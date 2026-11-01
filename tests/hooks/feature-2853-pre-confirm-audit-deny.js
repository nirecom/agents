"use strict";
// tests/hooks/feature-2853-pre-confirm-audit-deny.js
// Tests: hooks/confirm-checkpoint/pre-confirm-audit-deny.js
// Tags: scope:issue-specific, TL2, pre-confirm-audit, confirm-checkpoint, supervisor-audit, fail-closed
// #2853: auditDenyReason(sid, stage) decides, in-process, whether a plan CONFIRM may reach the receipt
// check. Skips: a non-plan stage, WORKFLOW_OFF, a session with no workflow state file. Everything else
// that cannot prove a settled (or accepted) audit denies — no sid, cap reached, a judgment that throws.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - the hook process wiring (confirm-checkpoint.js order, receipt keeping) — tests/hooks/feature-2768-plan-sync-confirm-gate.js drives it

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

delete process.env.CLAUDE_CODE_SESSION_ID;
const restore = isolate();
const ROOT = path.resolve(__dirname, "..", "..");
const S = require("../lib/pre-confirm-audit-settle");
const io = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const { getSessionStateDir } = require(path.join(ROOT, "hooks", "workflow-state"));
const PCA = require(path.join(ROOT, "hooks", "lib", "pre-confirm-audit"));
const { auditDenyReason } = require(path.join(ROOT, "hooks", "confirm-checkpoint", "pre-confirm-audit-deny"));

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) { pass += 1; console.log(`PASS ${name}`); } else { fail += 1; console.log(`FAIL ${name} :: ${String(detail).slice(0, 400)}`); }
}
// checked(fn) -> a node:test body that fails when any check() inside fn fails.
const checked = (fn) => () => {
  const before = fail;
  fn();
  assert.strictEqual(fail - before, 0, "check(s) failed; see the FAIL lines above");
};
after(() => {
  restore();
  console.log(`\n${fail === 0 ? "ALL PASS" : `${fail} FAILED, ${pass} passed`} (${pass})`);
});
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const writePlan = (sid, stage, body) => fs.writeFileSync(path.join(PLANS, `${sid}-${stage}.md`), body || `# ${stage}\n\nfixture ${stage} body\n`);
// session(opts) -> a UUID sid with an intent plan and (unless opts.noState) a workflow state file.
function session(opts) {
  const sid = crypto.randomUUID();
  fs.mkdirSync(PLANS, { recursive: true });
  writePlan(sid, "intent");
  if (!(opts && opts.noState)) {
    io.writeState(sid, io.createInitialState(sid, { cwd: process.cwd(), git_branch: "fixture" }));
    io.markStep(sid, "workflow_init", "complete");
  }
  return sid;
}
const offMarker = (sid) => fs.writeFileSync(path.join(getSessionStateDir(sid), `${sid}.workflow-off`), "fixture\n");
const SSH = require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer", "shared"));
// findingsOf(sid) -> the session's layer1 findings; notices(sid) -> those of severity notice.
function findingsOf(sid) {
  try {
    const st = require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer")).readState(sid);
    return (st && st.layer1 && Array.isArray(st.layer1.findings)) ? st.layer1.findings : [];
  } catch (_) { return []; }
}
const notices = (sid) => findingsOf(sid).filter((f) => f && f.severity === "notice");
const isAuditDeny = (r) => typeof r === "string" && r.startsWith("[pre-confirm-audit]");
// withJudge(stubs, fn) -> fn() run while PCA.judgeStage / acceptedOnError are replaced (the deny module requires PCA lazily).
function withJudge(stubs, fn) {
  const saved = { judgeStage: PCA.judgeStage, acceptedOnError: PCA.acceptedOnError };
  Object.assign(PCA, stubs);
  try { return fn(); } finally { Object.assign(PCA, saved); }
}

caseBegin("D1 control: an unsettled audit with a state file denies", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D1 control: an unsettled audit with a state file denies", checked(() => {
    const r = auditDenyReason(session(), "intent");
    check("D1 unsettled: [pre-confirm-audit] deny", isAuditDeny(r) && r.includes("not settled"), r);
}));
caseEnd();
caseBegin("D2 no workflow state file: null (the audit could never arm)", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D2 no workflow state file: null (the audit could never arm)", checked(() => {
    const r = auditDenyReason(session({ noState: true }), "intent");
    check("D2 no state file: null", r === null, r);
}));
caseEnd();
caseBegin("D3 WORKFLOW_OFF: null even with a state file and an unsettled audit", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D3 WORKFLOW_OFF: null even with a state file and an unsettled audit", checked(() => {
    const sid = session();
    offMarker(sid);
    const r = auditDenyReason(sid, "intent");
    check("D3 WORKFLOW_OFF: null", r === null, r);
}));
caseEnd();
caseBegin("D4 an empty sid denies", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D4 an empty sid denies", checked(() => {
  for (const sid of ["", undefined]) {
    const r = auditDenyReason(sid, "intent");
    check(`D4 sid ${JSON.stringify(sid)}: deny names the unresolved session`, isAuditDeny(r) && r.includes("session id is unresolved"), r);
  }
}));
caseEnd();
caseBegin("D5 cap reached without a settled run on the current plan: deny", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D5 cap reached without a settled run on the current plan: deny", checked(() => {
    const sid = session();
    // armStage is the counting arm (count_tr); the shared settle helper does not count toward the cap.
    for (let i = 0; i < 3; i++) {
      const a = PCA.armStage(sid, "clarify_intent", { cwd: process.cwd() }) || {};
      check(`D5 fixture: counted arm ${i + 1}`, a.ok === true && Boolean(a.audit_run_id), JSON.stringify(a));
      if (a.audit_run_id) S.finalize(sid, a.audit_run_id, "BLOCK");
    }
    writePlan(sid, "intent", "# intent\n\nrevised after the third BLOCK\n");
    const j = PCA.judgeStage(sid, "clarify_intent", { cwd: process.cwd() });
    check("D5 fixture: judgeStage says cap-reached", j && j.state === "cap-reached", JSON.stringify(j));
    const r = auditDenyReason(sid, "intent");
    check("D5 cap-reached: deny names the run cap", isAuditDeny(r) && r.includes("run cap"), r);
}));
caseEnd();
caseBegin("D6 a non-plan stage: null", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D6 a non-plan stage: null", checked(() => {
  for (const stage of ["docs", "release"]) {
    const r = auditDenyReason(session(), stage);
    check(`D6 ${stage}: null`, r === null, r);
  }
}));
caseEnd();
caseBegin("D7 judgeStage throws: acceptedOnError decides (accepted -> null, else deny)", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D7 judgeStage throws: acceptedOnError decides (accepted -> null, else deny)", checked(() => {
    const sid = session();
    const boom = () => { throw new Error("stub judge failure"); };
    const ok = withJudge({ judgeStage: boom, acceptedOnError: () => ({ accepted: true, runId: "run-0001" }) }, () => auditDenyReason(sid, "intent"));
    check("D7 throw + accepted: null", ok === null, ok);
    const no = withJudge({ judgeStage: boom, acceptedOnError: () => ({ accepted: false, runId: "run-0001" }) }, () => auditDenyReason(sid, "intent"));
    check("D7 throw + not accepted: deny carries the error", isAuditDeny(no) && no.includes("stub judge failure"), no);
    const both = withJudge({ judgeStage: boom, acceptedOnError: () => { throw new Error("stub acceptance failure"); } },
      () => auditDenyReason(sid, "intent"));
    check("D7 throw + acceptedOnError throws: deny", isAuditDeny(both) && both.includes("stub judge failure"), both);
}));
caseEnd();
caseBegin("D8 an unreadable state file is not an absent one: the audit check still runs", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D8 an unreadable state file is not an absent one: the audit check still runs", checked(() => {
    const sid = session();
    fs.writeFileSync(io.getStatePath(sid), "{not json");
    const r = auditDenyReason(sid, "intent");
    check("D8 corrupt workflow state, unsettled audit: deny (no absence exemption)", isAuditDeny(r) && r.includes("not settled"), r);
    const s2 = session();
    S.settle(s2, "intent", "CONTINUE");
    fs.writeFileSync(require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer", "shared")).getStatePath(s2), "{not json");
    const r2 = auditDenyReason(s2, "intent");
    check("D8 corrupt supervisor state after a settle: deny", isAuditDeny(r2), r2);
}));
caseEnd();
caseBegin("D9 no workflow state file: the skip is recorded as one notice finding", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D9 no workflow state file: the skip is recorded as one notice finding", checked(() => {
    const sid = session({ noState: true });
    const r = auditDenyReason(sid, "intent");
    check("D9 no state file: still null (no deny)", r === null, r);
    const n = notices(sid);
    check("D9 no state file: exactly one notice-severity finding", n.length === 1, JSON.stringify(findingsOf(sid)));
}));
caseEnd();
caseBegin("D10 a state file with a settled audit records no skip notice", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D10 a state file with a settled audit records no skip notice", checked(() => {
    const sid = session();
    S.settle(sid, "intent", "CONTINUE");
    const r = auditDenyReason(sid, "intent");
    check("D10 settled: null", r === null, r);
    check("D10 settled: no notice-severity finding", notices(sid).length === 0, JSON.stringify(findingsOf(sid)));
}));
caseEnd();
caseBegin("D11 a failed notice write never turns the skip into a deny", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D11 a failed notice write never turns the skip into a deny", checked(() => {
    const sid = session({ noState: true });
    // A directory where the supervisor state file belongs: every read and write of it fails.
    fs.mkdirSync(SSH.getStatePath(sid), { recursive: true });
    let r;
    try { r = auditDenyReason(sid, "intent"); } catch (e) { r = "THREW:" + e.message; }
    check("D11 unwritable supervisor state: still null (no deny, no throw)", r === null, r);
}));
caseEnd();
caseBegin("D12 a below-cap BLOCK acceptance does not carry over an outline edit: deny", "hooks/confirm-checkpoint/pre-confirm-audit-deny.js");
test("D12 a below-cap BLOCK acceptance does not carry over an outline edit: deny", checked(() => {
    const sid = session();
    writePlan(sid, "outline");
    const runB = S.settle(sid, "outline", "BLOCK");
    const { recordReviewedVerdictAcceptance } = require(path.join(ROOT, "hooks", "lib", "supervisor-block-override"));
    const acc = recordReviewedVerdictAcceptance(sid, { runId: runB, reason: "fixture: the user reviewed the findings and accepts them", actor: "test-fixture" }) || {};
    check("D12 fixture: acceptance recorded", acc.ok === true, JSON.stringify(acc));
    const pre = auditDenyReason(sid, "outline");
    check("D12 control: before the edit, the accepted BLOCK passes (null)", pre === null, pre);
    writePlan(sid, "outline", "# outline\n\nrevised after the accepted BLOCK\n");
    const r = auditDenyReason(sid, "outline");
    check("D12 after the edit: CONFIRM_OUTLINE [pre-confirm-audit] deny, not settled",
      isAuditDeny(r) && r.includes("CONFIRM_OUTLINE") && r.includes("not settled"), r);
}));
caseEnd();
