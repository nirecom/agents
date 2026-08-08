"use strict";
// Evidence-based completion resolver (SSOT for step → evidence predicate).
//
// Read-only module: never mutates workflow state. Callers (workflow-gate,
// the next-step script, reconcile-state CLI, and the WORKFLOW_ON handler)
// consult hasCompletionEvidence() to decide whether a step that is still
// `pending` in state JSON can be treated as complete based on on-disk
// artifacts. fail-open contract: any error or missing file yields false
// (pending treatment preserved) — this never throws.
//
// NON-AUTHORITATIVE for the approval-gated steps: this predicate is a heuristic,
// not completion authority. For `outline` and `detail` it cannot distinguish
// "review has not started" from "review finished but the user has not approved
// yet" — both leave the same on-disk shape. Authority for those two steps is the
// approval record owned by completion-approval.js, enforced at the writeState
// boundary. A true result here is a necessary, never a sufficient, condition.

const path = require("path");
const { execSync, execFileSync } = require("child_process");
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
const { SESSION_ID_VALID_RE } = require("./state-io");
const { hasStagedDocChanges, hasStagedTestChanges } = require("../workflow-gate/staged-evidence");
const { hasWorktreeNotesDocEvidence } = require("../workflow-gate/worktree-context");

// Post-merge fallback: checks whether any committed file under tests/ or test/
// differs from the default branch (origin/HEAD). Returns false on any failure
// (fail-open: pending treatment preserved).
function hasCommittedTestChanges(repoDir) {
  try {
    const baseRef = execFileSync(
      "git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      { cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] }
    ).trim();
    if (!baseRef) return false;
    const diffOut = execFileSync(
      "git", ["diff", "--name-only", baseRef + "...HEAD"],
      { cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] }
    );
    return diffOut.split("\n").some(
      (line) => line.startsWith("tests/") || line.startsWith("test/")
    );
  } catch (e) {
    return false;
  }
}

// An in-flight codex review cycle leaves its round-number and/or concern-ledger
// file on disk (skills/_shared/codex-review-loop.md: both are deleted only on
// a terminal verdict — APPROVED or ESCALATE — and persist across CONTINUE /
// AUTO_EXTEND). Used to distinguish "planner wrote a draft this round" from
// "the loop reached a terminal verdict" — draft existence alone is not proof
// of approval, since outline.md/detail.md is the same file the planner
// overwrites on every revision round.
function hasUnresolvedReviewCycle(plansDir, sessionId, format) {
  const fs = require("fs");
  const roundFile = path.join(plansDir, sessionId + "-" + format + "-round-number.txt");
  const ledgerFile = path.join(plansDir, sessionId + "-" + format + "-concern-ledger.txt");
  return fs.existsSync(roundFile) || fs.existsSync(ledgerFile);
}

// Plan-artifact existence check (SSOT for the step → artifact-suffix mapping).
//
// Returns true only if the plan artifact file for this step exists on disk.
// Used by evaluateInheritance (S3) to distinguish a genuine recorded-complete
// from a synthesized-complete: readState() synthesizes clarify_intent as
// complete even without the artifact, which would otherwise cause false
// inheritance. hasCompletionEvidence is deliberately NOT used there because it
// also checks for an unresolved review cycle, which would block legitimate
// in-progress-review inheritance.
const PLAN_ARTIFACT_SUFFIX = Object.freeze({
  clarify_intent: "intent",
  outline: "outline",
  detail: "detail",
});

function hasPlanArtifact(step, sessionId) {
  const suffix = PLAN_ARTIFACT_SUFFIX[step];
  if (!suffix) return false;
  if (!sessionId || !SESSION_ID_VALID_RE.test(sessionId)) return false;
  try {
    const fs = require("fs");
    return fs.existsSync(path.join(getWorkflowPlansDir(), sessionId + "-" + suffix + ".md"));
  } catch (e) {
    return false;
  }
}

// Resolve the git repository root used by docs evidence checks.
// Precedence: opts.repoDir → CLAUDE_PROJECT_DIR → git rev-parse. Returns null
// on failure (caller treats as no-evidence).
function resolveRepoDir(opts) {
  if (opts && typeof opts.repoDir === "string" && opts.repoDir.length) {
    return opts.repoDir;
  }
  if (process.env.CLAUDE_PROJECT_DIR) {
    return process.env.CLAUDE_PROJECT_DIR;
  }
  try {
    return execSync("git rev-parse --show-toplevel", {
      encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return null;
  }
}

// step がエビデンスベースで完了とみなせるかを確認する。
// 失敗（例外・ファイル不在）は fail-open で false を返す（throw しない）。
//
// @param {string} step       - ワークフローステップ名 (VALID_STEPS と同じ)
// @param {string} sessionId  - 現在のセッション ID
// @param {object} [opts]     - オプション
// @param {string} [opts.repoDir] - git リポジトリのルートパス（docs チェックに使用）
// @returns {boolean}         - true = エビデンス確認済み（complete 扱い可）
function hasCompletionEvidence(step, sessionId, opts = {}) {
  try {
    if (step === "clarify_intent") {
      // hasPlanArtifact rejects a malformed sessionId before building any path
      // (defense-in-depth against path traversal; no live unvalidated path today).
      return hasPlanArtifact("clarify_intent", sessionId);
    }
    if (step === "docs") {
      const repoDir = resolveRepoDir(opts);
      if (!repoDir) return false;
      return hasStagedDocChanges(repoDir) || hasWorktreeNotesDocEvidence(repoDir);
    }
    if (step === "outline") {
      if (!hasPlanArtifact("outline", sessionId)) return false;
      return !hasUnresolvedReviewCycle(getWorkflowPlansDir(), sessionId, "outline-plan");
    }
    if (step === "detail") {
      if (!hasPlanArtifact("detail", sessionId)) return false;
      return !hasUnresolvedReviewCycle(getWorkflowPlansDir(), sessionId, "detail-plan");
    }
    if (step === "write_tests") {
      const repoDir = resolveRepoDir(opts);
      if (!repoDir) return false;
      if (hasStagedTestChanges(repoDir)) return true;
      return hasCommittedTestChanges(repoDir);
    }
    // run_tests: sentinel-only — no evidence-based predicate here.
    // Completion is owned by workflow-run-tests.js (run-all.sh contract-trust)
    // or the run_tests sentinel — never by staged-test evidence.
    return false;
  } catch (e) {
    return false;
  }
}

// step に対応するエビデンス述語が true を返すための必要条件を
// 人間可読な形で返す（チェック内容の説明文字列配列）。
//
// @param {string} step
// @returns {string[]}
function describeEvidence(step) {
  if (step === "clarify_intent") {
    return ["<PLANS_DIR>/<sessionId>-intent.md exists"];
  }
  if (step === "docs") {
    return [
      "a staged file is under docs/ or matches *.md (any name/location, case-insensitive)",
      "in a linked worktree: WORKTREE_NOTES.md ## History Notes / ## Changelog Notes has a non-'(none)' bullet",
    ];
  }
  if (step === "outline") {
    return [
      "<PLANS_DIR>/<sessionId>-outline.md exists",
      "no in-flight review cycle: <sessionId>-outline-plan-round-number.txt and "
        + "<sessionId>-outline-plan-concern-ledger.txt are both absent",
      "NOT sufficient: completion additionally requires a recorded user approval "
        + "(plan_approvals.outline via WORKFLOW_CONFIRM_OUTLINE, or CONFIRM_OUTLINE=off)",
    ];
  }
  if (step === "detail") {
    return [
      "<PLANS_DIR>/<sessionId>-detail.md exists",
      "no in-flight review cycle: <sessionId>-detail-plan-round-number.txt and "
        + "<sessionId>-detail-plan-concern-ledger.txt are both absent",
      "NOT sufficient: completion additionally requires a recorded user approval "
        + "(plan_approvals.detail via WORKFLOW_CONFIRM_DETAIL, or CONFIRM_DETAIL=off)",
    ];
  }
  if (step === "write_tests") {
    return [
      "a staged file is under tests/ or test/ (per hasStagedTestChanges)",
      "a committed file under tests/ or test/ differs from the default branch (post-merge fallback)",
    ];
  }
  if (step === "run_tests") {
    return [
      "NO completion evidence exists: hasCompletionEvidence(\"run_tests\") is always false — "
        + "completion is owned by workflow-run-tests.js (tests/run-all.sh RUN_CONTRACT) "
        + "or the MARK_STEP sentinel",
      "SKIP only: when every staged file is human-facing docs (isDocsOnlyStaged), "
        + "echo \"<<WORKFLOW_RUN_TESTS_NOT_NEEDED: {reason}>>\" records it as skipped; "
        + "docs-only grants explicability, never completion authority",
    ];
  }
  return [];
}

module.exports = { hasCompletionEvidence, describeEvidence, hasPlanArtifact };
