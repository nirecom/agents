#!/usr/bin/env node
"use strict";
// Tests: hooks/workflow-state/state-io.js, hooks/lib/run-tests-completion-note.js
// Tags: TL2, run-tests, baseline, legacy, compatibility, completion-note, workflow-state, scope:issue-specific
// #2688 T8 — a state completed by a user grant before #2688 (baseline_accept annotation and
// completion_basis baseline-user-accepted) still reads as complete after the grant mechanism is gone,
// and its completion note becomes a fixed legacy line. The grant reason is never re-read.
// TL3 gap: uses an event sequence rebuilt with appendEvents, not a real old session state file.

const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rtb-2688-legacy-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const { appendEvents } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "events"));
const { readState } = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const NOTE = require(path.join(ROOT, "hooks", "lib", "run-tests-completion-note.js"));

const LEGACY = "- Unverified tests: failing tests accepted by the user before #2688 (legacy grant; details not re-read)";
const ev = (o) => Object.assign({ step: "run_tests", provenance: "observed", origin: "run-tests-baseline-evidence" }, o);
const a = (key, value) => ev({ kind: "step_annotation", key, value });
// The grant annotation the old accept wrote (declared provenance, old origin).
const grant = (g) => Object.assign(a("baseline_accept", Object.assign({ run_seq: 1, outcome_source: null }, g)),
  { provenance: "declared", origin: "workflow-mark-run-tests-baseline-accept" });

const SHAPES = {
  undetermined: [
    a("baseline_classification", { base: "abc", entries: [{ path: "t/a.sh", class: "undetermined", detail: "budget-exhausted" }] }),
    grant({ reason: "seen red on main", kind: "undetermined", accepted_run_outcome: "fail" })],
  nolist: [grant({ reason: "flaky on main", kind: "failing-list-unrecorded", accepted_run_outcome: "timeout" })],
};

function seedLegacy(id, shape) {
  appendEvents(id, [ev({ kind: "step_status", status: "pending" }), ...SHAPES[shape],
    a("run_outcome", "pass"), a("completion_basis", "baseline-user-accepted"), ev({ kind: "step_status", status: "complete" })]);
}

const sidOf = (shape) => `legacy-${shape}-${process.pid}`;
for (const shape of Object.keys(SHAPES)) seedLegacy(sidOf(shape), shape);

caseBegin("legacy-state-still-reads-complete", "hooks/workflow-state/state-io.js");
test("legacy-state-still-reads-complete", () => {
  for (const shape of Object.keys(SHAPES)) {
    const s = readState(sidOf(shape));
    assert.ok(s && s.steps && s.steps.run_tests, `${shape}: run_tests projected`);
    const e = s.steps.run_tests;
    assert.equal(e.status, "complete", shape);
    assert.equal(e.completion_basis, "baseline-user-accepted", shape);
    assert.equal(e.run_outcome, "pass", shape);
  }
});
caseEnd();

caseBegin("legacy-state-gets-the-fixed-line", "hooks/lib/run-tests-completion-note.js");
test("legacy-state-gets-the-fixed-line", () => {
  for (const shape of Object.keys(SHAPES)) {
    const line = NOTE.readCompletionNote(sidOf(shape));
    assert.equal(line, LEGACY, shape);
  }
});
caseEnd();

caseBegin("legacy-line-does-not-reread-the-grant", "hooks/lib/run-tests-completion-note.js");
test("legacy-line-does-not-reread-the-grant", () => {
  for (const shape of Object.keys(SHAPES)) {
    const line = String(NOTE.readCompletionNote(sidOf(shape)));
    assert.doesNotMatch(line, /seen red on main|flaky on main|budget-exhausted|run_outcome=/, shape);
  }
});
caseEnd();

caseBegin("legacy-grant-without-basis-is-silent", "hooks/lib/run-tests-completion-note.js");
test("legacy-grant-without-basis-is-silent", () => {
  // With only the grant annotation left and no basis (a later green run cleared it), no line is shown.
  const id = `legacy-tomb-${process.pid}`;
  seedLegacy(id, "undetermined");
  appendEvents(id, [ev({ kind: "step_status", status: "pending" }), a("completion_basis", null),
    a("run_outcome", "pass"), ev({ kind: "step_status", status: "complete" })]);
  assert.equal(NOTE.readCompletionNote(id), null);
});
caseEnd();
