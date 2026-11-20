"use strict";
// Node part of shadow step (b): reads the input, capture, rename map, and test file change status written by the
// parent shell, calls decide per test, checks it against live, and writes the divergence log in one go. Never touches live values.
const fs = require("node:fs");
const path = require("node:path");
const { parseComparisonSideResult } = require("../run-tests-baseline-comparison-side-result");
const { decide, explainDecision, DETAILS_DECIDED_OUTSIDE_DECIDE, DETAILS_FROM_REUSE_PATH } = require("../run-tests-baseline-decide");
const { readSide, readRenameMap } = require("../run-tests-baseline-compare/records");
const { makeNormalizer } = require("../run-tests-baseline-compare/normalize");
const { compareSides } = require("../run-tests-baseline-compare/diff");
const { compareOne, inOutside } = require("./compare-one");

const HEADER = "# run-tests-baseline decide shadow v1";
const FLAGS = ["input", "capture", "map", "tfc", "root", "base-wt", "b2", "head", "log", "started-ms"];
const CAPTURE_COLS = 11;
const OUTSIDE = [...DETAILS_DECIDED_OUTSIDE_DECIDE, ...DETAILS_FROM_REUSE_PATH];
const TFC = { 0: "changed", 1: "unchanged", 2: "unknown" };
const VERDICTS = ["same", "new", "no-records", "branch-missing", "base-missing"];

// Node fs cannot read the Git Bash drive-letter form, so convert it to the Windows drive form.
const toNative = (p) => (process.platform === "win32" ? String(p).replace(/^\/([a-zA-Z])\//, "$1:/") : String(p));

// Path columns arrive with backslash, TAB, and newline escaped as \\, \t, \n by the shell; one left-to-right pass.
const ESCAPES = { "\\": "\\", t: "\t", n: "\n" };
const decodePath = (s) => String(s).replace(/\\([\\tn])/g, (_, c) => ESCAPES[c]);

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i += 2) o[String(argv[i]).replace(/^--/, "")] = argv[i + 1] === undefined ? "" : argv[i + 1];
  const absent = FLAGS.filter((f) => o[f] === undefined);
  if (absent.length) throw new Error(`missing: --${absent.join(" --")}`);
  return o;
}

const rows = (file) => readLines(file).map((l) => ({ raw: l, cols: l.split("\t") }));

const readLines = (file) => {
  try { return fs.readFileSync(toNative(file), "utf8").split(/\r?\n/).filter((l) => l !== ""); } catch { return []; }
};

// The last capture row whose comparison side and rel both match.
function lastCapture(captures, side, rel) {
  let hit = null;
  for (const r of captures) if (r.cols[0] === side && r.cols[1] === rel) hit = r;
  return hit;
}

function captureResult(row) {
  if (row.cols.length !== CAPTURE_COLS) throw new Error("capture row has a wrong column count");
  const [, , logdir, seq, returnCode, rc, timedout, unsupported, decoy, state, unrunnable] = row.cols;
  const res = parseComparisonSideResult({ RTB_EXEC_STATE: state, RTB_EXEC_DECOY: decoy, returnCode, RTB_EXEC_RC: rc,
    RTB_EXEC_TIMEDOUT: timedout, RTB_EXEC_UNSUPPORTED: unsupported, RTB_EXEC_UNRUNNABLE: unrunnable },
  readLines(path.join(toNative(logdir), `${seq}.err`)));
  return { res, resDir: path.join(toNative(logdir), `${seq}.res`) };
}

// Compares the branch side and merge base side case records under three readings (same comparator as live rtb_compare).
function caseComparison(branch, base, opts) {
  const one = (branchRes, end) => {
    try {
      const r = compareSides(readSide(base.resDir), readSide(branchRes), Object.assign({}, opts, { end }));
      return VERDICTS.includes(r.verdict) ? r : { verdict: "compare-failed", count: 0, head: [] };
    } catch { return { verdict: "compare-failed", count: 0, head: [] }; }
  };
  const full = {
    branchRecordsAsNormal: one(branch.resDir, "normal"),
    branchRecordsAsInterrupted: one(branch.resDir, "interrupted"),
    // Read as no records: a nonexistent dir yields an empty comparison side.
    branchRecordsIgnored: one(`${branch.resDir}.decide-shadow-none-${process.pid}`, "normal"),
  };
  const fields = {};
  for (const k of Object.keys(full)) fields[k] = full[k].verdict;
  return { fields, full };
}

const SAME = { branchRecordsAsNormal: "same", branchRecordsAsInterrupted: "same", branchRecordsIgnored: "same" };
const isTimeout = (r) => r.termination === "timeout" || r.termination === "interrupted-by-outer-watchdog";
const newSuffix = (count, head) => (Number(count) > 0 ? ` new=${count} head=${head}` : "");

// Adds to the decide detail the same marks live adds (rename and new lines).
function decidedDetail(out, input, full, fieldRead, old) {
  let det = out.detail;
  if (old && input.baseResult && !(isTimeout(input.branchResult) && det === "timeout-at-base")) det += `-via-rename:${old}`;
  const c = fieldRead && full ? full[fieldRead] : null;
  return det + (c ? newSuffix(c.count, JSON.stringify(c.head)) : "");
}

function oneTest(t, ctx) {
  const [, rel, runRel, old, liveClass, liveDet, newc, newh] = t.cols;
  const liveDetail = `${liveDet}${newSuffix(newc, newh)}`;
  const noLine = (reason) => ({ line: `NO_COMPARISON\t${rel}\t${reason}`, kind: "NO_COMPARISON" });
  if (inOutside(OUTSIDE, liveClass, String(liveDet).replace(/-via-rename:.*$/, ""))) return noLine("outside-decide");
  const brRow = lastCapture(ctx.captures, "branch", rel);
  if (!brRow) return noLine("branch-result-reused-from-cache");
  const baseRow = runRel ? lastCapture(ctx.captures, "merge-base", runRel) : null;
  let input; let decision; let full = null;
  try {
    const branch = captureResult(brRow);
    const base = baseRow ? captureResult(baseRow) : null;
    let fields = Object.assign({}, SAME);
    if (base) ({ fields, full } = caseComparison(branch, base, ctx.cmpOpts));
    input = { branchResult: branch.res, baseResult: base ? base.res : null,
      testFileChange: ctx.b2 ? (ctx.tfc.get(t.cols[0]) || "unknown") : "unknown", caseComparison: fields };
    const out = decide(input);
    decision = out.class !== undefined
      ? { class: out.class, detail: decidedDetail(out, input, full, explainDecision(input).fieldRead, decodePath(old)) } : out;
  } catch { return noLine("capture-unreadable"); }
  const r = compareOne({ rel, captureRow: brRow.raw, decision, liveClass, liveDetail,
    outsideDetails: OUTSIDE, decideInput: input });
  if (r.kind === "NO_COMPARISON") return noLine(r.reason);
  const result = r.result === "recorded" ? `recorded:${r.recordId}` : r.result;
  const decCls = decision.class !== undefined ? decision.class : "-";
  const decDet = decision.class !== undefined ? decision.detail : `outside:${decision.decidedOutsideDecide}`;
  const baseJson = input.baseResult ? JSON.stringify(input.baseResult) : "null";
  return { kind: "COMPARED", result: r.result,
    line: ["COMPARED", rel, liveClass, liveDetail, decCls, decDet, result, JSON.stringify(input.branchResult), baseJson].join("\t") };
}

function main(argv) {
  const o = parseArgs(argv);
  const tfc = new Map(rows(o.tfc).map((r) => [r.cols[0], TFC[r.cols[1]] || "unknown"]));
  const ctx = { captures: rows(o.capture), tfc, b2: o.b2,
    cmpOpts: { normalize: makeNormalizer({ root: o.root, baseWt: o["base-wt"] }), renames: readRenameMap(toNative(o.map)) } };
  const n = { compared: 0, matched: 0, recorded: 0, unrecorded: 0, no_comparison: 0 };
  const body = [];
  for (const t of rows(o.input)) {
    const r = oneTest(t, ctx);
    body.push(r.line);
    if (r.kind === "NO_COMPARISON") { n.no_comparison += 1; continue; }
    n.compared += 1;
    n[r.result === "match" ? "matched" : r.result] += 1;
  }
  const started = Number(o["started-ms"]);
  const elapsed = Number.isFinite(started) && started > 0 ? Math.max(0, Date.now() - started) : 0;
  const summary = ["SUMMARY", ...Object.keys(n).map((k) => `${k}=${n[k]}`), "skipped=-", `elapsed_ms=${elapsed}`].join("\t");
  const run = ["RUN", Math.floor(Date.now() / 1000), o.head, o.b2 || "-"].join("\t");
  fs.writeFileSync(toNative(o.log), `${[HEADER, run, ...body, summary].join("\n")}\n`);
  process.stdout.write(`compared=${n.compared} unrecorded=${n.unrecorded} no_comparison=${n.no_comparison}\n`);
  return 0;
}

module.exports = { main, oneTest };
