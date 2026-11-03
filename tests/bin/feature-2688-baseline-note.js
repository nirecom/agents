#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/run-tests-completion-note.js, bin/workflow/run-tests-baseline-evidence
// Tags: TL2, run-tests, baseline, completion-note, auto-accept, note, legacy, disclosure, scope:issue-specific
// #2688 T4 - disclosure of auto-accepts. record --note reaches baseline_note (newlines stripped, 200 chars),
// and completionNote returns the auto-accept line under `Unverified tests:`. The old basis baseline-user-accepted
// becomes a fixed legacy line.
// TL3 gap: the path where bin/run-tests-baseline passes --note to record is verified in bash by
// tests/bin/feature-2431-run-tests-baseline.sh (stage-order part).

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "workflow", "run-tests-baseline-evidence");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rtb-2688-note-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
process.env.RUN_ALL_CACHE_DIR = path.join(TMP, "cache");
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { appendEvents } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "events"));
const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));
const NOTE = require(path.join(ROOT, "hooks", "lib", "run-tests-completion-note.js"));

const PRE = "- Unverified tests:";
const LEGACY = `${PRE} failing tests accepted by the user before #2688 (legacy grant; details not re-read)`;
const autoLine = (n, causes, note) =>
  `${PRE} ${n} failing test(s) auto-accepted without baseline proof (causes: ${causes}; note: ${note})`;

let serial = 0;
const sid = (label) => `bn-${label}-${process.pid}-${++serial}`;
const ann = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });
const entry = (id) => { const s = readState(id); return (s && s.steps && s.steps.run_tests) || {}; };
const cli = (args) => {
  const r = spawnSync(process.execPath, [CLI, ...args], { cwd: TMP, encoding: "utf8", timeout: 30000 });
  return { rc: r.status, out: String(r.stdout || ""), err: String(r.stderr || "") };
};

// recordAuto - record one skip-at-base (auto-accepted) item. extra holds options such as --note.
function recordAuto(label, extra) {
  const id = sid(label);
  appendEvents(id, [
    { kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" },
    ann("run_outcome", "fail"), ann("failing_tests", ["tests/bin/s.sh"]), ann("unrunnable_count", 0)]);
  const m = /^SEQ=(\S+)/m.exec(cli(["failing", "--session", id]).out);
  const file = path.join(TMP, `${id}.tsv`);
  fs.writeFileSync(file, "tests/bin/s.sh\tundetermined\tskip-at-base\n");
  const r = cli(["record", "--session", id, "--seq", m ? m[1] : "1", "--classification", file, ...extra]);
  return Object.assign(r, { id });
}

const cls = (...rows) => ({ base: "abc", entries: rows.map(([p, c, d]) => ({ path: p, class: c, detail: d })) });
const done = (o) => Object.assign({ status: "complete", run_outcome: "pass" }, o);

caseBegin("exports-the-auto-basis", "hooks/lib/run-tests-completion-note.js");
test("exports-the-auto-basis", () => {
  assert.equal(NOTE.BASELINE_AUTO_BASIS, "baseline-auto-accepted");
  assert.equal(NOTE.UNRUNNABLE_ACCEPT_BASIS, "unrunnable-accepted");
  assert.equal(NOTE.BASELINE_ACCEPT_BASIS, undefined, "the user-grant basis constant is retired");
});
caseEnd();

caseBegin("auto-line-text", "hooks/lib/run-tests-completion-note.js");
test("auto-line-text", () => {
  const e = done({ completion_basis: "baseline-auto-accepted", baseline_note: "seen on main",
    baseline_classification: cls(["t/a.sh", "undetermined", "skip-at-base"], ["t/b.sh", "undetermined", "skip-at-base"],
      ["t/c.sh", "preexisting", "base-fail"]) });
  assert.equal(NOTE.completionNote(e), autoLine(2, "skip-at-base", "seen on main"));
  const none = Object.assign({}, e, { baseline_note: undefined });
  assert.equal(NOTE.completionNote(none), autoLine(2, "skip-at-base", "(none)"));
});
caseEnd();

caseBegin("auto-line-names-every-cause-once", "hooks/lib/run-tests-completion-note.js");
test("auto-line-names-every-cause-once", () => {
  const v = NOTE.completionNote(done({ completion_basis: "baseline-auto-accepted",
    baseline_classification: cls(["t/a.sh", "undetermined", "timeout-at-base"],
      ["t/b.sh", "flaky-timeout-on-branch", "exit-124-then-pass"], ["t/c.sh", "undetermined", "timeout-at-base"]) }));
  assert.ok(v.startsWith(`${PRE} 3 failing test(s) auto-accepted without baseline proof (causes: `), v);
  assert.equal(v.split("timeout-at-base").length - 1, 1, v);
  assert.ok(v.includes("exit-124-then-pass"), v);
  assert.ok(v.endsWith("; note: (none))"), v);
});
caseEnd();

caseBegin("legacy-user-grant-line", "hooks/lib/run-tests-completion-note.js");
test("legacy-user-grant-line", () => {
  const legacy = done({ completion_basis: "baseline-user-accepted",
    baseline_classification: cls(["t/a.sh", "undetermined", "budget-exhausted"]),
    baseline_accept: { reason: "seen red on main", kind: "undetermined", run_seq: 1, accepted_run_outcome: "fail" } });
  assert.equal(NOTE.completionNote(legacy), LEGACY);
  const nolist = done({ completion_basis: "baseline-user-accepted", failing_tests: null,
    baseline_accept: { reason: "flaky", kind: "failing-list-unrecorded", run_seq: 2 } });
  assert.equal(NOTE.completionNote(nolist), LEGACY);
});
caseEnd();

caseBegin("no-line-for-proof-or-pending", "hooks/lib/run-tests-completion-note.js");
test("no-line-for-proof-or-pending", () => {
  assert.equal(NOTE.completionNote(done({ completion_basis: "baseline-preexisting" })), null);
  assert.equal(NOTE.completionNote(done({})), null);
  assert.equal(NOTE.completionNote({ status: "pending", completion_basis: "baseline-auto-accepted" }), null);
  assert.equal(NOTE.completionNote(null), null);
});
caseEnd();

caseBegin("record-note-reaches-baseline-note", "bin/workflow/run-tests-baseline-evidence");
test("record-note-reaches-baseline-note", () => {
  const r = recordAuto("note", ["--note", "seen on main"]);
  assert.equal(r.rc, 0, r.err);
  const e = entry(r.id);
  assert.equal(e.completion_basis, "baseline-auto-accepted");
  assert.equal(e.baseline_note, "seen on main");
  assert.equal(NOTE.readCompletionNote(r.id), autoLine(1, "skip-at-base", "seen on main"));
});
caseEnd();

caseBegin("record-note-is-one-line-and-capped", "bin/workflow/run-tests-baseline-evidence");
test("record-note-is-one-line-and-capped", () => {
  const r1 = recordAuto("nl", ["--note", "first\r\nsecond"]);
  assert.equal(r1.rc, 0, r1.err);
  const n1 = entry(r1.id).baseline_note;
  assert.equal(typeof n1, "string");
  assert.doesNotMatch(n1, /[\r\n]/);
  assert.ok(n1.includes("first") && n1.includes("second"), n1);
  const r2 = recordAuto("cap", ["--note", "x".repeat(400)]);
  assert.equal(r2.rc, 0, r2.err);
  assert.equal(entry(r2.id).baseline_note, "x".repeat(200));
});
caseEnd();

caseBegin("record-without-note-says-none", "bin/workflow/run-tests-baseline-evidence");
test("record-without-note-says-none", () => {
  const r = recordAuto("nonote", []);
  assert.equal(r.rc, 0, r.err);
  assert.equal(entry(r.id).baseline_note ?? null, null);
  assert.equal(NOTE.readCompletionNote(r.id), autoLine(1, "skip-at-base", "(none)"));
});
caseEnd();

caseBegin("record-note-without-value-is-usage", "bin/workflow/run-tests-baseline-evidence");
test("record-note-without-value-is-usage", () => {
  const r = recordAuto("noval", ["--note"]);
  assert.equal(r.rc, 2, r.err);
  assert.equal(entry(r.id).status, "pending");
});
caseEnd();
