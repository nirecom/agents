"use strict";
// Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/core.js
// Tags: TL2, hooks, workflow-state, state-io, scope:common
// #2828 (d): the view composeAppendedState hands an appendEvents builder is the full state view
// readState returns (persisted top level + `current` + PROJECTION_KEYS), not a bare projection;
// a builder writing to it cannot change the stream; the evaluator view still accepts a resumed
// session's upstream-bound approval. Fixture: tests/bin/feat-2529-glossary-drift/fixture.js.
// TL3 gap (what this test does NOT catch):
// - a real resumed session's state file produced by session inheritance, not the fixture copy.
// Closest-to-action mitigation: tests/hooks/feat-2529-glossary-accept.js drives the real handler.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after: afterAll } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "f2828-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
process.chdir(os.tmpdir());

// The plan-stage CONFIRM flags are read from $AGENTS_MAIN_ROOT/.env only: pin every gate on, so
// the completion boundary in the evaluator-view case never depends on the ambient config.
const CE = require("../lib/confirm-env-fixture");
process.env.AGENTS_MAIN_ROOT = CE.confirmEnvRoot(fs.mkdtempSync(path.join(os.tmpdir(), "f2828-cfg-")),
  { CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on" });
for (const k of CE.PLAN_KEYS) delete process.env[k];

const F = require("../bin/feat-2529-glossary-drift/fixture");
const SIO = require(path.join(F.ROOT, "hooks/workflow-state/state-io.js"));
afterAll(() => {
  F.finish();
  restore();
});

const TOP = { first_session_id: "f2828-first", previous_session_ids: ["f2828-first"], upstream_session_id: "f2828-first", deliverable_type: "wf-code" };
const note = (step, value) => ({ kind: "step_annotation", step, key: "reopen_reason", value, provenance: "observed", origin: "test-fixture" });

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

// A persisted session carrying the ancestry fields; → the view its builder receives.
function seeded(tag) {
  const sid = F.newSid(tag);
  SIO.writeState(sid, Object.assign(SIO.createInitialState(sid, { cwd: os.tmpdir(), git_branch: "feature/f2828" }), TOP));
  SIO.appendEvents(sid, [note("write_tests", "seed")]);
  let view = null;
  SIO.appendEvents(sid, (_events, v) => { view = v; return []; });
  return { sid, view, raw: JSON.parse(F.rawState(sid)) };
}

caseBegin("builder view carries the persisted top-level fields (d1)", "hooks/workflow-state/state-io/events.js");
test("d1", () => noNewFailures(F.failureCount, () => guarded("d1", () => {
  const s = seeded("d1");
  F.check("d1: the builder received a view", !!s.view && typeof s.view === "object", String(s.view));
  for (const key of Object.keys(TOP).concat(["session_id"])) {
    F.check(`d1: view.${key} equals the persisted value`,
      !!s.view && JSON.stringify(s.view[key]) === JSON.stringify(s.raw[key]) && s.raw[key] !== undefined,
      `view=${JSON.stringify(s.view && s.view[key])} persisted=${JSON.stringify(s.raw[key])}`);
  }
})));
caseEnd();

caseBegin("builder view projection keys and current equal projectState (d2)", "hooks/workflow-state/state-io/projection.js");
test("d2", () => noNewFailures(F.failureCount, () => guarded("d2", () => {
  const s = seeded("d2");
  const want = SIO.projectState(s.raw);
  for (const key of SIO.PROJECTION_KEYS) {
    let same = true;
    try { assert.deepStrictEqual(s.view && s.view[key], want[key]); } catch (e) { same = false; }
    F.check(`d2: view.${key} deep-equals projectState`, same, JSON.stringify(s.view && s.view[key]));
  }
  let same = true;
  try { assert.deepStrictEqual(s.view && s.view.current, want); } catch (e) { same = false; }
  F.check("d2: view.current deep-equals projectState", same, String(JSON.stringify(s.view && s.view.current)));
})));
caseEnd();

caseBegin("builder writing to view.events cannot change the stream (d3)", "hooks/workflow-state/state-io/events.js");
test("d3", () => noNewFailures(F.failureCount, () => guarded("d3", () => {
  const s = seeded("d3");
  const n = s.raw.events.length;
  let pushed = false;
  SIO.appendEvents(s.sid, (_events, v) => {
    if (v && Array.isArray(v.events)) { v.events.push({}); pushed = true; }
    return [note("write_tests", "d3")];
  });
  F.check("d3: the view carried an events array the builder wrote to", pushed, "view.events missing");
  const after = JSON.parse(F.rawState(s.sid)).events;
  F.check("d3: the persisted stream grew by exactly one event", after.length === n + 1, `before=${n} after=${after.length}`);
  F.check("d3: seq stays contiguous from 1", after.every((e, i) => e && e.seq === i + 1), JSON.stringify(after.map((e) => e && e.seq)));
})));
caseEnd();

caseBegin("builder view has the same key set as readState (d4)", "hooks/workflow-state/state-io/core.js");
test("d4", () => noNewFailures(F.failureCount, () => guarded("d4", () => {
  const s = seeded("d4");
  const read = Object.keys(SIO.readState(s.sid) || {}).sort();
  const view = Object.keys(s.view || {}).sort();
  F.check("d4: enumerable keys of readState and of the builder view match", JSON.stringify(read) === JSON.stringify(view),
    `readState=${read.join(",")} view=${view.join(",")}`);
})));
caseEnd();

caseBegin("composeAppendedState hands the view on a bare base without I/O (d5)", "hooks/workflow-state/state-io/events.js");
test("d5", () => noNewFailures(F.failureCount, () => guarded("d5", () => {
  const sid = F.newSid("d5");
  let view = null;
  const out = SIO.composeAppendedState(sid, SIO.createInitialState(sid, { cwd: os.tmpdir() }), (_events, v) => {
    view = v;
    return [note("write_tests", "d5")];
  });
  F.check("d5: the builder received a view with session_id and current",
    !!view && view.session_id === sid && !!view.current && typeof view.current === "object", JSON.stringify(view && Object.keys(view)));
  F.check("d5: one event appended", !!out && Array.isArray(out.appended) && out.appended.length === 1, JSON.stringify(out && out.appended));
  F.check("d5: no state file was written for the sid", !fs.existsSync(F.statePath(sid)), F.statePath(sid));
})));
caseEnd();

caseBegin("evaluator view accepts a resumed session's upstream-bound outline approval (d6)", "hooks/workflow-state/state-io/events.js");
test("d6", () => noNewFailures(F.failureCount, () => guarded("d6", () => {
  const repo = F.mkRepo("d6");
  const up = F.newSid("d6-up");
  const sid = F.newSid("d6");
  F.writeIntent(up);
  F.writePlan(up, "outline", "# Outline\n\n## Approach\n\nMid-line the glossary drift appears.\n");
  F.seedAt(sid, "outline", repo, { firstSid: up });
  const d = F.drift(sid, "outline", repo, true);
  const rec = F.recordOf(sid, "outline");
  F.check("d6 precondition: --record exits 0 with a fingerprinted record and no finding",
    F.reached(d) && d.code === 0 && !!rec && typeof rec.fingerprint === "string" && Array.isArray(rec.findings) && rec.findings.length === 0,
    `code=${d.code} ${JSON.stringify(rec)} ${d.all}`);
  let threw = null;
  try {
    SIO.appendEvents(sid, [F.approvalEvent(up, "outline"), F.statusEvent("outline", "complete")], { repoDir: repo });
  } catch (e) {
    threw = e;
  }
  F.check("d6: completing outline with the upstream-bound approval is not refused", threw === null, threw && threw.message);
  // repoDir: the glossary fingerprint of a complete R-A stage is read from the fixture repo, not the cwd.
  const { resolveCurrentStep } = require(path.join(F.ROOT, "hooks/workflow-state/current-step.js"));
  const cur = resolveCurrentStep(F.readState(sid), { sessionId: sid, repoDir: repo });
  F.check("d6: the current step moves on to detail", cur === "detail", String(cur));
})));
caseEnd();
