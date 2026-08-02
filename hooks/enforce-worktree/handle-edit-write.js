// hooks/enforce-worktree/handle-edit-write.js
// Extracted verbatim (mechanical move only — no logic/behavior change) from the
// `else if (["Edit", "Write", "MultiEdit"].includes(toolName)) { ... }` branch of
// hooks/enforce-worktree.js (file-split, rules/coding/file-split.md — entrypoint
// exceeded the 500-line HARD limit).
//
// Returns repoRoot on natural fall-through (single Edit/Write whose target is a
// non-excluded, in-session-scope git path — no allow/block decision reached
// inside this branch) so the entrypoint can continue with its post-dispatch
// main-checkout / protected-branch checks. Calls `done()` (passed in via ctx)
// for every allow/block exit, exactly as the original inline code did —
// `done()` calls process.exit(0), so control never returns past those points.

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

  // H-2 (#1780 round-4): the batch shape belongs to the CLASS, not to MultiEdit
  // (NotebookEdit sends `edits[]` too, with the target under `notebook_path`).
  // Gating on the tool NAME let a batched editFiles/NotebookEdit call fall
  // through to the single-path branch, which reads only the top-level key and
  // therefore saw no target at all → `done()` → allow.
  //
  // H-4 (#1780 round-13): a per-edit `fp` lookup alone is not enough — MultiEdit
  // names its target ONLY at the top level (`file_path`); its `edits[]` entries
  // (`old_string`/`new_string`/`replace_all`) never carry a path at all, so every
  // per-entry lookup failed and the loop fell through to an unconditional allow
  // without ever consulting the top-level path. collectEditWritePaths (the
  // hooks/lib/write-tools.js SSOT) is additive across top level + `edits[]`, so
  // it is the only correct source of "what did this call name" for a batch call.
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
      // Axis A (#885): null (unresolved) routes to the block side, not allow.
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
  // NotebookEdit names its target `notebook_path` (H-2, #1780 round-4) — same
  // key set hooks/lib/write-tools.js collects for the rest of the class.
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
