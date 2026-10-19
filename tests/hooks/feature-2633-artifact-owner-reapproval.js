#!/usr/bin/env node
// tests/hooks/feature-2633-artifact-owner-reapproval.js
// Tests: hooks/workflow-state/plan-artifact-owner.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/confirm-approval-handler.js, hooks/workflow-mark.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/evidence-resolver.js, hooks/lib/plan-link.js, hooks/workflow-state/session-facts.js, hooks/lib/wf-target-repos.js, hooks/lib/diff-fingerprint.js, hooks/lib/branch-diff.js, bin/workflow/lib/next-step/gate-mode.js
// Tags: scope:issue-specific, workflow-state, plan-approval
"use strict";
// #2633-2: a downstream session D (upstream_session_id = U) holds no plan artifact of its own;
// the approval-gated artifacts stay named <U>-<stage>.md. Re-approving a stage in D must hash U's
// file, and every reader on the finish path must resolve the owner instead of <D>-<stage>.md.
// CONFIRM_INTENT / CONFIRM_OUTLINE / CONFIRM_DETAIL are pinned "on" through a fixture config root
// except in the one config-dependent case.

const os = require("os");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const restore = isolate();
const savedRoot = process.env.AGENTS_MAIN_ROOT;
const savedCwd = process.cwd();
const F = require("./feature-2633-artifact-owner-reapproval/fixture");
const work = path.dirname(process.env.WORKFLOW_STATE_DIR);
process.chdir(work);
const ON_ROOT = F.configRoot("on", ["CONFIRM_INTENT=on", "CONFIRM_OUTLINE=on", "CONFIRM_DETAIL=on"]);
const OFF_ROOT = F.configRoot("off", ["CONFIRM_INTENT=off", "CONFIRM_OUTLINE=off", "CONFIRM_DETAIL=off"]);
process.env.AGENTS_MAIN_ROOT = ON_ROOT;

const OWNER = "hooks/workflow-state/plan-artifact-owner.js";
const owner = () => F.load(OWNER);
const CA = () => F.load("hooks/workflow-state/completion-approval.js");
const WS = () => F.load("hooks/workflow-state");
const STEPS = ["clarify_intent", "outline", "detail"];

// downstream(steps) — U owns the artifacts of `steps`; D carries upstream_session_id = U only.
function downstream(steps, extraEvents) {
  const U = F.newSid();
  const D = F.newSid();
  for (const s of steps) F.writePlan(U, F.SUFFIX[s]);
  F.writeState(U, null, []);
  F.writeState(D, { upstream_session_id: U, upstream_copy_seq: 0 }, extraEvents || []);
  return { U, D };
}

// confirm(sid, step) -> the handler's pushed messages.
function confirm(sid, step) {
  const msgs = [];
  const cmd = `echo "<<${CA().confirmSentinelFor(step)}: fixture approval>>"`;
  F.load("hooks/workflow-mark/confirm-approval-handler.js").handle({ cmd, sessionId: sid, pushMessage: (m) => msgs.push(m) });
  return msgs.join("\n");
}
// confirmViaHook(sid, step) -> additionalContext + stderr of one real hooks/workflow-mark.js run.
function confirmViaHook(sid, step) {
  const command = `echo "<<${CA().confirmSentinelFor(step)}: fixture approval>>"`;
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command, cwd: work }, tool_response: { exit_code: 0 } };
  const r = spawnSync(process.execPath, [path.join(F.ROOT, "hooks", "workflow-mark.js")],
    { input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env), cwd: work });
  if (r.error) throw new Error(`hook did not run: ${r.error.message}`);
  let out = {};
  try { out = JSON.parse(String(r.stdout || "").trim().split("\n").pop() || "{}"); } catch (_) { out = {}; }
  return String(out.additionalContext || "") + String(r.stderr || "");
}
const approvalOf = (sid, step) => ((WS().readState(sid) || {}).plan_approvals || {})[step] || null;
const statusOf = (sid, step) => (((WS().readState(sid) || {}).steps || {})[step] || {}).status;

caseBegin("owner-resolver-own-upstream-missing", "hooks/workflow-state/plan-artifact-owner.js");
F.run("resolver basic", () => {
  F.check("resolvePlanArtifactOwner is exported", typeof owner().resolvePlanArtifactOwner === "function", "missing export");
  const { U, D } = downstream(["outline"]);
  let r = owner().resolvePlanArtifactOwner(D, "outline");
  F.check("upstream-only -> via upstream, owner U", r.via === "upstream" && r.ownerSid === U && r.exists === true &&
    F.samePath(r.path, F.planPath(U, "outline")), JSON.stringify(r));
  F.writePlan(D, "outline", F.body("outline", "own-D"));
  r = owner().resolvePlanArtifactOwner(D, "outline");
  F.check("own file wins over upstream", r.via === "own" && r.ownerSid === D && F.samePath(r.path, F.planPath(D, "outline")), JSON.stringify(r));
  r = owner().resolvePlanArtifactOwner(D, "detail");
  F.check("nothing anywhere -> missing, own path", r.via === "missing" && r.ownerSid === D && r.exists === false, JSON.stringify(r));
});
caseEnd();

caseBegin("owner-resolver-approval-record-and-history", "hooks/workflow-state/plan-artifact-owner.js");
F.run("resolver approval chain", () => {
  const X = F.newSid();
  const xBody = F.body("outline", "X");
  F.writePlan(X, "outline", xBody);
  const D1 = F.newSid();
  F.writeState(D1, null, [F.approvalEvent("outline", X, F.sha(xBody))]);
  let r = owner().resolvePlanArtifactOwner(D1, "outline");
  F.check("live approval record names X -> via approval-record", r.via === "approval-record" && r.ownerSid === X, JSON.stringify(r));
  // X -> U -> D chain: the record was revoked, U holds no outline; history still names X.
  const U = F.newSid();
  const D2 = F.newSid();
  F.writeState(D2, { upstream_session_id: U, upstream_copy_seq: 2 },
    [F.approvalEvent("outline", X, F.sha(xBody)), F.revokeEvent("outline")]);
  r = owner().resolvePlanArtifactOwner(D2, "outline");
  F.check("revoked record -> via approval-history, owner X", r.via === "approval-history" && r.ownerSid === X, JSON.stringify(r));
});
caseEnd();

caseBegin("inheritance-reverts-approval-bound-to-earlier-generation", "hooks/workflow-state/completion-approval.js");
F.run("chained adoption with an upstream-owned artifact", () => {
  const apply = () => F.load("hooks/workflow-state/inheritance/apply.js");
  const at = new Date().toISOString();
  // X -> U -> D: U carries X's approval (outline complete); D adopts U.
  const chain = (uOwnsOutline) => {
    const X = F.newSid();
    const xBody = F.body("outline", "X-gen");
    F.writePlan(X, "outline", xBody);
    const U = F.newSid();
    F.writeState(U, { upstream_session_id: X, upstream_copy_seq: 0 },
      [F.approvalEvent("outline", X, F.sha(xBody)), F.statusEvent("outline", "complete")]);
    if (uOwnsOutline) F.writePlan(U, "outline", F.body("outline", "U-own"));
    const D = F.newSid();
    F.writeState(D, null, []);
    return { U, D, res: apply().applyInheritance(D, at, U) };
  };
  const ctl = chain(false);
  F.check("control: U without its own outline -> outline stays complete", statusOf(ctl.D, "outline") === "complete",
    JSON.stringify(ctl.res.reverted_steps));
  const { D, res } = chain(true);
  const rv = (res.reverted_steps || []).find((r) => r.step === "outline");
  F.check("U owns its outline -> outline reverted to pending", statusOf(D, "outline") === "pending", statusOf(D, "outline"));
  F.check("revert names the approval mismatch", rv && rv.cause === "approval" && rv.code === "artifact-hash-mismatch",
    JSON.stringify(res.reverted_steps));
});
caseEnd();

caseBegin("owner-resolver-rejects-traversal-and-honors-plans-dir", "hooks/workflow-state/plan-artifact-owner.js");
F.run("resolver security", () => {
  const D = F.newSid();
  const evil = "evil-" + F.newSid();
  fs.writeFileSync(path.join(work, `${evil}-outline.md`), "# planted\n");
  F.writeState(D, { upstream_session_id: `../${evil}` }, []);
  const r = owner().resolvePlanArtifactOwner(D, "outline");
  F.check("traversal upstream sid is never used", r.via === "missing" && r.ownerSid === D && !String(r.path).includes(evil), JSON.stringify(r));
  const alt = path.join(work, "alt-plans");
  const { U, D: D2 } = downstream([]);
  F.writePlan(U, "intent", null, alt);
  const r2 = owner().resolvePlanArtifactOwner(D2, "intent", undefined, { plansDir: alt });
  F.check("opts.plansDir is honored", r2.via === "upstream" && F.samePath(r2.path, F.planPath(U, "intent", alt)), JSON.stringify(r2));
});
caseEnd();

caseBegin("confirm-outline-in-downstream-hashes-upstream-and-completes", "hooks/workflow-mark/confirm-approval-handler.js");
F.run("downstream outline re-approval", () => {
  const { U, D } = downstream(["outline"]);
  const msg = confirm(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("artifact_session_id is U", rec && rec.artifact_session_id === U && rec.artifact_hash_status === "recorded", msg + " " + JSON.stringify(rec));
  F.check("message names the hashed upstream file", msg.includes(`hashed ${U}-outline.md (owned by session upstream)`), msg);
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("evaluation approved", v.approved === true, JSON.stringify(v));
  WS().markStep(D, "outline", "complete");
  F.check("markStep(D, outline, complete) persists", statusOf(D, "outline") === "complete", statusOf(D, "outline"));
});
caseEnd();

caseBegin("confirm-intent-and-detail-in-downstream-complete", "hooks/workflow-mark/confirm-approval-handler.js");
F.run("downstream intent/detail re-approval", () => {
  for (const step of ["clarify_intent", "detail"]) {
    const { U, D } = downstream([step]);
    const msg = confirm(D, step);
    const rec = approvalOf(D, step);
    F.check(`${step}: artifact_session_id is U`, rec && rec.artifact_session_id === U, msg);
    WS().markStep(D, step, "complete");
    F.check(`${step}: completes in D`, statusOf(D, step) === "complete", statusOf(D, step));
  }
});
caseEnd();

caseBegin("confirm-outline-in-downstream-through-registered-hook", "hooks/workflow-mark.js");
F.run("downstream outline re-approval via workflow-mark.js subprocess", () => {
  const { U, D } = downstream(["outline"]);
  const msg = confirmViaHook(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("hook records an approval for D", rec !== null, msg);
  F.check("hook: artifact_session_id (owner) is U", rec && rec.artifact_session_id === U && rec.artifact_hash_status === "recorded", msg + " " + JSON.stringify(rec));
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("hook: evaluation approved", v.approved === true, JSON.stringify(v));
});
caseEnd();

caseBegin("confirm-prefers-own-artifact", "hooks/workflow-mark/confirm-approval-handler.js");
F.run("own artifact preferred", () => {
  const { D } = downstream(["outline"]);
  F.writePlan(D, "outline", F.body("outline", "own-D"));
  const msg = confirm(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("artifact_session_id is D", rec && rec.artifact_session_id === D, msg);
  F.check("no upstream-owner note", !msg.includes("owned by session upstream") && msg.includes("hash-status: recorded"), msg);
});
caseEnd();

caseBegin("own-artifact-written-after-upstream-bound-approval-needs-reapproval", "hooks/workflow-state/completion-approval.js");
F.run("stale upstream-bound approval", () => {
  const { U, D } = downstream(["outline"]);
  confirm(D, "outline");
  F.check("approval bound to U", (approvalOf(D, "outline") || {}).artifact_session_id === U, JSON.stringify(approvalOf(D, "outline")));
  F.writePlan(D, "outline", F.body("outline", "own-D-later"));
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("stale approval -> artifact-hash-mismatch", v.approved === false && v.code === "artifact-hash-mismatch", JSON.stringify(v));
  let threw = null;
  try { WS().markStep(D, "outline", "complete"); } catch (e) { threw = e; }
  F.check("markStep(complete) refused with the mismatch code", threw !== null && threw.code === "artifact-hash-mismatch",
    threw ? `${threw.code} ${threw.message}` : "no throw");
  F.check("outline stays not complete", statusOf(D, "outline") !== "complete", statusOf(D, "outline"));
  confirm(D, "outline");
  F.check("re-approval binds to D", (approvalOf(D, "outline") || {}).artifact_session_id === D, JSON.stringify(approvalOf(D, "outline")));
  WS().markStep(D, "outline", "complete");
  F.check("completes after re-approval", statusOf(D, "outline") === "complete", statusOf(D, "outline"));
});
caseEnd();

caseBegin("confirm-without-any-artifact-is-unverifiable", "hooks/workflow-mark/confirm-approval-handler.js");
F.run("no artifact", () => {
  const { D } = downstream([]);
  const msg = confirm(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("downstream: recorded as uncomputable-at-record", rec && rec.artifact_hash_status === "uncomputable-at-record" &&
    msg.includes("hash-status: uncomputable-at-record"), msg);
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("downstream: artifact-hash-unverifiable", v.approved === false && v.code === "artifact-hash-unverifiable", JSON.stringify(v));
  const S = F.newSid();
  F.writeState(S, null, []);
  const msg2 = confirm(S, "outline");
  const v2 = CA().evaluateCompletionApproval(S, "outline", WS().readState(S));
  F.check("regular session: unchanged unverifiable verdict", msg2.includes("uncomputable-at-record") &&
    v2.code === "artifact-hash-unverifiable", msg2 + " " + JSON.stringify(v2));
});
caseEnd();

caseBegin("record-plan-approval-artifact-session-id-field", "hooks/workflow-state/completion-approval.js");
F.run("artifactSessionId field", () => {
  const S = F.newSid();
  F.writeState(S, null, []);
  const fields = (owner) => ({ source: "confirm-sentinel", reason: "r", artifactSha: "a".repeat(64), artifactHashStatus: "recorded", artifactSessionId: owner });
  const stateFile = path.join(process.env.WORKFLOW_STATE_DIR, `${S}.json`);
  const before = fs.readFileSync(stateFile);
  let threw = null;
  try { CA().recordPlanApproval(S, "outline", fields("../../etc/passwd")); } catch (e) { threw = e; }
  F.check("traversal artifactSessionId throws", threw !== null, "no throw");
  F.check("rejected call leaves the whole state file byte-identical (no owner-null approval)",
    Buffer.compare(before, fs.readFileSync(stateFile)) === 0, "state file changed after a rejected call");
  F.check("rejected record never lands", approvalOf(S, "outline") === null, JSON.stringify(approvalOf(S, "outline")));
  const U = F.newSid();
  const rec = CA().recordPlanApproval(S, "outline", fields(U));
  F.check("valid artifactSessionId is recorded", rec && rec.artifact_session_id === U, JSON.stringify(rec));
});
caseEnd();

caseBegin("evaluate-backfills-owner-for-record-without-session", "hooks/workflow-state/completion-approval.js");
F.run("evaluate backfill", () => {
  const U = F.newSid();
  const D = F.newSid();
  const text = F.body("outline", "U-eval");
  F.writePlan(U, "outline", text);
  F.writeState(D, { upstream_session_id: U, upstream_copy_seq: 0 }, [F.approvalEvent("outline", null, F.sha(text))]);
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("record without artifact_session_id verifies against U", v.approved === true, JSON.stringify(v));
  // A record that names its owner is bound to it: editing U's file afterwards is a mismatch.
  const D2 = F.newSid();
  F.writeState(D2, { upstream_session_id: U, upstream_copy_seq: 0 }, [F.approvalEvent("outline", U, F.sha(text))]);
  F.writePlan(U, "outline", text + "\nedited after approval\n");
  const v2 = CA().evaluateCompletionApproval(D2, "outline", WS().readState(D2));
  F.check("edited upstream artifact -> artifact-hash-mismatch", v2.approved === false && v2.code === "artifact-hash-mismatch", JSON.stringify(v2));
});
caseEnd();

caseBegin("regular-session-approval-unchanged", "hooks/workflow-mark/confirm-approval-handler.js");
F.run("regular session regression", () => {
  for (const step of STEPS) {
    const S = F.newSid();
    F.writePlan(S, F.SUFFIX[step]);
    F.writeState(S, null, []);
    const msg = confirm(S, step);
    F.check(`${step}: exact legacy message`, msg === `workflow-mark: ${step} approval recorded (source: confirm-sentinel, hash-status: recorded).`, msg);
    F.check(`${step}: artifact_session_id is S`, (approvalOf(S, step) || {}).artifact_session_id === S, JSON.stringify(approvalOf(S, step)));
    WS().markStep(S, step, "complete");
    F.check(`${step}: completes`, statusOf(S, step) === "complete", statusOf(S, step));
  }
});
caseEnd();

caseBegin("confirm-flag-off-waiver-is-config-file-only", "hooks/workflow-state/completion-approval.js");
F.run("config-dependent branch", () => {
  const S = F.newSid();
  F.writeState(S, null, []);
  const st = WS().readState(S);
  process.env.AGENTS_MAIN_ROOT = OFF_ROOT;
  const off = { outline: CA().evaluateCompletionApproval(S, "outline", st), intent: CA().evaluateCompletionApproval(S, "clarify_intent", st) };
  process.env.AGENTS_MAIN_ROOT = ON_ROOT;
  const on = CA().evaluateCompletionApproval(S, "outline", st);
  F.check("CONFIRM_OUTLINE=off waives outline", off.outline.approved === true && off.outline.source === "confirm-flag-off", JSON.stringify(off.outline));
  F.check("CONFIRM_INTENT=off never waives clarify_intent", off.intent.approved === false, JSON.stringify(off.intent));
  F.check("CONFIRM_OUTLINE=on -> no-approval-record", on.approved === false && on.code === "no-approval-record", JSON.stringify(on));
});
caseEnd();

caseBegin("finish-path-readers-resolve-upstream-artifacts", "hooks/lib/plan-link.js");
F.run("1b readers", () => {
  const { U, D } = downstream(["clarify_intent", "outline", "detail"]);
  const plans = F.plansDir();
  const link = F.load("hooks/lib/plan-link.js").resolvePlanLink(D, "outline", { plansDir: plans });
  F.check("plan-link path is U's outline", F.samePath(link.path, F.planPath(U, "outline")), JSON.stringify(link));
  const issues = F.load("hooks/workflow-state/session-facts.js").getClosesIssues(D, { plansDir: plans });
  F.check("getClosesIssues(D) reads U's intent", JSON.stringify(issues) === JSON.stringify([{ number: 4242 }]), JSON.stringify(issues));
  F.check("hasCompletionEvidence(outline, D) is true",
    F.load("hooks/workflow-state/evidence-resolver.js").hasCompletionEvidence("outline", D) === true, "false");
  const DF = F.load("hooks/lib/diff-fingerprint.js");
  const kd = DF.computeArtifactKey(plans, D, ["outline"]);
  F.check("artifact digest of D equals U's", kd !== null && kd === DF.computeArtifactKey(plans, U, ["outline"]), String(kd));
  const files = F.load("hooks/lib/branch-diff.js").parseDetailFilesToModify(plans, D);
  F.check("declared files come from U's detail", JSON.stringify(files) === JSON.stringify([`hooks/from-${U}.js`]), JSON.stringify(files));
  const gm = F.load("bin/workflow/lib/next-step/gate-mode.js");
  F.check("detectScopeChange is exported", typeof gm.detectScopeChange === "function", Object.keys(gm).join(","));
  const sc = gm.detectScopeChange(D);
  F.check("detectScopeChange(D) reads U's plans (Phase split -> changed, not failed)", sc.failed === false && sc.changed === true, JSON.stringify(sc));
});
caseEnd();

caseBegin("wf-target-repos-downstream-intent-worktrees", "hooks/lib/wf-target-repos.js");
F.run("wf-target-repos", () => {
  const repo = path.join(work, "repo-" + F.newSid());
  fs.mkdirSync(repo);
  gitInit(repo);
  const WT = F.load("hooks/lib/wf-target-repos.js");
  const declared = (r) => (r.members || []).filter((m) => m.origin === "intent-worktrees").map((m) => m.declaredPath);
  const U = F.newSid();
  F.writePlan(U, "intent", F.body("intent", "U", "/nonexistent/wt-up"));
  const r = WT.readWfTargetRepos(F.newSid(), { session_start_context: { cwd: repo }, upstream_session_id: U });
  F.check("upstream intent worktrees are members", JSON.stringify(declared(r)) === JSON.stringify(["/nonexistent/wt-up"]), JSON.stringify(r));
  // Regression: the approval-record route keeps working.
  const X = F.newSid();
  F.writePlan(X, "intent", F.body("intent", "X", "/nonexistent/wt-x"));
  const r2 = WT.readWfTargetRepos(F.newSid(), { session_start_context: { cwd: repo },
    current: { plan_approvals: { outline: { artifact_session_id: X } } }, plan_approvals: { outline: { artifact_session_id: X } } });
  F.check("approval-record route still resolves", JSON.stringify(declared(r2)) === JSON.stringify(["/nonexistent/wt-x"]), JSON.stringify(r2));
});
caseEnd();

caseBegin("finish-path-readers-missing-everywhere-stay-missing", "hooks/lib/plan-link.js");
F.run("missing regression", () => {
  const { D } = downstream([]);
  const plans = F.plansDir();
  const link = F.load("hooks/lib/plan-link.js").resolvePlanLink(D, "outline", { plansDir: plans });
  F.check("plan-link reports no-artifact", link.reason === "no-artifact" && !link.path, JSON.stringify(link));
  F.check("getClosesIssues -> []", F.load("hooks/workflow-state/session-facts.js").getClosesIssues(D, { plansDir: plans }).length === 0, "non-empty");
  F.check("no completion evidence", F.load("hooks/workflow-state/evidence-resolver.js").hasCompletionEvidence("outline", D) === false, "true");
  F.check("artifact key null", F.load("hooks/lib/diff-fingerprint.js").computeArtifactKey(plans, D, ["outline"]) === null, "non-null");
  F.check("declared files null", F.load("hooks/lib/branch-diff.js").parseDetailFilesToModify(plans, D) === null, "non-null");
});
caseEnd();

process.chdir(savedCwd === work ? os.tmpdir() : savedCwd);
if (savedRoot === undefined) delete process.env.AGENTS_MAIN_ROOT;
else process.env.AGENTS_MAIN_ROOT = savedRoot;
restore();
const n = F.failureCount();
console.log(n === 0 ? "ALL PASS" : `${n} FAILED`);
process.exitCode = n === 0 ? 0 : 1;
