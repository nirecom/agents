"use strict";
// write_code completion → review_tests reopen (#2327). Shared by record-step-verdict
// (the single writer every write_code completion passes through) and the three
// notice sites (mark-step-handler, next-step advance, next-step --mark).

const { toWindowsPath } = require("../lib/branch-diff");
// Called as reviewTests.recordWriteCodeCompletionScope at call time (never
// destructured) so a wrapper installed on the module is honoured.
const reviewTests = require("./state-io/review-tests");

// The write_code completion entry gates (CPR-E2C): reset and recorded-verdict never complete it.
const REOPEN_GATES = ["sentinel", "advance", "mark"];
const REASON_BY_FRESHNESS = {
  unavailable: "write-code-unavailable",
  missing: "write-code-missing",
  stale: "write-code-stale",
};

// The review target is the session's linked worktree: an absent repoDir, or a main
// worktree while the session records a linked one, resolves from state (never env).
function resolveReopenRepoDir(sessionId, repoDir) {
  const { resolveSessionWorktreePath, isMainWorktree } = require("./resolve-worktree-path");
  const dir = repoDir ? toWindowsPath(repoDir) : null;
  if (dir && !isMainWorktree(dir)) return dir;
  const sessionWt = resolveSessionWorktreePath(sessionId);
  return sessionWt ? toWindowsPath(sessionWt) : dir;
}

function reopenReviewTestsAfterWriteCode(sessionId, repoDir, gate) {
  if (!REOPEN_GATES.includes(gate)) return {};
  try {
    const { computeReviewScopeFingerprint, evaluateReviewScopeFreshness } =
      require("../workflow-gate/review-tests-evidence");
    const dir = resolveReopenRepoDir(sessionId, repoDir);
    // Computed outside the state lock: git I/O never runs under it.
    const current = dir ? computeReviewScopeFingerprint(dir) : { ok: false, error: "worktree unresolvable" };
    const decide = (stepState) => {
      const f = evaluateReviewScopeFreshness(stepState, current);
      return f.fresh ? { reopen: false } : { reopen: true, reason: REASON_BY_FRESHNESS[f.reason] };
    };
    const res = reviewTests.recordWriteCodeCompletionScope(sessionId, current, decide);
    return res && res.reopened ? { kind: "review-tests-reopened", detail: res.reason } : {};
  } catch (e) {
    // write_code is already recorded; the commit gate re-checks freshness.
    return { kind: "review-tests-reopen-failed", detail: (e && e.message) || String(e) };
  }
}

// Notice wording SSOT for every write_code completion entry; null for any other kind.
function formatReviewTestsReopenNotice(res) {
  const kind = res && res.kind;
  if (kind === "review-tests-reopened") {
    return `review_tests reopened to pending (${res.detail}): write_code changed the review scope — ` +
      "run next-step; it routes to /review-tests.";
  }
  if (kind === "review-tests-reopen-failed") {
    return `review_tests reopen failed (${res.detail}); the commit gate re-checks review-scope freshness.`;
  }
  return null;
}

module.exports = { reopenReviewTestsAfterWriteCode, formatReviewTestsReopenNotice };
