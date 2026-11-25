// hooks/enforce-worktree/effective-target/decide.js
// #3147: verdicts keyed on the effective target (resolve.js). Each returns a value and
// leaves calling done() to handle-bash-write.js.

"use strict";

const { getProtectedBranches } = require("../config");
const { isAllowedWorktreeCommand } = require("../main-worktree-allows");
const { isAllowedBranchDeleteWhenNotCheckedOut } = require("../branch-delete-guard");
const { naturalBranch } = require("./natural-git");

const EXIT_LINE = "Or set ENFORCE_WORKTREE=off in agents config to allow direct main work.";
const INHERITED_LINE = "GIT_DIR / GIT_WORK_TREE is inherited from the session environment; unset it.";
const OVERRIDE_LINE =
  "The write target is redirected by --git-dir / --work-tree / -C / core.worktree / GIT_DIR / GIT_WORK_TREE and judged where it lands.\n";

const block = (lines, eff) => ({ block: true, reason: [...lines, ...(eff.inherited ? [INHERITED_LINE] : []), EXIT_LINE].join("\n") });

// worktree remove/prune: arm 1 from the main checkout, arm 2 from a linked worktree aimed at
// its own main; a redirect must leave the write on that same main checkout.
function removePruneArmsAllowed(cmd, eff, cwdId, linkedTargetsOwnMain) {
  if (!cwdId) return false;
  const none = eff.kind === "none";
  const main = eff.kind === "main-checkout" && eff.root === eff.mainCheckout;
  if (cwdId.isMain) {
    return (none || (main && eff.gitDir === cwdId.gitDir && eff.root === cwdId.root)) && isAllowedWorktreeCommand(cmd, cwdId.root);
  }
  return (none || (main && eff.commonDir === cwdId.commonDir && eff.gitDir === cwdId.commonDir)) && linkedTargetsOwnMain(cmd, cwdId.root);
}

// → null (no override: keep the cwd-based logic) | "allow" | "block".
function branchDeleteVerdict(eff, cmd) {
  if (eff.kind === "none") return null;
  if (eff.kind !== "linked" && eff.kind !== "outside-session") return "block";
  const root = eff.roots && eff.roots[0];
  return root && isAllowedBranchDeleteWhenNotCheckedOut(cmd, root) ? "allow" : "block";
}

// → null (fall through) | { allow: true } | { block: true, reason }.
function decideEffectiveTarget(eff, markerHit) {
  if (eff.kind === "none") return null;
  if (eff.kind === "unresolvable") {
    return block([
      "ENFORCE_WORKTREE: git write blocked.",
      `Reason: the git write target cannot be resolved (${eff.reason}).`,
      "Pass literal absolute paths for --git-dir / --work-tree / -C / core.worktree.",
    ], eff);
  }
  if (eff.kind === "main-checkout") {
    return block([
      "ENFORCE_WORKTREE: git write blocked.",
      "Reason: --git-dir / --work-tree / -C / core.worktree / GIT_DIR / GIT_WORK_TREE resolve this write to the main checkout of a session repo " +
        `(${eff.mainCheckout}).`,
      "Main worktree is reserved for merge/pull only. Work from a linked worktree.",
    ], eff);
  }
  if (eff.kind === "linked") {
    for (const root of eff.roots || []) {
      const branch = naturalBranch(root);
      if (branch && getProtectedBranches(root).includes(branch)) {
        return block([
          `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${branch}' in linked worktree ${root} (resolved via --git-dir / --work-tree / GIT_DIR).`,
          "Switch to a feature branch before writing.",
          "Run: git switch -c feature/<task-name>",
        ], eff);
      }
    }
    return eff.coversAllWrites && !markerHit ? { allow: true } : null;
  }
  return eff.coversAllWrites && !markerHit ? { allow: true } : null;
}

module.exports = { removePruneArmsAllowed, branchDeleteVerdict, decideEffectiveTarget, OVERRIDE_LINE };
