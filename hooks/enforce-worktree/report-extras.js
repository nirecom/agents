// hooks/enforce-worktree/report-extras.js
// Extracted verbatim from hooks/enforce-worktree.js (file-split, rules/coding/file-split.md).
// buildExtras() is shared by the entrypoint's own block-path reporting and by the
// handle-bash-write / handle-edit-write sub-modules, which each populate
// _reportContext.extras before calling done({ block: true, ... }).

"use strict";

function buildExtras(cmd, cwd, repoRoot, mainCheckoutResult) {
  const extras = {};
  if (cwd !== undefined) {
    extras.context = { cwd };
    if (repoRoot !== undefined) extras.context.git_root_resolved = !!repoRoot;
  }
  if (!repoRoot) extras.reason = "cwd_no_git_root";
  else if (mainCheckoutResult === null) extras.reason = "isMainCheckout_unresolved";
  return extras;
}

module.exports = { buildExtras };
