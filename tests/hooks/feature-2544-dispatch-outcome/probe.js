#!/usr/bin/env node
"use strict";
// Fixture builder and read-only probe for the #2544 dispatch-outcome cases.
// A module that does not exist yet prints MODULE_MISSING:<path> instead of
// crashing, so a missing implementation fails an assertion, never the harness.
// F2544_AGENTS = repo root under test; argv[2] = mode; the rest are mode args.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const ROOT = process.env.F2544_AGENTS;
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const [mode, ...a] = process.argv.slice(2);
const CONTRACT = "hooks/lib/worker-outcome-contract.js";
const SETTLEMENT = "hooks/workflow-state/dispatch-settlement.js";
const BASELINE = "bin/workflow/lib/run-tests-baseline-evidence.js";
const PRE_RUN_TESTS = [
  "workflow_init", "clarify_intent", "research", "outline", "detail",
  "branching_complete", "write_tests", "review_tests", "write_code",
];

const out = (s) => process.stdout.write(`${s}\n`);
const controlDir = (sid) => path.join(STATE_DIR, `${sid}.control`);
const controlFile = (sid, name) => path.join(controlDir(sid), name);
const wf = () => require(path.join(ROOT, "hooks", "workflow-state"));

function load(rel) {
  try {
    return { mod: require(path.join(ROOT, rel)) };
  } catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND") return { missing: `MODULE_MISSING:${rel}` };
    return { missing: `LOAD_THREW:${rel}:${e && e.message}` };
  }
}

function show(v) {
  if (v === undefined || v === null) return "absent";
  return typeof v === "string" ? v : JSON.stringify(v);
}

function rawEvents(sid) {
  const raw = JSON.parse(fs.readFileSync(path.join(STATE_DIR, `${sid}.json`), "utf8"));
  return Array.isArray(raw.events) ? raw.events : [];
}

function buildOutcome(sid, stem, status, pass, fail, failing) {
  const bytes = fs.readFileSync(controlFile(sid, `${stem}.json`));
  const fields = {
    schema_version: 1,
    worker: "test-runner",
    stem,
    session_id: sid,
    payload_sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
    cwd: JSON.parse(bytes.toString("utf8")).cwd,
    status,
    exit_code: status === "pass" ? 0 : 1,
    duration_ms: 1200,
    worker_result: {
      run_contract: { pass, fail, skip: 0, executed: pass + fail },
      failing_tests: failing,
      log_tail: ["PASS: alpha"],
      summary: `${status}: ${pass} passed, ${fail} failed`,
    },
  };
  const c = load(CONTRACT);
  if (c.mod && typeof c.mod.buildOutcome === "function") {
    try { return c.mod.buildOutcome(fields); } catch (_) { return fields; }
  }
  return fields;
}

const MODES = {
  call() {
    const l = load(a[0]);
    if (l.missing) return out(l.missing);
    if (typeof l.mod[a[1]] !== "function") return out(`FN_MISSING:${a[1]}`);
    try { out(show(l.mod[a[1]](...JSON.parse(a[2] || "[]")))); } catch (e) { out(`THREW:${e && e.message}`); }
  },
  value() {
    const l = load(a[0]);
    if (l.missing) return out(l.missing);
    let v = l.mod;
    for (const key of a[1].split(".")) v = v === undefined || v === null ? undefined : v[key];
    out(show(v));
  },
  cmp() {
    const l = load(SETTLEMENT);
    if (l.missing) return out(l.missing);
    if (typeof l.mod.compareSeq !== "function") return out("FN_MISSING:compareSeq");
    const n = l.mod.compareSeq(a[0], a[1]);
    out(n < 0 ? "lt" : n > 0 ? "gt" : n === 0 ? "eq" : `bad:${n}`);
  },
  digest() {
    const l = load(CONTRACT);
    if (l.missing) return out(l.missing);
    out(show(l.mod.payloadDigest(Buffer.from(a[0], "utf8"))));
  },
  validate() {
    const l = load(CONTRACT);
    if (l.missing) return out(l.missing);
    let subject;
    if (a[0] === "--raw") {
      subject = JSON.parse(a[1]);
    } else {
      const o = buildOutcome(a[0], a[1], "pass", 3, 0, []);
      const over = JSON.parse(a[2] || "{}");
      subject = Object.assign({}, o, over);
      if (over.worker_result) subject.worker_result = Object.assign({}, o.worker_result, over.worker_result);
      if (a[3]) delete subject[a[3]];
    }
    let r;
    try { r = l.mod.validateOutcome(subject); } catch (e) { return out(`THREW:${e && e.message}`); }
    if (r && r.ok === true) return out(`ok:${show(r.outcome && r.outcome.stem)}`);
    const hasReason = r && r.ok === false && typeof r.reason === "string" && r.reason !== "";
    out(hasReason ? "reject:with-reason" : `reject:no-reason:${show(r)}`);
  },
  kind() {
    const r = require(path.join(ROOT, "hooks/lib/plans-artifact-registry.js")).parsePlansEntry(a[0]);
    out(r ? `${r.verdict}:${show(r.kind)}` : "none");
  },
  unsettled() {
    const l = load(SETTLEMENT);
    if (l.missing) return out(l.missing);
    const r = l.mod.listUnsettled({ sessionId: a[0] });
    const stems = (r.unsettled || []).map((u) => u.stem).sort().join(",") || "none";
    out(typeof r.reason === "string" && r.reason !== "" ? `${stems}|reason` : stems);
  },
  latest() {
    const l = load(SETTLEMENT);
    if (l.missing) return out(l.missing);
    const r = l.mod.latestDispatch({ sessionId: a[0], worker: a[1] });
    out(r ? `${r.stem}/${r.seq}` : "none");
  },
  "source-status"() {
    const l = load(SETTLEMENT);
    if (l.missing) return out(l.missing);
    const s = wf().readState(a[0]);
    const e = s && s.steps && s.steps.run_tests;
    out(show(l.mod.outcomeSourceStatus({ sessionId: a[0], source: e ? e.outcome_source : null })));
  },
  "is-test-command"() {
    out(String(require(path.join(ROOT, "hooks/workflow-run-tests/exec-model.js")).isTestCommand(a[0])));
  },
  "baseline-seq"() {
    const r = require(path.join(ROOT, BASELINE)).failing(a[0]);
    const m = /^SEQ=(\d+)/.exec(r.stdout || "");
    out(m ? m[1] : `ERR:${r.stderr}`);
  },
  "baseline-record"() {
    const entries = [{ path: a[2], class: "preexisting", detail: "fixture" }];
    const r = require(path.join(ROOT, BASELINE)).record(a[0], Number(a[1]), entries, "abc1234");
    out(`${r.code}:${show(r.reason)}`);
  },
  field() {
    const s = wf().readState(a[0]);
    const e = s && s.steps && s.steps[a[1]];
    out(show(e ? e[a[2]] : undefined));
  },
  path() {
    // path <sid> <step> <field> <dotted.key> — a value inside an object annotation.
    const s = wf().readState(a[0]);
    let v = s && s.steps && s.steps[a[1]] ? s.steps[a[1]][a[2]] : undefined;
    for (const k of a[3].split(".")) v = v === undefined || v === null ? undefined : v[k];
    out(show(v));
  },
  events() { out(String(rawEvents(a[0]).length)); },
  seed() { wf().markStep(a[0], a[1], a[2], a[3] ? JSON.parse(a[3]) : undefined); },
  prefix() {
    const approval = require(path.join(ROOT, "hooks/workflow-state/completion-approval.js"));
    for (const s of PRE_RUN_TESTS) {
      if (approval.isApprovalGatedStep(s)) {
        approval.recordPlanApproval(a[0], s, { source: "reset-sentinel", reason: "2544 fixture" });
      }
      wf().markStep(a[0], s, "complete");
    }
  },
  "hook-input"() {
    const input = {
      session_id: a[0],
      tool_name: "Bash",
      tool_input: { command: a[1] },
      tool_response: { exit_code: parseInt(a[2], 10), stdout: a[3] || "" },
    };
    if (a[4]) input.tool_input.cwd = a[4];
    out(JSON.stringify(input));
  },
  "mark-input"() {
    out(JSON.stringify({ session_id: a[0], tool_name: "Bash", tool_input: { command: a[1] } }));
  },
  payload() {
    fs.mkdirSync(controlDir(a[0]), { recursive: true });
    const body = { cwd: a[2], timeout_seconds: 120, test_args: [] };
    fs.writeFileSync(controlFile(a[0], `${a[1]}.json`), `${JSON.stringify(body)}\n`);
  },
  outcome() {
    const o = buildOutcome(a[0], a[1], a[2], Number(a[3]), Number(a[4]), JSON.parse(a[5] || "[]"));
    const over = a[6] ? JSON.parse(a[6]) : {};
    const merged = Object.assign({}, o, over);
    if (over.worker_result) merged.worker_result = Object.assign({}, o.worker_result, over.worker_result);
    fs.writeFileSync(controlFile(a[0], `${a[1]}.outcome.json`), `${JSON.stringify(merged)}\n`);
  },
  touch() {
    fs.mkdirSync(controlDir(a[0]), { recursive: true });
    fs.writeFileSync(controlFile(a[0], a[1]), a[2] === undefined ? `${new Date().toISOString()}\n` : a[2]);
  },
  rm() { fs.rmSync(controlFile(a[0], a[1]), { force: true }); },
  exists() { out(fs.existsSync(controlFile(a[0], a[1])) ? "yes" : "no"); },
  age() {
    const old = new Date(Date.now() - Number(a[2]) * 3600 * 1000);
    const p = controlFile(a[0], a[1]);
    fs.writeFileSync(p, `${old.toISOString()}\n`);
    fs.utimesSync(p, old, old);
  },
  symlink() {
    // symlink <sid> <name> <target-abs> — replace a control file with a symlink.
    // Prints "unsupported" where the OS refuses (Windows without the privilege).
    const p = controlFile(a[0], a[1]);
    fs.rmSync(p, { force: true });
    try { fs.symlinkSync(a[2], p, "file"); out("ok"); } catch (_) { out("unsupported"); }
  },
  copy() {
    // copy <src-abs> <dst-abs>
    fs.copyFileSync(a[0], a[1]);
  },
  file() { out(controlFile(a[0], a[1])); },
  sha() {
    // sha <sid> <name> — sha256 hex of a control file's bytes, or "absent".
    const p = controlFile(a[0], a[1]);
    if (!fs.existsSync(p)) return out("absent");
    out(crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex"));
  },
};

try {
  if (!Object.prototype.hasOwnProperty.call(MODES, mode)) {
    process.stderr.write(`probe: unknown mode ${String(mode)}\n`);
    process.exit(2);
  }
  MODES[mode]();
} catch (e) {
  out(`PROBE_ERR:${e && e.message}`);
}
