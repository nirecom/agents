#!/usr/bin/env node
"use strict";
// Tests: bin/lib/run-tests-baseline-decide-shadow.js
// Tags: TL1, bin, run-tests-baseline, decide-shadow, table-driven, scope:common
// #3068 — step 4 (capture-unreadable) and step 5 (unrecorded under decidedOutsideDecide) of the shadow comparison.
// provisional contract (the plan does not state the call shape, so this test fixes it provisionally):
//   compareOne({ rel, captureRow, decision, liveDetail, outsideDetails }) →
//     { kind: "NO_COMPARISON", reason } | { kind: "COMPARED", result: "match" | "recorded" | "unrecorded" | "diverged" }
//   rel: RUN_REL, captureRow: one capture TSV row (string), decision: the decide output,
//   liveDetail: the live detail, outsideDetails: the outside-decide list (array of details).
// TL3 gap: the capture TSV and divergence log lines the real CLI writes are owned by the corpus TL2 tests.
const { isolate, caseBegin, caseEnd } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const restore = isolate();
after(() => restore());

const MODULE = path.resolve(__dirname, "..", "..", "bin", "lib", "run-tests-baseline-decide-shadow.js");
// While the module does not exist yet, each test fails with MODULE_NOT_FOUND (the whole file does not crash).
const compareOne = (a) => require(MODULE).compareOne(a);
const ROW = "0\ttests/bin/t.sh\tFAIL\t1";

caseBegin("SH-step4-capture-unreadable", "bin/lib/run-tests-baseline-decide-shadow.js");
test("SH-step4: a tab in rel makes the capture unreadable, so no comparison (capture-unreadable)", () => {
  const cases = [
    { name: "tab in rel", rel: "tests/bin/a\tb.sh" },
    { name: "tab at the end of rel", rel: "tests/bin/a.sh\t" },
  ];
  for (const { name, rel } of cases) {
    const got = compareOne({ rel, captureRow: ROW, decision: { class: "broken", detail: "passes-at-base" },
      liveDetail: "passes-at-base", outsideDetails: [] });
    assert.deepEqual(got, { kind: "NO_COMPARISON", reason: "capture-unreadable" }, name);
  }
});
caseEnd();

caseBegin("SH-step5-outside-unrecorded", "bin/lib/run-tests-baseline-decide-shadow.js");
test("SH-step5: decidedOutsideDecide with a live detail absent from the outside list is unrecorded", () => {
  const base = { rel: "tests/bin/t.sh", captureRow: ROW, decision: { decidedOutsideDecide: "x" } };
  const cases = [
    { name: "outside list empty", liveDetail: "fails-at-base-exit-1", outside: [], want: "unrecorded" },
    { name: "outside list holds only another detail", liveDetail: "fails-at-base-exit-1", outside: ["ledger-same-base"], want: "unrecorded" },
  ];
  for (const { name, liveDetail, outside, want } of cases) {
    const got = compareOne(Object.assign({}, base, { liveDetail, outsideDetails: outside }));
    assert.deepEqual(got, { kind: "COMPARED", result: want }, name);
  }
});
caseEnd();

const DECIDE = path.resolve(__dirname, "..", "..", "bin", "lib", "run-tests-baseline-decide.js");
const R = (verdict, termination, exitCode, hitKind = "none") => ({ verdict, termination, exitCode, hitKind });
const FAIL1 = R("FAIL", "completed", 1);
const IN = (branchResult, baseResult, cmp = {}) => ({ branchResult, baseResult, testFileChange: "unchanged",
  caseComparison: Object.assign({ branchRecordsAsNormal: "same", branchRecordsAsInterrupted: "same", branchRecordsIgnored: "same" }, cmp) });
// As main.js does, passes the decide output, the outside-decide list and the decide input.
function compareLive(input, liveClass, liveDetail) {
  const D = require(DECIDE);
  return compareOne({ rel: "tests/bin/t.sh", captureRow: ROW, decision: D.decide(input), liveClass, liveDetail,
    outsideDetails: D.DETAILS_DECIDED_OUTSIDE_DECIDE, decideInput: input });
}

caseBegin("SH-outside-decide-consults-records", "bin/lib/run-tests-baseline-decide-shadow/compare-one.js");
test("SH-outside-records: even under decidedOutsideDecide, a live detail absent from the outside list looks up the recorded discrepancies", () => {
  const input = IN(R("?", "?", 0), FAIL1, { branchRecordsIgnored: "branch-missing" });
  assert.ok(require(DECIDE).decide(input).decidedOutsideDecide !== undefined, "premise: branch ?/? rc 0 is decided outside decide");
  assert.deepEqual(compareLive(input, "new-case-failure-on-branch", "case-records-missing-on-branch"),
    { kind: "COMPARED", result: "recorded", recordId: "discrepancy-6" }, "live that reads an unknown state as skip");
  assert.deepEqual(compareLive(input, "passes-alone-on-branch", "exit-1-then-pass"),
    { kind: "NO_COMPARISON", reason: "outside-decide" }, "live in the outside list stays outside-decide as before");
  assert.deepEqual(compareLive(input, "broken", "passes-at-base"),
    { kind: "COMPARED", result: "unrecorded" }, "live unrelated to the recorded reading is unrecorded");
});
caseEnd();

caseBegin("SH-recorded-needs-live-reading", "bin/lib/run-tests-baseline-decide-shadow/compare-one.js");
test("SH-recorded-live: even when the combination matches a record, live that is not the recorded reading is unrecorded", () => {
  const input = IN(FAIL1, R("FAIL", "completed", 1, "command-guard-hit-only"));
  assert.deepEqual(compareLive(input, "undetermined", "root-decoy-hit-at-base"),
    { kind: "COMPARED", result: "recorded", recordId: "discrepancy-3" }, "live with the recorded reading");
  assert.deepEqual(compareLive(input, "broken", "passes-at-base"),
    { kind: "COMPARED", result: "unrecorded" }, "live unrelated to the recorded reading");
});
caseEnd();

const COMPARE_ONE = path.resolve(__dirname, "..", "..", "bin", "lib", "run-tests-baseline-decide-shadow", "compare-one.js");
caseBegin("SH-compare-one-guards", "bin/lib/run-tests-baseline-decide-shadow/compare-one.js");
test("SH-guards: unreadable input is capture-unreadable, needsBaseResult is base-result-reused-from-ledger-or-inheritance", () => {
  const { compareOne: cmp } = require(COMPARE_ONE);
  const UNREADABLE = { kind: "NO_COMPARISON", reason: "capture-unreadable" };
  const REUSED = { kind: "NO_COMPARISON", reason: "base-result-reused-from-ledger-or-inheritance" };
  const ok = { class: "broken", detail: "passes-at-base" };
  const cases = [
    { name: "decision is null", decision: null, want: UNREADABLE },
    { name: "decision is a string", decision: "broken", want: UNREADABLE },
    { name: "decision is a number", decision: 1, want: UNREADABLE },
    { name: "tab in rel", rel: "tests/bin/a\tb.sh", want: UNREADABLE },
    { name: "LF in rel", rel: "tests/bin/a\nb.sh", want: UNREADABLE },
    { name: "CR in rel", rel: "tests/bin/a\rb.sh", want: UNREADABLE },
    { name: "captureRow is undefined", captureRow: undefined, want: UNREADABLE },
    { name: "captureRow is null", captureRow: null, want: UNREADABLE },
    { name: "captureRow is a number", captureRow: 0, want: UNREADABLE },
    { name: "captureRow is an array", captureRow: ROW.split("\t"), want: UNREADABLE },
    { name: "needsBaseResult", decision: { needsBaseResult: true }, want: REUSED },
  ];
  for (const c of cases) {
    const args = { rel: "tests/bin/t.sh", captureRow: ROW, decision: ok, liveClass: "broken",
      liveDetail: "passes-at-base", outsideDetails: [] };
    for (const k of ["rel", "captureRow", "decision"]) if (k in c) args[k] = c[k];
    assert.deepEqual(cmp(args), c.want, c.name);
  }
  assert.deepEqual(cmp({ rel: "tests/bin/t.sh", captureRow: ROW, decision: ok, liveClass: "broken",
    liveDetail: "passes-at-base", outsideDetails: [] }), { kind: "COMPARED", result: "match" }, "control: readable input is compared");
});
caseEnd();

caseBegin("SH-cli-tab-in-path", "bin/lib/run-tests-baseline-decide-shadow.js");
test("SH-cli-tab: the real CLI given a path with a tab does not crash; that row is capture-unreadable and SUMMARY is still written", () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const { spawnSync } = require("node:child_process");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "decide-shadow-cli-"));
  try {
    const f = (name) => path.join(dir, name);
    const tab = "tests/bin/a\tb.sh";
    const ok = "tests/bin/ok.sh";
    // input: <i> <TESTS> <RUN_REL> <RUN_OLD> <CLS> <DET> <NEWC> <NEWH> (the same 8 columns as the shell printf).
    fs.writeFileSync(f("input.tsv"), [[0, tab, "", "", "broken", "passes-at-base", 0, "[]"],
      [1, ok, ok, "", "broken", "passes-at-base", 0, "[]"]].map((r) => r.join("\t")).join("\n") + "\n");
    // capture: side rel logdir seq returnCode rc timedout unsupported decoy state unrunnable (11 columns).
    const cap = (side, rel, rc, state) => [side, rel, f("logs"), "1", rc, rc, "0", "0", "0", state, "0"].join("\t");
    fs.writeFileSync(f("capture.tsv"), [cap("branch", tab, "1", "FAIL"), cap("branch", ok, "1", "FAIL"),
      cap("merge-base", ok, "0", "PASS")].join("\n") + "\n");
    for (const n of ["map.tsv", "tfc.tsv"]) fs.writeFileSync(f(n), "");
    const r = spawnSync(process.execPath, [path.resolve(__dirname, "..", "..", "bin", "lib", "run-tests-baseline-decide-shadow.js"),
      "--input", f("input.tsv"), "--capture", f("capture.tsv"), "--map", f("map.tsv"), "--tfc", f("tfc.tsv"),
      "--root", dir, "--base-wt", dir, "--b2", "", "--head", "h", "--log", f("log.tsv"), "--started-ms", String(Date.now())],
    { encoding: "utf8", timeout: 30000, cwd: dir });
    assert.equal(r.status, 0, `the CLI does not crash: status=${r.status} stderr=${r.stderr}`);
    const lines = fs.readFileSync(f("log.tsv"), "utf8").split("\n").filter((l) => l !== "");
    assert.match(r.stdout, /^compared=1 unrecorded=\d+ no_comparison=1\n$/,
      `stdout counts are 1 comparison and 1 no_comparison: ${JSON.stringify(lines)}`);
    const no = lines.filter((l) => l.startsWith("NO_COMPARISON\t"));
    assert.equal(no.length, 1, `one NO_COMPARISON line: ${JSON.stringify(lines)}`);
    assert.deepEqual(no[0].split("\t").slice(2), ["capture-unreadable"], `reason of the row with a tab: ${no[0]}`);
    assert.equal(no[0].split("\t").length, 3, "the NO_COMPARISON line's columns are intact");
    const cmp = lines.filter((l) => l.startsWith("COMPARED\t"));
    assert.equal(cmp.length, 1, "the control row is compared");
    assert.equal(cmp[0].split("\t")[1], ok, "the compared row is the control path");
    const summary = lines.filter((l) => l.startsWith("SUMMARY\t"));
    assert.equal(summary.length, 1, "exactly one SUMMARY line");
    assert.match(summary[0], /\tcompared=1\t.*\tno_comparison=1\tskipped=-\t/, `SUMMARY counts: ${summary[0]}`);
    assert.equal(lines[lines.length - 1], summary[0], "SUMMARY is the last line");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
caseEnd();

// The shell escapes path columns before the node CLI reads them: backslash -> \\, TAB -> \t, LF -> \n (two characters each).
const escPath = (p) => String(p).replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\n/g, "\\n");

// runShadowCli <inputRows> <captureRows(logdir)> — runs the real node CLI in a temp dir; returns { r, lines }.
function runShadowCli(inputRows, captureRows) {
  const fs = require("node:fs");
  const os = require("node:os");
  const { spawnSync } = require("node:child_process");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "decide-shadow-esc-"));
  try {
    const f = (name) => path.join(dir, name);
    fs.writeFileSync(f("input.tsv"), inputRows.map((r) => r.join("\t")).join("\n") + "\n");
    fs.writeFileSync(f("capture.tsv"), captureRows(f("logs")).map((r) => r.join("\t")).join("\n") + "\n");
    for (const n of ["map.tsv", "tfc.tsv"]) fs.writeFileSync(f(n), "");
    const r = spawnSync(process.execPath, [MODULE,
      "--input", f("input.tsv"), "--capture", f("capture.tsv"), "--map", f("map.tsv"), "--tfc", f("tfc.tsv"),
      "--root", dir, "--base-wt", dir, "--b2", "", "--head", "h", "--log", f("log.tsv"), "--started-ms", String(Date.now())],
    { encoding: "utf8", timeout: 30000, cwd: dir });
    const lines = fs.existsSync(f("log.tsv")) ? fs.readFileSync(f("log.tsv"), "utf8").split("\n").filter((l) => l !== "") : [];
    return { r, lines };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}
const capRow = (logdir, side, rel, rc, state) => [side, rel, logdir, "1", rc, rc, "0", "0", "0", state, "0"];

caseBegin("SH-cli-escaped-path-columns", "bin/lib/run-tests-baseline-decide-shadow.js");
test("SH-cli-escaped: a tab path arrives escaped, so the log path column is the escaped literal and stays one column", () => {
  const tabRaw = "tests/bin/a\tb.sh";
  const tab = escPath(tabRaw);
  const ok = "tests/bin/ok.sh";
  assert.equal(tab, "tests/bin/a\\tb.sh", "premise: the escaped form is backslash-t, two characters");
  const { r, lines } = runShadowCli([[0, tab, "", "", "broken", "passes-at-base", 0, "[]"],
    [1, ok, ok, "", "broken", "passes-at-base", 0, "[]"]],
  (logs) => [capRow(logs, "branch", tab, "1", "FAIL"), capRow(logs, "branch", ok, "1", "FAIL"),
    capRow(logs, "merge-base", ok, "0", "PASS")]);
  assert.equal(r.status, 0, `the CLI does not crash: status=${r.status} stderr=${r.stderr}`);
  const body = lines.filter((l) => /^(COMPARED|NO_COMPARISON)\t/.test(l));
  assert.equal(body.length, 2, `one line per test: ${JSON.stringify(lines)}`);
  const tabLine = body.find((l) => l.split("\t")[1] === tab);
  assert.ok(tabLine, `a line carries the escaped path ${JSON.stringify(tab)}: ${JSON.stringify(lines)}`);
  const want = tabLine.startsWith("COMPARED\t") ? 9 : 3;
  assert.equal(tabLine.split("\t").length, want, `the escaped-path line keeps ${want} columns: ${JSON.stringify(tabLine)}`);
  assert.ok(!body.some((l) => l.split("\t")[1] === "tests/bin/a"), `no line carries the truncated path: ${JSON.stringify(lines)}`);
  const summary = lines.filter((l) => l.startsWith("SUMMARY\t"));
  assert.equal(summary.length, 1, "exactly one SUMMARY line");
  const m = /\tcompared=(\d+)\t.*\tno_comparison=(\d+)\t/.exec(summary[0]);
  assert.ok(m && Number(m[1]) + Number(m[2]) === 2, `compared + no_comparison is the 2 tests: ${summary[0]}`);
});
caseEnd();

caseBegin("SH-cli-rename-old-decoded", "bin/lib/run-tests-baseline-decide-shadow/main.js");
test("SH-cli-rename-old: an escaped RUN_OLD is decoded where the -via-rename detail is built, so it equals the live detail", () => {
  const cur = "tests/bin/new.sh";
  const cases = [
    { name: "control: no escapable character in the old path", oldRaw: "tests/bin/old.sh" },
    { name: "backslash in the old path", oldRaw: "tests/bin/a\\b.sh" },
  ];
  for (const { name, oldRaw } of cases) {
    const old = escPath(oldRaw);
    const { r, lines } = runShadowCli([[0, cur, old, old, "broken", `passes-at-base-via-rename:${oldRaw}`, 0, "[]"]],
      (logs) => [capRow(logs, "branch", cur, "1", "FAIL"), capRow(logs, "merge-base", old, "0", "PASS")]);
    assert.equal(r.status, 0, `${name}: the CLI does not crash: status=${r.status} stderr=${r.stderr}`);
    const cmp = lines.filter((l) => l.startsWith("COMPARED\t"));
    assert.equal(cmp.length, 1, `${name}: the renamed test is compared: ${JSON.stringify(lines)}`);
    const cols = cmp[0].split("\t");
    assert.equal(cols[5], `passes-at-base-via-rename:${oldRaw}`, `${name}: the decided detail names the decoded old path`);
    assert.equal(cols[6], "match", `${name}: decide matches live: ${JSON.stringify(cmp[0])}`);
  }
});
caseEnd();
