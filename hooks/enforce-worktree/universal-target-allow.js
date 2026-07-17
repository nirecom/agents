"use strict";
// hooks/enforce-worktree/universal-target-allow.js
// Universal target-aware allow rule (issue #1045).
// For Bash commands from main worktree under ENFORCE_WORKTREE=on:
// allow when every parseable write target resolves outside the session scope.
// Sequenced commands and parse failures → abstain (fail-closed, C1).

const { collectBashWriteTargets, areAllBashTargetsOutsideSessionScope, areAllBashTargetsUnderPlansDir, areAllBashTargetsUnderClaude, areAllWriteSegmentsOutsideSessionScope } = require("./bash-write-scope");
const { hasCommandSequencing, hasCommandSequencingOutsideHeredoc } = require("./shared-cmd-utils");
const { parse } = require("../lib/command-ir");

/**
 * Check whether a Bash command's write targets are all outside the session scope.
 * Returns { verdict: 'allow' } when all extracted targets are outside every repo in sessionRoots.
 * Returns { verdict: 'abstain' } in all other cases (fail-closed):
 *   - non-Bash tool
 *   - sessionRoots is empty (non-git CWD with no extra repos configured)
 *   - repoRoot is null (non-git CWD — even when ADDITIONAL_REPOS is configured,
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
 * @param {import('../lib/command-ir').IR} [ir]  Optional pre-parsed IR; if omitted, cmd is parsed internally.
 * @returns {{ verdict: 'allow' | 'abstain', reason?: string }}
 */
function checkUniversalTargetAllow(toolName, toolInput, sessionRoots, repoRoot, ir) {
  try {
    // Only applies to Bash commands; Edit/Write/MultiEdit are handled by
    // isInSessionScope in the caller (line ~387 of enforce-worktree.js).
    if (toolName !== "Bash") return { verdict: "abstain" };

    // Guard 1: no session scope to compare against, or non-git/out-of-session CWD — abstain.
    // Covers: empty sessionRoots (no ENFORCE_WORKTREE_ADDITIONAL_REPOS), non-git CWD regardless
    // of ADDITIONAL_REPOS config, out-of-session CWD, and any misconfiguration.
    if (!sessionRoots || sessionRoots.size === 0 || !repoRoot) return { verdict: "abstain" };

    const cmd = (toolInput && typeof toolInput.command === "string") ? toolInput.command : "";
    if (!cmd) return { verdict: "abstain" };

    const irToUse = ir || parse(cmd);

    // Guard 2 (C1 fail-closed): sequenced commands may contain repo-internal write
    // segments invisible to any single extractor. Abstain immediately — UNLESS the
    // sequencing operators appear only inside a heredoc body (#1109) AND all targets
    // are provably under plans-dir (safe non-repo external writes), OR all write
    // segments are provably outside session scope (#1448A).
    if (hasCommandSequencing(cmd)) {
      if (hasCommandSequencingOutsideHeredoc(cmd)) {
        const seqIr = parse(cmd);
        if (areAllWriteSegmentsOutsideSessionScope(seqIr, repoRoot, sessionRoots)) {
          return { verdict: "allow", reason: "all write segments outside session scope" };
        }
        return { verdict: "abstain" };
      }
      // Sequencing is heredoc-body-only: check targets now; allow if all under plans-dir.
      const { targets: hTargets, parseFailure: hPf } = collectBashWriteTargets(irToUse, repoRoot);
      if (hPf || !(areAllBashTargetsUnderPlansDir(hTargets) || areAllBashTargetsUnderClaude(hTargets))) return { verdict: "abstain" };
      return { verdict: "allow", reason: "heredoc-body-only sequencing; all write targets under plans-dir or claude scratchpad" };
    }

    // Extract write targets from all applicable extractors (forward repoRoot so a
    // git self-target is visible on the universal path too — D4).
    const { targets, parseFailure } = collectBashWriteTargets(irToUse, repoRoot);

    // Guard 3: parse failure from any extractor → abstain (fail-closed).
    if (parseFailure) return { verdict: "abstain" };

    // Guard 4: no targets extracted → unknown write destination → abstain.
    if (!targets || targets.length === 0) return { verdict: "abstain" };

    // Guard 5: every target must resolve outside every repo in sessionRoots.
    // areAllBashTargetsOutsideSessionScope strips surrounding shell quotes from
    // each target's .path internally (centralized quote-strip — CPR-2), so no
    // pre-stripping is needed here. Fail-closed to abstain if any target is in scope.
    if (!areAllBashTargetsOutsideSessionScope(targets, sessionRoots)) {
      return { verdict: "abstain" };
    }
    return { verdict: "allow", reason: "all write targets outside session scope" };
  } catch (_) {
    // Any unexpected exception → abstain (fail-closed).
    return { verdict: "abstain" };
  }
}

module.exports = { checkUniversalTargetAllow };
