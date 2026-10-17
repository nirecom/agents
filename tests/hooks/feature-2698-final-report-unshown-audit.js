"use strict";
// Tests: hooks/lib/final-report-schema.js
// Tags: TL2, hooks, final-report, supervisor, audit, unshown-run, scope:issue-specific
// #2698 3-7: a run armed but never shown (deferred by the post-alert window, session ended first)
// is reported in the existing <SUPERVISOR_AUDIT_SUMMARY> line only: ", unlaunched audit: <run-id>"
// is appended to that one line, no line is added, and without an unshown run the output is identical.
// TL3 gap (what this test does NOT catch):
// - the session-close skill actually printing the rendered report to the user
// Closest-to-action mitigation: the supervisor state is produced by the real armAuditRun writer.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");
const X = require("./feature-2698-supervisor/fixture");
const S = require("./feature-2698-supervisor/audit-scene");
const { renderFinalReport } = require("../../hooks/lib/final-report-schema");

const restore = isolate();
process.env.CONV_LANG = "english";
const ROOT = X.tmpRoot("frep");
after(() => { restore(); X.rmRoot(ROOT); });

const SID = "frep-sid";
const render = (supervisorState) => renderFinalReport(SID, {
  env: {}, outcome: null, closesIssues: [], notesSections: { bugs: "- (none)", related: "- (none)", next: "- (none)" },
  supervisorState,
});
const auditLine = (out) => {
  const lines = out.split("\n");
  const i = lines.indexOf("### Supervisor Audit");
  return lines[i + 1];
};
const BASE = (a) => `phase: ${a.audit_phase || "none"}, verdict: ${a.audit_verdict || "none"}, cause: ${a.audit_cause || "none"}`;

caseBegin("unshown-run-one-line-suffix", "hooks/lib/final-report-schema.js");
test("an unshown pending run -> the audit summary line gains ', unlaunched audit: <run-id>'; line count unchanged", () => {
  const s = S.scene(ROOT, "uns", {});
  S.armUnshown(s);
  const state = X.readSup(s.dir, s.sid);
  assert.strictEqual(state.audit.audit_dispatched_at, null, "fixture: the run is unshown");
  const out = render(state);
  assert.strictEqual(auditLine(out), `${BASE(state.audit)}, unlaunched audit: run-0001`);
  const shownState = JSON.parse(JSON.stringify(state));
  shownState.audit.audit_dispatched_at = new Date().toISOString();
  assert.strictEqual(out.split("\n").length, render(shownState).split("\n").length, "no line is added");
});
caseEnd();

caseBegin("no-unshown-run-identical-output", "hooks/lib/final-report-schema.js");
test("a shown pending run -> the line is exactly today's", () => {
  const s = S.scene(ROOT, "shown", {});
  S.armUnshown(s);
  S.writer(s.dir, "writeAuditState", s.sid, { audit_dispatched_at: new Date().toISOString() });
  const state = X.readSup(s.dir, s.sid);
  assert.strictEqual(auditLine(render(state)), BASE(state.audit));
  assert.ok(!render(state).includes("unlaunched audit"));
});
test("a terminal run and an empty state -> the line is exactly today's", () => {
  const s = S.scene(ROOT, "done", {});
  S.armUnshown(s);
  S.writer(s.dir, "finalizeAuditRun", s.sid, { audit_run_id: "run-0001", verdict: "CONTINUE", verdict_summary: "ok" });
  const done = X.readSup(s.dir, s.sid);
  assert.strictEqual(auditLine(render(done)), BASE(done.audit));
  assert.strictEqual(auditLine(render(null)), "(not run)");
  assert.strictEqual(auditLine(render({ audit: {} })), "phase: none, verdict: none, cause: none");
});
caseEnd();
