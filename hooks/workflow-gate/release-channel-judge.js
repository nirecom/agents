"use strict";
// AUTO_MERGE_PR=off release refusal (#2527 4-3, judgments I-1 / J-1): under off with a
// pull_request delivery the human merges on the web, so Claude's own merge to a protected
// branch is refused. Deliberately blind to session markers, the TR5 backstop and the
// recorded user_verification — none of them may lift the refusal — and it has no
// bootstrap exception. workflow-gate.js calls it before the WORKFLOW_OFF approve.
//
// refuse = first merge-to-protected hit AND AUTO_MERGE_PR off (pinned state value first,
// a fallback pin is "on"; no pin -> live read; unreadable -> "on" + notice) AND delivery
// path pull_request (recorded value first; no record -> config, markers never read).

function defaultDeps() {
  return {
    isMergeToProtectedCommand: require("../lib/merge-detect").isMergeToProtectedCommand,
    readAutoMergePr: require("../lib/auto-merge-config").readAutoMergePr,
    resolveDeliveryPath: require("../lib/delivery-path").resolveMarkerFreeDeliveryPath,
  };
}

function autoMergePrOf(state, repoDir, deps) {
  const pinned = state.auto_merge_pr;
  if (pinned === "on" || pinned === "off") return { value: pinned, notice: null };
  const live = deps.readAutoMergePr({ repoDir });
  if (!live || live.readable === false) {
    return { value: "on", notice: "AUTO_MERGE_PR could not be read; treated as on (no release refusal)." };
  }
  return { value: live.value === "off" ? "off" : "on", notice: null };
}

// judgeRelease({ commands, state, repoDir }, deps?) -> { refuse, kind, notice }.
function judgeRelease(input, deps) {
  const d = Object.assign(defaultDeps(), deps || {});
  const commands = (input && Array.isArray(input.commands)) ? input.commands : [];
  const state = input && input.state && typeof input.state === "object" ? input.state : {};
  const repoDir = input ? input.repoDir : undefined;

  const hit = commands.map((c) => d.isMergeToProtectedCommand(c)).find((h) => h && h.hit);
  if (!hit) return { refuse: false, kind: null, notice: null };

  const amp = autoMergePrOf(state, repoDir, d);
  if (amp.value !== "off") return { refuse: false, kind: hit.kind, notice: amp.notice };

  const deliveryPath = d.resolveDeliveryPath(state, repoDir);
  return { refuse: deliveryPath === "pull_request", kind: hit.kind, notice: null };
}

// refusesUserVerified(state, repoDir, deps?) -> boolean. On the web-merge channel (off +
// pull_request, no bootstrap push) the human's merge is the only approval, so the
// USER_VERIFIED sentinel is refused too. Same value resolution as judgeRelease.
function refusesUserVerified(state, repoDir, deps) {
  const d = Object.assign(defaultDeps(), deps || {});
  const s = state && typeof state === "object" ? state : {};
  const push = s.steps && s.steps.push_branch;
  if (push && push.decision === "bootstrap") return false;
  if (autoMergePrOf(s, repoDir, d).value !== "off") return false;
  return d.resolveDeliveryPath(s, repoDir) === "pull_request";
}

module.exports = { judgeRelease, refusesUserVerified };
