"use strict";
// Declared completion of the release steps push_branch / merge_to_main (#2527 3-2b, 3-3).
// A declaration (MARK_STEP, --advance, --mark) completes them only on the same
// evidence navigation reads, so a freely emittable sentinel cannot claim a push
// or a delivery that did not happen. A forge or git failure is no evidence.
// checkReleaseCompletion → null (not a release completion) | { ok:false, ... }
//   | { ok:true, settleKind, extraFields } — settleKind set only for merge_to_main.

const RELEASE_STEPS = ["push_branch", "merge_to_main"];
const RELEASE_GATES = ["sentinel", "advance", "mark"];

function refuse(step, why) {
  return {
    ok: false, code: 2, kind: "no-release-evidence", detail: why,
    message: `record-step-verdict: ${step} NOT recorded — ${why}. Run the step's skill ` +
      `(${step === "push_branch" ? "/commit-push" : "/merge-to-main"}) instead of declaring it complete.`,
  };
}

function readRecorded(sessionId) {
  try { return require("../state-io").readState(sessionId); } catch (_) { return null; }
}

// Bootstrap delivery (an empty remote, pushed by bootstrap-complete.sh): the
// default branch now exists on origin and HEAD is exactly its tip. Declared
// gate only — navigation evidence keeps no bootstrap branch (detail 3-3).
function isBootstrapDelivered(repoDir) {
  const { spawnSync } = require("child_process");
  const { getProtectedBranches } = require("../../lib/merge-detect");
  const rev = (ref) => {
    const r = spawnSync("git", ["-C", repoDir, "rev-parse", "--verify", "-q", ref], { encoding: "utf8", timeout: 5000 });
    return r && !r.error && r.status === 0 ? (r.stdout || "").trim() : null;
  };
  const head = rev("HEAD");
  if (!head) return false;
  return getProtectedBranches().some((b) => rev("refs/remotes/origin/" + b) === head);
}

// resolveTrusted: the advance gate's H2 repo resolver (never opts.repoDir there).
function checkReleaseCompletion(sessionId, step, status, gate, opts, resolveTrusted) {
  if (status !== "complete" || RELEASE_STEPS.indexOf(step) === -1 || RELEASE_GATES.indexOf(gate) === -1) {
    return null;
  }
  const repoDir = gate === "advance" ? resolveTrusted() : (opts && opts.repoDir) || null;
  if (!repoDir) return refuse(step, "no repository to read the evidence from");
  const state = readRecorded(sessionId);
  const { hasCompletionEvidence } = require("../evidence-resolver");
  let evidence = false;
  try { evidence = hasCompletionEvidence(step, sessionId, { repoDir, state }) === true; } catch (_) { evidence = false; }
  const steps = (state && state.steps) || {};
  if (step === "push_branch") {
    if (evidence) return { ok: true, extraFields: {} };
    const { isRemoteDefaultBranchAbsent } = require("../../workflow-gate/gh-detect");
    if (isRemoteDefaultBranchAbsent(repoDir)) return { ok: true, extraFields: { decision: "bootstrap" } };
    return refuse(step, "no pull request (OPEN or MERGED) exists for the current branch");
  }
  const bootstrap = steps.push_branch && steps.push_branch.decision === "bootstrap";
  if (!evidence && !(bootstrap && isBootstrapDelivered(repoDir))) {
    return refuse(step, "the delivery is not observable (PR not MERGED, or the default branch is not pushed clean)");
  }
  const { resolveSessionProfile } = require("../session-profile");
  const profile = resolveSessionProfile(state, sessionId, { repoDir });
  const { isReleaseApprovalSatisfied } = require("../release-approval");
  if (!isReleaseApprovalSatisfied(state, sessionId, { repoDir, profile })) {
    return refuse(step, "user_verification (release approval) is not recorded for this session");
  }
  const { deliveryKindFor } = require("../delivery-settle");
  const path = profile.deliveryPath;
  return { ok: true, extraFields: {}, settleKind: bootstrap ? "post-push" : deliveryKindFor(path) };
}

module.exports = { checkReleaseCompletion, RELEASE_STEPS };
