"use strict";

// Axis A (#885): build supervisor-emit extras for block self-report.
//   context.cwd:               present when cwd !== undefined
//   context.git_root_resolved: omitted when repoRoot === undefined (inspection
//                              didn't run); false when repoRoot is null or
//                              empty-string (checked, absent); true when truthy.
//   reason: "cwd_no_git_root" when !repoRoot; else
//           "isMainCheckout_unresolved" when mainCheckoutResult === null;
//           else absent.
//   co_blocked_by: NOT populated here — writer back-annotates from sibling search.
function buildExtras(cmd, cwd, repoRoot, mainCheckoutResult) {
  const extras = {};
  if (cwd !== undefined) {
    extras.context = { cwd };
    if (repoRoot !== undefined) {
      extras.context.git_root_resolved = !!repoRoot;
    }
  }
  if (!repoRoot) {
    extras.reason = "cwd_no_git_root";
  } else if (mainCheckoutResult === null) {
    extras.reason = "isMainCheckout_unresolved";
  }
  return extras;
}

module.exports = { buildExtras };
