"use strict";
// Tests: hooks/lib/supervisor-state-writer/append.js, hooks/lib/supervisor-state-writer/alert.js, bin/supervisor-write-alert
// Tags: TL2, hooks, supervisor, em-supervisor, alert, paused, rearm, writer, resume, scope:issue-specific
// #2698 change 2: a paused (frozen) alert is never re-armed by a new finding — on the dedup
// collapse, the class-dedup and the plain append exit alike the phase stays paused, armed_at
// stays null and the finding is still recorded. Only the explicit resume
// (bin/supervisor-write-alert --set-alert-phase pending --alert-armed-at <iso>) leaves paused,
// and it resets alert_retry_count to 0 so the first block after it does not re-freeze.
// TL3 gap (what this test does NOT catch):
// - a live supervisor subagent following the resume protocol written in agents/supervisor.md
// Closest-to-action mitigation: the real CLI runs here as a child process.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const REPO = path.resolve(__dirname, "..", "..");
const restore = isolate();
for (const k of ["CONV_LANG", "ENFORCE_WORKFLOW", "ENFORCE_WORKTREE", "CONFIRM_RELEASE"]) delete process.env[k];
process.env.CONV_LANG = "english";
after(() => restore());

const W = require(path.join(REPO, "hooks", "lib", "supervisor-state-writer.js"));
const S = require(path.join(REPO, "hooks", "lib", "supervisor-state-schema.js"));
const CLI = path.join(REPO, "bin", "supervisor-write-alert");

let seq = 0;
// seedPaused(findings) — a fresh session whose alert is frozen (paused, armed_at null, retry 2).
function seedPaused(findings = []) {
  const sid = `p2698-${process.pid}-${++seq}`;
  const st = S.createEmptyState(sid);
  st.alert = {
    alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [],
    alert_phase: "paused", alert_cause: null, alert_retry_count: S.ALERT_RETRY_THRESHOLD,
  };
  st.layer1.findings = findings;
  fs.writeFileSync(W.getStatePath(sid, { forWrite: true }), JSON.stringify(st));
  return sid;
}
const F = (detail, reporter = "test") => ({ categories: ["workflow"], severity: "error", detail, reporter });
const stamped = (f) => ({ ...f, timestamp: new Date().toISOString() });

function assertStillPaused(sid, label) {
  const st = W.readState(sid);
  assert.ok(st, `${label}: state readable`);
  assert.strictEqual(st.alert.alert_phase, "paused", `${label}: alert_phase stays paused`);
  assert.strictEqual(st.alert.alert_armed_at, null, `${label}: alert_armed_at stays null`);
  assert.strictEqual(st.alert.alert_retry_count, S.ALERT_RETRY_THRESHOLD, `${label}: retry count unchanged`);
  return st;
}

caseBegin("paused-not-rearmed-by-any-append-exit", "hooks/lib/supervisor-state-writer/append.js");
test("plain append on paused: finding pushed, phase stays paused, armed_at null", () => {
  const sid = seedPaused();
  assert.strictEqual(W.appendFinding(sid, F("plain after freeze")), true);
  const st = assertStillPaused(sid, "plain append");
  assert.ok(st.layer1.findings.some((f) => f.detail === "plain after freeze"), "finding recorded");
});
test("dedup collapse on paused (same finding as the last one): stays paused, armed_at null", () => {
  const f = F("same finding");
  const sid = seedPaused([stamped(f)]);
  assert.strictEqual(W.appendFinding(sid, f), true);
  const st = assertStillPaused(sid, "dedup collapse");
  assert.strictEqual(st.layer1.findings.length, 1, "the collapsed finding stays recorded once");
});
test("class dedup on paused (same reporter + command): count bumped, stays paused, armed_at null", () => {
  const sid = seedPaused([stamped(F("hook blocked: rule-a on git push origin x", "enforce-x"))]);
  assert.strictEqual(W.appendFinding(sid, F("hook blocked: rule-b on git push origin x", "enforce-x")), true);
  const st = assertStillPaused(sid, "class dedup");
  assert.strictEqual(st.layer1.findings.length, 1);
  assert.strictEqual(st.layer1.findings[0].class_dedup_count, 2, "the class occurrence is still counted");
});
test("ensureAlertScheduled(state) on paused leaves the alert untouched", () => {
  const state = { alert: { alert_armed_at: null, alert_phase: "paused", alert_retry_count: 2, findings: [] } };
  W.ensureAlertScheduled(state, "unit-sid", F("x"));
  assert.deepStrictEqual(state.alert, { alert_armed_at: null, alert_phase: "paused", alert_retry_count: 2, findings: [] });
});
caseEnd();

caseBegin("explicit-resume-resets-retry", "hooks/lib/supervisor-state-writer/alert.js");
test("writeAlertState paused -> pending without alert_retry_count resets the count to 0", () => {
  const sid = seedPaused();
  assert.strictEqual(W.writeAlertState(sid, { alert_phase: "pending", alert_armed_at: new Date().toISOString() }), true);
  const st = W.readState(sid);
  assert.strictEqual(st.alert.alert_phase, "pending");
  assert.strictEqual(st.alert.alert_retry_count, 0, "retry count reset on the paused -> pending resume");
});
test("after a resume, the first block (one retry increment) does not re-freeze", () => {
  const sid = seedPaused();
  assert.strictEqual(W.writeAlertState(sid, { alert_phase: "pending", alert_armed_at: new Date().toISOString() }), true);
  const r = W.incrementAlertRetryCount(sid);
  assert.strictEqual(r.frozen, false, `first increment after resume must not freeze (got ${JSON.stringify(r)})`);
  assert.strictEqual(W.readState(sid).alert.alert_phase, "pending");
});
caseEnd();

caseBegin("cli-resume-from-paused", "bin/supervisor-write-alert");
test("bin/supervisor-write-alert --set-alert-phase pending --alert-armed-at <iso> resumes a paused alert", () => {
  const sid = seedPaused();
  const iso = new Date().toISOString();
  const r = spawnSync(process.execPath, [CLI, "--session-id", sid, "--set-alert-phase", "pending", "--alert-armed-at", iso],
    { encoding: "utf8", env: process.env, timeout: 30000 });
  assert.strictEqual(r.status, 0, `CLI exit 0 (stderr: ${r.stderr})`);
  const st = W.readState(sid);
  assert.strictEqual(st.alert.alert_phase, "pending");
  assert.strictEqual(st.alert.alert_armed_at, iso);
  assert.strictEqual(st.alert.alert_retry_count, 0);
  assert.strictEqual(W.incrementAlertRetryCount(sid).frozen, false, "first block after the CLI resume does not re-freeze");
});
caseEnd();
