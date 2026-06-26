"use strict";
// Evidence-based completion resolver (SSOT for step → evidence predicate).
//
// Read-only module: never mutates workflow state. Callers (workflow-gate,
// the next-step oracle, reconcile-state CLI, and the WORKFLOW_ON handler)
// consult hasCompletionEvidence() to decide whether a step that is still
// `pending` in state JSON can be treated as complete based on on-disk
// artifacts. fail-open contract: any error or missing file yields false
// (pending treatment preserved) — this never throws.

const path = require("path");
const { execSync } = require("child_process");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { SESSION_ID_VALID_RE } = require("./state-io");
const { hasStagedDocChanges } = require("../../workflow-gate/staged-evidence");
const { hasWorktreeNotesDocEvidence } = require("../../workflow-gate/worktree-context");

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
      // fail-open: reject malformed sessionId before building any path
      // (defense-in-depth against path traversal; no live unvalidated path today).
      if (!sessionId || !SESSION_ID_VALID_RE.test(sessionId)) return false;
      const fs = require("fs");
      const plansDir = getWorkflowPlansDir();
      const intentPath = path.join(plansDir, sessionId + "-intent.md");
      return fs.existsSync(intentPath);
    }
    if (step === "docs") {
      const repoDir = resolveRepoDir(opts);
      if (!repoDir) return false;
      return hasStagedDocChanges(repoDir) || hasWorktreeNotesDocEvidence(repoDir);
    }
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
  return [];
}

module.exports = { hasCompletionEvidence, describeEvidence };
