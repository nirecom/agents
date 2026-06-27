"use strict";
// hooks/enforce-worktree/universal-target-allow.js
// Universal target-aware allow rule (issue #1045).
// For Bash commands from main worktree under ENFORCE_WORKTREE=on:
// allow when every parseable write target resolves outside the session scope.
// Sequenced commands and parse failures → abstain (fail-closed, C1).

const { collectBashWriteTargets, areAllBashTargetsOutsideSessionScope, areAllBashTargetsUnderPlansDir } = require("./bash-write-scope");
const { hasCommandSequencing, hasCommandSequencingOutsideHeredoc } = require("./shared-cmd-utils");

/**
 * Check whether a Bash command's write targets are all outside the session scope.
 * Returns { verdict: 'allow' } when all extracted targets are outside every repo in sessionRoots.
 * Returns { verdict: 'abstain' } in all other cases (fail-closed):
 *   - non-Bash tool
 *   - sessionRoots is empty (non-git CWD with no extra repos configured)
 *   - repoRoot is null (non-git CWD — even when EXTRA_REPOS is configured,
 *     a non-git CWD cannot be evaluated)
 *   - command contains sequencing operators (C1)
 *   - no write targets extracted (unknown write destination)
 *   - parse failure from any extractor
 *   - any target resolves inside any session-scope repo
 *   - unexpected exception
 *
 * Note: when repoRoot resolves to a git repo outside sessionRoots (e.g. the
 * model uses `git -C /otherRepo` or `cd /otherRepo`), the universal rule still
 * applies — writes to a different project entirely are outside this hook's
 * protection scope by design. The session-scope check evaluates write targets,
 * not the CWD repo.
 *
 * @param {string} toolName  Claude Code tool name (e.g. 'Bash', 'Edit').
 * @param {object} toolInput  The tool_input object from the hook payload.
 * @param {Set<string>} sessionRoots  Set of repo roots considered in-session (from getSessionRepoRoots()).
 * @param {string|null|undefined} repoRoot  Resolved repo root for the Bash command's CWD, or null/undefined.
 * @returns {{ verdict: 'allow' | 'abstain', reason?: string }}
 */
function checkUniversalTargetAllow(toolName, toolInput, sessionRoots, repoRoot) {
  try {
    // Only applies to Bash commands; Edit/Write/MultiEdit are handled by
    // isInSessionScope in the caller (line ~387 of enforce-worktree.js).
    if (toolName !== "Bash") return { verdict: "abstain" };

    // Guard 1: no session scope to compare against, or non-git/out-of-session CWD — abstain.
    // Covers: empty sessionRoots (no ENFORCE_WORKTREE_EXTRA_REPOS), non-git CWD regardless
    // of EXTRA_REPOS config, out-of-session CWD, and any misconfiguration.
    if (!sessionRoots || sessionRoots.size === 0 || !repoRoot) return { verdict: "abstain" };

    const cmd = (toolInput && typeof toolInput.command === "string") ? toolInput.command : "";
    if (!cmd) return { verdict: "abstain" };

    // Guard 2 (C1 fail-closed): sequenced commands may contain repo-internal write
    // segments invisible to any single extractor. Abstain immediately — UNLESS the
    // sequencing operators appear only inside a heredoc body (#1109) AND all targets
    // are provably under plans-dir (safe non-repo external writes).
    if (hasCommandSequencing(cmd)) {
      if (hasCommandSequencingOutsideHeredoc(cmd)) return { verdict: "abstain" };
      // Sequencing is heredoc-body-only: check targets now; allow if all under plans-dir.
      const { targets: hTargets, parseFailure: hPf } = collectBashWriteTargets(cmd);
      if (hPf || !areAllBashTargetsUnderPlansDir(hTargets)) return { verdict: "abstain" };
      return { verdict: "allow", reason: "heredoc-body-only sequencing; all write targets under plans-dir" };
    }

    // Extract write targets from all applicable extractors.
    const { targets, parseFailure } = collectBashWriteTargets(cmd);

    // Guard 3: parse failure from any extractor → abstain (fail-closed).
    if (parseFailure) return { verdict: "abstain" };

    // Guard 4: no targets extracted → unknown write destination → abstain.
    if (!targets || targets.length === 0) return { verdict: "abstain" };

    // Guard 5: every target must resolve outside every repo in sessionRoots.
    // Strip surrounding shell quotes first — some extractors (e.g. tee) return
    // raw token strings that include the original shell quote characters ("path" or 'path').
    // areAllBashTargetsOutsideSessionScope does not strip quotes internally.
    // Fail-closed to abstain if any target is in scope.
    const bareTargets = targets.map((t) => String(t).replace(/^["']|["']$/g, ""));
    if (!areAllBashTargetsOutsideSessionScope(bareTargets, sessionRoots)) {
      return { verdict: "abstain" };
    }
    return { verdict: "allow", reason: "all write targets outside session scope" };
  } catch (_) {
    // Any unexpected exception → abstain (fail-closed).
    return { verdict: "abstain" };
  }
}

module.exports = { checkUniversalTargetAllow };
