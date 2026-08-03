// hooks/enforce-worktree/handle-edit-write.js
// Extracted (mechanical move, file-split rules/coding/file-split.md) from the
// Edit/Write/MultiEdit branch of hooks/enforce-worktree.js.
//
// Returns repoRoot on natural fall-through (single Edit/Write whose target is
// a non-excluded, in-session-scope git path) so the entrypoint can continue
// its post-dispatch main-checkout / protected-branch checks. Calls `done()`
// (via ctx) for every allow/block exit — it exits the process, so control
// never returns past those points.

"use strict";

const { getSessionRepoRoots } = require("./session-scope");
const { getExcludePatterns, isExcluded } = require("./shared-cmd-utils");
const { isMainCheckout, findRepoRoot } = require("./git-repo-detection");
const { isInSessionScope } = require("./bash-write-scope");
const { getProtectedBranches, getCurrentBranch } = require("./config");
const { buildWorktreeRemedy } = require("./worktree-remedy");
const { buildExtras } = require("./report-extras");
const { collectEditWritePaths } = require("../lib/write-tools");

function handleEditWrite(ctx) {
  const { input, toolName, toolInput, _toolCwd, done, reportContext, resolveSessionId } = ctx;

  const sessionRoots = getSessionRepoRoots();
  const excludePatterns = getExcludePatterns();

  // The batch shape belongs to the CLASS, not to MultiEdit specifically —
  // NotebookEdit sends `edits[]` too, under `notebook_path`. Gating on tool
  // NAME let a batched call fall through to the single-path branch below,
  // which reads only the top-level key and sees no target at all → allow.
  // MultiEdit also names its target ONLY at the top level (`file_path`); its
  // `edits[]` entries never carry a path, so a per-edit lookup alone always
  // fails. collectEditWritePaths (hooks/lib/write-tools.js SSOT) is additive
  // across top level + `edits[]` — the only correct source for a batch call.
  if (Array.isArray(toolInput.edits) && toolInput.edits.length > 0) {
    // Check every named target — a mixed-repo batch must not slip through.
    for (const fp of collectEditWritePaths(toolInput)) {
      // Bug 1: EXCLUDE match → skip this edit (allow).
      if (isExcluded(fp, excludePatterns)) continue;

      const root = findRepoRoot(fp);
      // Bug 2: non-git path or outside session scope → skip (allow).
      if (!root || !isInSessionScope(root, sessionRoots)) continue;

      const isMC = isMainCheckout(root);
      const branch = getCurrentBranch(root);
      const protected_ = getProtectedBranches(root);
      // null (unresolved) routes to the block side, not allow.
      if (isMC !== false) {
        const branchDesc = branch ? `branch '${branch}'` : "detached HEAD";
        reportContext.extras = buildExtras(undefined, _toolCwd, root, isMC);
        const _remedy = buildWorktreeRemedy((input && input.session_id) || resolveSessionId());
        done({
          block: true,
          reason:
            `ENFORCE_WORKTREE: write blocked. Reason: main worktree (${branchDesc}).\n` +
            "Work from a linked worktree.\n" +
            _remedy +
            "Or set ENFORCE_WORKTREE=off.",
        });
      }
      if (branch && protected_.includes(branch)) {
        reportContext.extras = buildExtras(undefined, _toolCwd, root, isMC);
        done({
          block: true,
          reason: `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${branch}' in linked worktree.\nSwitch to a feature branch or set ENFORCE_WORKTREE=off.`,
        });
      }
    }
    done(); // all edits passed
  }
  // NotebookEdit names its target `notebook_path` — same key set
  // hooks/lib/write-tools.js collects for the rest of the class.
  const filePath = toolInput.file_path || toolInput.path || toolInput.notebook_path;
  if (!filePath || typeof filePath !== "string") done();

  // Bug 1: EXCLUDE match → allow.
  if (isExcluded(filePath, excludePatterns)) done();

  const repoRoot = findRepoRoot(filePath);

  // Bug 2: non-git path or outside session scope → allow.
  if (!repoRoot || !isInSessionScope(repoRoot, sessionRoots)) done();

  return repoRoot;
}

module.exports = { handleEditWrite };
