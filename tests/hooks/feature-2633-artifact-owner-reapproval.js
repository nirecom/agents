#!/usr/bin/env node
// tests/hooks/feature-2633-artifact-owner-reapproval.js
// Tests: hooks/workflow-state/plan-artifact-owner.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/confirm-approval-handler.js, hooks/workflow-mark.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/evidence-resolver.js, hooks/lib/plan-link.js, hooks/workflow-state/session-facts.js, hooks/lib/wf-target-repos.js, hooks/lib/diff-fingerprint.js, hooks/lib/branch-diff.js, bin/workflow/lib/next-step/gate-mode.js
// Tags: scope:issue-specific, workflow-state, plan-approval, regression-2748
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
const { after, test } = require("node:test");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const savedRoot = process.env.AGENTS_MAIN_ROOT;
const savedCwd = process.cwd();
const F = require("./feature-2633-artifact-owner-reapproval/fixture");
const work = path.dirname(process.env.WORKFLOW_STATE_DIR);
process.chdir(work);
const ON_ROOT = F.configRoot("on", ["CONFIRM_INTENT=on", "CONFIRM_OUTLINE=on", "CONFIRM_DETAIL=on"]);
const OFF_ROOT = F.configRoot("off", ["CONFIRM_INTENT=off", "CONFIRM_OUTLINE=off", "CONFIRM_DETAIL=off"]);
process.env.AGENTS_MAIN_ROOT = ON_ROOT;
after(() => {
  process.chdir(savedCwd === work ? os.tmpdir() : savedCwd);
  if (savedRoot === undefined) delete process.env.AGENTS_MAIN_ROOT;
  else process.env.AGENTS_MAIN_ROOT = savedRoot;
  restore();
});

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
// complete(sid, step) — #2529: a gated completion also needs a current glossary_check record,
// seeded first (bound to a throwaway fixture repo) so each case keeps judging the approval alone.
const { completeWithRecord } = require("../lib/glossary-check-record");
const GLOSSARY_REPO = path.join(work, "glossary-repo");
fs.mkdirSync(GLOSSARY_REPO, { recursive: true });
gitInit(GLOSSARY_REPO);
function complete(sid, step) {
  completeWithRecord(sid, step, GLOSSARY_REPO, (...a) => WS().markStep(...a));
}
const approvalOf = (sid, step) => ((WS().readState(sid) || {}).plan_approvals || {})[step] || null;
const statusOf = (sid, step) => (((WS().readState(sid) || {}).steps || {})[step] || {}).status;

// #2748: every plan is named after the first_session_id; the session-downstream's own sid name is
// never read. downstream() seeds a legacy state (upstream_session_id only), whose first_session_id is U.
caseBegin("owner-resolver-first-session-only-and-missing", "hooks/workflow-state/plan-artifact-owner.js");
test("resolver basic", () => noNewFailures(F.failureCount, () => F.run("resolver basic", () => {
  F.check("resolvePlanArtifactOwner is exported", typeof owner().resolvePlanArtifactOwner === "function", "missing export");
  const { U, D } = downstream(["outline"]);
  let r = owner().resolvePlanArtifactOwner(D, "outline");
  F.check("first_session_id file -> via first-session, owner U", r.via === "first-session" && r.ownerSid === U && r.exists === true &&
    F.samePath(r.path, F.planPath(U, "outline")), JSON.stringify(r));
  F.writePlan(D, "outline", F.body("outline", "own-D"));
  r = owner().resolvePlanArtifactOwner(D, "outline");
  F.check("only the first_session_id name is read (D's own file ignored)", r.via === "first-session" && r.ownerSid === U &&
    F.samePath(r.path, F.planPath(U, "outline")), JSON.stringify(r));
  r = owner().resolvePlanArtifactOwner(D, "detail");
  F.check("nothing anywhere -> missing, the first_session_id path", r.via === "missing" && r.ownerSid === U && r.exists === false &&
    F.samePath(r.path, F.planPath(U, "detail")), JSON.stringify(r));
  const S = F.newSid();
  F.writePlan(S, "outline");
  F.writeState(S, null, []);
  r = owner().resolvePlanArtifactOwner(S, "outline");
  F.check("a first generation reads its own file via own", r.via === "own" && r.ownerSid === S && r.exists === true, JSON.stringify(r));
})));
caseEnd();

caseBegin("owner-resolver-ignores-approval-record-sid", "hooks/workflow-state/plan-artifact-owner.js");
test("resolver ignores approval records", () => noNewFailures(F.failureCount, () => F.run("resolver ignores approval records", () => {
  const X = F.newSid();
  const xBody = F.body("outline", "X");
  F.writePlan(X, "outline", xBody);
  const D1 = F.newSid();
  F.writeState(D1, null, [F.approvalEvent("outline", X, F.sha(xBody))]);
  let r = owner().resolvePlanArtifactOwner(D1, "outline");
  F.check("live approval record names X -> path stays the first_session_id (D1) path", r.ownerSid === D1 && r.via === "missing" &&
    F.samePath(r.path, F.planPath(D1, "outline")), JSON.stringify(r));
  const U = F.newSid();
  const D2 = F.newSid();
  F.writeState(D2, { upstream_session_id: U, upstream_copy_seq: 2 },
    [F.approvalEvent("outline", X, F.sha(xBody)), F.revokeEvent("outline")]);
  r = owner().resolvePlanArtifactOwner(D2, "outline");
  F.check("approval history names X -> path stays the first_session_id (U) path", r.ownerSid === U && r.via === "missing" &&
    F.samePath(r.path, F.planPath(U, "outline")), JSON.stringify(r));
})));
caseEnd();

caseBegin("inheritance-reverts-approval-when-first-session-file-edited", "hooks/workflow-state/completion-approval.js");
test("chained adoption with a first_session_id-owned artifact", () => noNewFailures(F.failureCount, () => F.run("chained adoption with a first_session_id-owned artifact", () => {
  const apply = () => F.load("hooks/workflow-state/inheritance/apply.js");
  const at = new Date().toISOString();
  // X -> U -> D: U carries X's approval (outline complete); D adopts U. X is the first_session_id.
  const chain = (mutate) => {
    const X = F.newSid();
    const xBody = F.body("outline", "X-gen");
    F.writePlan(X, "outline", xBody);
    const U = F.newSid();
    F.writeState(U, { upstream_session_id: X, upstream_copy_seq: 0 },
      [F.approvalEvent("outline", X, F.sha(xBody)), F.statusEvent("outline", "complete")]);
    if (mutate === "upstream-own") F.writePlan(U, "outline", F.body("outline", "U-own"));
    if (mutate === "edit-first") F.writePlan(X, "outline", xBody + "\nedited after approval\n");
    const D = F.newSid();
    F.writeState(D, null, []);
    return { D, res: apply().applyInheritance(D, at, U) };
  };
  const ctl = chain(null);
  F.check("control: unedited first_session_id file -> outline stays complete", statusOf(ctl.D, "outline") === "complete",
    JSON.stringify(ctl.res.reverted_steps));
  const up = chain("upstream-own");
  F.check("a session-upstream-named outline is never read -> outline stays complete", statusOf(up.D, "outline") === "complete",
    JSON.stringify(up.res.reverted_steps));
  const { D, res } = chain("edit-first");
  const rv = (res.reverted_steps || []).find((r) => r.step === "outline");
  F.check("edited first_session_id file -> outline reverted to pending", statusOf(D, "outline") === "pending", statusOf(D, "outline"));
  F.check("revert names the approval mismatch", rv && rv.cause === "approval" && rv.code === "artifact-hash-mismatch",
    JSON.stringify(res.reverted_steps));
})));
caseEnd();

caseBegin("owner-resolver-rejects-traversal-and-honors-plans-dir", "hooks/workflow-state/plan-artifact-owner.js");
test("resolver security", () => noNewFailures(F.failureCount, () => F.run("resolver security", () => {
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
  F.check("opts.plansDir is honored", r2.via === "first-session" && F.samePath(r2.path, F.planPath(U, "intent", alt)), JSON.stringify(r2));
})));
caseEnd();

caseBegin("confirm-outline-in-downstream-hashes-upstream-and-completes", "hooks/workflow-mark/confirm-approval-handler.js");
test("downstream outline re-approval", () => noNewFailures(F.failureCount, () => F.run("downstream outline re-approval", () => {
  const { U, D } = downstream(["outline"]);
  const msg = confirm(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("artifact_session_id is U", rec && rec.artifact_session_id === U && rec.artifact_hash_status === "recorded", msg + " " + JSON.stringify(rec));
  F.check("message names the hashed upstream file", msg.includes(`hashed ${U}-outline.md (owned by session upstream)`), msg);
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("evaluation approved", v.approved === true, JSON.stringify(v));
  complete(D, "outline");
  F.check("markStep(D, outline, complete) persists", statusOf(D, "outline") === "complete", statusOf(D, "outline"));
})));
caseEnd();

caseBegin("confirm-intent-and-detail-in-downstream-complete", "hooks/workflow-mark/confirm-approval-handler.js");
test("downstream intent/detail re-approval", () => noNewFailures(F.failureCount, () => F.run("downstream intent/detail re-approval", () => {
  for (const step of ["clarify_intent", "detail"]) {
    const { U, D } = downstream([step]);
    const msg = confirm(D, step);
    const rec = approvalOf(D, step);
    F.check(`${step}: artifact_session_id is U`, rec && rec.artifact_session_id === U, msg);
    complete(D, step);
    F.check(`${step}: completes in D`, statusOf(D, step) === "complete", statusOf(D, step));
  }
})));
caseEnd();

caseBegin("confirm-outline-in-downstream-through-registered-hook", "hooks/workflow-mark.js");
test("downstream outline re-approval via workflow-mark.js subprocess", () => noNewFailures(F.failureCount, () => F.run("downstream outline re-approval via workflow-mark.js subprocess", () => {
  const { U, D } = downstream(["outline"]);
  const msg = confirmViaHook(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("hook records an approval for D", rec !== null, msg);
  F.check("hook: artifact_session_id (owner) is U", rec && rec.artifact_session_id === U && rec.artifact_hash_status === "recorded", msg + " " + JSON.stringify(rec));
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("hook: evaluation approved", v.approved === true, JSON.stringify(v));
})));
caseEnd();

caseBegin("confirm-binds-to-first-session-artifact", "hooks/workflow-mark/confirm-approval-handler.js");
test("approval bound to the first_session_id file", () => noNewFailures(F.failureCount, () => F.run("approval bound to the first_session_id file", () => {
  const { U, D } = downstream(["outline"]);
  F.writePlan(D, "outline", F.body("outline", "own-D"));
  const msg = confirm(D, "outline");
  const rec = approvalOf(D, "outline");
  F.check("artifact_session_id is the first_session_id (U), not D", rec && rec.artifact_session_id === U, msg + " " + JSON.stringify(rec));
  F.check("recorded hash is the first_session_id file's", rec && rec.artifact_sha256 === CA().computeArtifactSha(U, "outline"), JSON.stringify(rec));
})));
caseEnd();

caseBegin("first-session-file-edited-after-approval-needs-reapproval", "hooks/workflow-state/completion-approval.js");
test("stale first_session_id-bound approval", () => noNewFailures(F.failureCount, () => F.run("stale first_session_id-bound approval", () => {
  const { U, D } = downstream(["outline"]);
  confirm(D, "outline");
  F.check("approval bound to U", (approvalOf(D, "outline") || {}).artifact_session_id === U, JSON.stringify(approvalOf(D, "outline")));
  F.writePlan(D, "outline", F.body("outline", "own-D-later"));
  const own = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("a later D-named file is never read -> approval stands", own.approved === true, JSON.stringify(own));
  F.writePlan(U, "outline", F.body("outline", "U-edited-later"));
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("edited first_session_id file -> artifact-hash-mismatch", v.approved === false && v.code === "artifact-hash-mismatch", JSON.stringify(v));
  let threw = null;
  try { WS().markStep(D, "outline", "complete"); } catch (e) { threw = e; }
  F.check("markStep(complete) refused with the mismatch code", threw !== null && threw.code === "artifact-hash-mismatch",
    threw ? `${threw.code} ${threw.message}` : "no throw");
  F.check("outline stays not complete", statusOf(D, "outline") !== "complete", statusOf(D, "outline"));
  confirm(D, "outline");
  F.check("re-approval binds to the first_session_id (U)", (approvalOf(D, "outline") || {}).artifact_session_id === U, JSON.stringify(approvalOf(D, "outline")));
  complete(D, "outline");
  F.check("completes after re-approval", statusOf(D, "outline") === "complete", statusOf(D, "outline"));
})));
caseEnd();

caseBegin("approval-bound-to-non-first-session-sid-is-mismatch", "hooks/workflow-state/completion-approval.js");
test("record naming a sid that is not read", () => noNewFailures(F.failureCount, () => F.run("record naming a sid that is not read", () => {
  const { U, D } = downstream(["outline"]);
  const text = F.body("outline", "D-named");
  F.writePlan(D, "outline", text);
  F.writeState(D, { upstream_session_id: U, upstream_copy_seq: 0 }, [F.approvalEvent("outline", D, F.sha(text))]);
  const v = CA().evaluateCompletionApproval(D, "outline", WS().readState(D));
  F.check("artifact_session_id != first_session_id -> artifact-hash-mismatch", v.approved === false && v.code === "artifact-hash-mismatch", JSON.stringify(v));
})));
caseEnd();

caseBegin("confirm-without-any-artifact-is-unverifiable", "hooks/workflow-mark/confirm-approval-handler.js");
test("no artifact", () => noNewFailures(F.failureCount, () => F.run("no artifact", () => {
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
})));
caseEnd();

caseBegin("record-plan-approval-artifact-session-id-field", "hooks/workflow-state/completion-approval.js");
test("artifactSessionId field", () => noNewFailures(F.failureCount, () => F.run("artifactSessionId field", () => {
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
})));
caseEnd();

caseBegin("evaluate-backfills-owner-for-record-without-session", "hooks/workflow-state/completion-approval.js");
test("evaluate backfill", () => noNewFailures(F.failureCount, () => F.run("evaluate backfill", () => {
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
})));
caseEnd();

caseBegin("regular-session-approval-unchanged", "hooks/workflow-mark/confirm-approval-handler.js");
test("regular session regression", () => noNewFailures(F.failureCount, () => F.run("regular session regression", () => {
  for (const step of STEPS) {
    const S = F.newSid();
    F.writePlan(S, F.SUFFIX[step]);
    F.writeState(S, null, []);
    const msg = confirm(S, step);
    F.check(`${step}: exact legacy message`, msg === `workflow-mark: ${step} approval recorded (source: confirm-sentinel, hash-status: recorded).`, msg);
    F.check(`${step}: artifact_session_id is S`, (approvalOf(S, step) || {}).artifact_session_id === S, JSON.stringify(approvalOf(S, step)));
    complete(S, step);
    F.check(`${step}: completes`, statusOf(S, step) === "complete", statusOf(S, step));
  }
})));
caseEnd();

caseBegin("confirm-flag-off-waiver-is-config-file-only", "hooks/workflow-state/completion-approval.js");
test("config-dependent branch", () => noNewFailures(F.failureCount, () => F.run("config-dependent branch", () => {
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
})));
caseEnd();

caseBegin("finish-path-readers-resolve-upstream-artifacts", "hooks/lib/plan-link.js");
test("1b readers", () => noNewFailures(F.failureCount, () => F.run("1b readers", () => {
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
})));
caseEnd();

caseBegin("wf-target-repos-downstream-intent-worktrees", "hooks/lib/wf-target-repos.js");
test("wf-target-repos", () => noNewFailures(F.failureCount, () => F.run("wf-target-repos", () => {
  const repo = path.join(work, "repo-" + F.newSid());
  fs.mkdirSync(repo);
  gitInit(repo);
  const WT = F.load("hooks/lib/wf-target-repos.js");
  const declared = (r) => (r.members || []).filter((m) => m.origin === "intent-worktrees").map((m) => m.declaredPath);
  const U = F.newSid();
  F.writePlan(U, "intent", F.body("intent", "U", "/nonexistent/wt-up"));
  const r = WT.readWfTargetRepos(F.newSid(), { session_start_context: { cwd: repo }, upstream_session_id: U });
  F.check("upstream intent worktrees are members", JSON.stringify(declared(r)) === JSON.stringify(["/nonexistent/wt-up"]), JSON.stringify(r));
  // #2748: the approval-record route is gone; the intent is read at the resolver's path only.
  const X = F.newSid();
  F.writePlan(X, "intent", F.body("intent", "X", "/nonexistent/wt-x"));
  const S = F.newSid();
  F.writePlan(S, "intent", F.body("intent", "S", "/nonexistent/wt-s"));
  const r2 = WT.readWfTargetRepos(S, { session_start_context: { cwd: repo },
    current: { plan_approvals: { outline: { artifact_session_id: X } } }, plan_approvals: { outline: { artifact_session_id: X } } });
  F.check("the resolver path is read, not the approval record's sid", JSON.stringify(declared(r2)) === JSON.stringify(["/nonexistent/wt-s"]), JSON.stringify(r2));
})));
caseEnd();

caseBegin("finish-path-readers-missing-everywhere-stay-missing", "hooks/lib/plan-link.js");
test("missing regression", () => noNewFailures(F.failureCount, () => F.run("missing regression", () => {
  const { D } = downstream([]);
  const plans = F.plansDir();
  const link = F.load("hooks/lib/plan-link.js").resolvePlanLink(D, "outline", { plansDir: plans });
  F.check("plan-link reports no-artifact", link.reason === "no-artifact" && !link.path, JSON.stringify(link));
  F.check("getClosesIssues -> []", F.load("hooks/workflow-state/session-facts.js").getClosesIssues(D, { plansDir: plans }).length === 0, "non-empty");
  F.check("no completion evidence", F.load("hooks/workflow-state/evidence-resolver.js").hasCompletionEvidence("outline", D) === false, "true");
  F.check("artifact key null", F.load("hooks/lib/diff-fingerprint.js").computeArtifactKey(plans, D, ["outline"]) === null, "non-null");
  F.check("declared files null", F.load("hooks/lib/branch-diff.js").parseDetailFilesToModify(plans, D) === null, "non-null");
})));
caseEnd();

// #2748 R2-R5: a wsid that fails SESSION_ID_VALID_RE never reaches a path, so the catch fallback
// of the owner resolution can no longer join "<dir>/../x-detail.md" and read outside the plans dir.
caseBegin("branch-diff-rejects-invalid-wsid", "hooks/lib/branch-diff.js");
test("parseDetailFilesToModify sid validation", () => noNewFailures(F.failureCount, () => F.run("parseDetailFilesToModify sid validation", () => {
  const BD = F.load("hooks/lib/branch-diff.js");
  const tmp = path.join(work, "r2-plans");
  fs.mkdirSync(tmp, { recursive: true });
  const escape = "f2748-r2-" + F.newSid();
  fs.writeFileSync(path.join(work, `${escape}-detail.md`), F.body("detail", "escaped"));
  const r2 = BD.parseDetailFilesToModify(tmp, `../${escape}`);
  F.check("R2: a traversal wsid returns null even when <dir>/../<x>-detail.md exists", r2 === null, JSON.stringify(r2));
  const bad = "f2748.r3";
  const badFile = path.join(tmp, `${bad}-detail.md`);
  fs.writeFileSync(badFile, F.body("detail", "dotted"));
  const reads = [];
  const orig = fs.readFileSync;
  fs.readFileSync = function (p, ...rest) {
    if (F.samePath(p, badFile)) reads.push(String(p));
    return orig.call(fs, p, ...rest);
  };
  let r3;
  try { r3 = BD.parseDetailFilesToModify(tmp, bad); } finally { fs.readFileSync = orig; }
  F.check("R3: an invalid wsid with no state returns null instead of the catch fallback's files", r3 === null, JSON.stringify(r3));
  F.check("R3: the fallback path <dir>/<invalid>-detail.md is never read", reads.length === 0, JSON.stringify(reads));
  const S = F.newSid();
  F.writePlan(S, "detail", null, tmp);
  const r4 = BD.parseDetailFilesToModify(tmp, S);
  F.check("R4: a valid wsid still returns its Files to modify", JSON.stringify(r4) === JSON.stringify([`hooks/from-${S}.js`]), JSON.stringify(r4));
})));
caseEnd();

caseBegin("artifact-key-rejects-invalid-session-id", "hooks/lib/diff-fingerprint.js");
test("computeArtifactKey sid validation", () => noNewFailures(F.failureCount, () => F.run("computeArtifactKey sid validation", () => {
  const DF = F.load("hooks/lib/diff-fingerprint.js");
  const tmp = path.join(work, "r5-plans");
  fs.mkdirSync(tmp, { recursive: true });
  const escape = "f2748-r5-" + F.newSid();
  fs.writeFileSync(path.join(work, `${escape}-intent.md`), F.body("intent", "escaped"));
  const k = DF.computeArtifactKey(tmp, `../${escape}`, ["intent"]);
  F.check("R5: a traversal sessionId returns null even when <dir>/../<x>-intent.md exists", k === null, String(k));
  const S = F.newSid();
  F.writePlan(S, "intent", null, tmp);
  const ok = DF.computeArtifactKey(tmp, S, ["intent"]);
  F.check("R5: a valid sessionId still yields a key", typeof ok === "string" && ok.length > 0, String(ok));
})));
caseEnd();

// #2748 O1-O4: the owner is the first_session_id, so a third generation reaches the first
// generation's plan even when the middle one wrote none, and no other generation's name is read.
// adopt(down, up) — a real applyInheritance hop, so previous_session_ids is the production value.
function adopt(down, up) {
  F.writeState(down, null, []);
  const created = JSON.parse(fs.readFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${down}.json`), "utf8")).created_at;
  F.load("hooks/workflow-state/inheritance/apply.js").applyInheritance(down, created, up);
}
// sessionChain(n) — a session chain of n generations G0 -> ... -> G(n-1), each adopting the previous one.
function sessionChain(n) {
  const g = [F.newSid()];
  F.writeState(g[0], null, []);
  for (let i = 1; i < n; i++) { g.push(F.newSid()); adopt(g[i], g[i - 1]); }
  return g;
}

caseBegin("owner-resolver-reads-first-session-only", "hooks/workflow-state/plan-artifact-owner.js");
test("first_session_id candidates", () => noNewFailures(F.failureCount, () => F.run("first_session_id candidates", () => {
  const [A, , C] = sessionChain(3);
  for (const k of ["intent", "outline", "detail"]) F.writePlan(A, k);
  const r1 = owner().resolvePlanArtifactOwner(C, "detail");
  F.check("O1: A -> B (no plan) -> C resolves C's detail to A's file via first-session", r1.ownerSid === A && r1.exists === true &&
    r1.via === "first-session" && F.samePath(r1.path, F.planPath(A, "detail")), JSON.stringify(r1));
  const [A2, B2, C2, D2] = sessionChain(4);
  F.writePlan(B2, "detail");
  F.writePlan(C2, "detail");
  F.writePlan(D2, "detail");
  const r2 = owner().resolvePlanArtifactOwner(D2, "detail");
  F.check("O2: plans not named after the first_session_id are never read", r2.ownerSid === A2 && r2.via === "missing" &&
    r2.exists === false && F.samePath(r2.path, F.planPath(A2, "detail")), JSON.stringify(r2));
})));
caseEnd();

caseBegin("owner-resolver-skips-invalid-ancestors", "hooks/workflow-state/plan-artifact-owner.js");
test("invalid ancestors", () => noNewFailures(F.failureCount, () => F.run("invalid ancestors", () => {
  const A = F.newSid();
  const U = F.newSid();
  const D = F.newSid();
  F.writePlan(A, "detail");
  const evil = "evil-" + F.newSid();
  fs.writeFileSync(path.join(work, `${evil}-detail.md`), F.body("detail", "evil"));
  F.writeState(U, null, []);
  F.writeState(D, { upstream_session_id: U, previous_session_ids: [A, U, "a.b", `../${evil}`, 7] }, []);
  const r = owner().resolvePlanArtifactOwner(D, "detail");
  F.check("O3: invalid elements of previous_session_ids are skipped and A is reached", r.ownerSid === A && r.via === "first-session" &&
    !String(r.path).includes(evil), JSON.stringify(r));
  const [A4, , C] = sessionChain(3);
  const r4 = owner().resolvePlanArtifactOwner(C, "outline");
  F.check("O4: nothing written -> the first_session_id path, missing", r4.via === "missing" && r4.ownerSid === A4 &&
    r4.exists === false && F.samePath(r4.path, F.planPath(A4, "outline")), JSON.stringify(r4));
})));
caseEnd();
