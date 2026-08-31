"use strict";
// hooks/enforce-worktree/universal-target-allow.js
// Universal target-aware allow rule (issue #1045).
// For Bash commands from main worktree under ENFORCE_WORKTREE=on:
// allow when every parseable write target resolves outside the session scope.
// Sequenced commands and parse failures → abstain (fail-closed, C1).

const { collectBashWriteTargets, areAllBashTargetsOutsideSessionScope, areAllBashTargetsUnderPlansDir, areAllBashTargetsUnderClaude, areAllWriteSegmentsOutsideSessionScope } = require("./bash-write-scope");
const { hasCommandSequencing, hasHeredoc } = require("./shared-cmd-utils");
const { parse } = require("../lib/command-ir");

// Allow a Bash command's write targets when all resolve outside session scope;
// abstain (fail-closed) on: non-Bash tool, empty sessionRoots, null repoRoot,
// real sequencing operators (C1), no/unparseable targets, an in-scope target,
// or an exception. A repoRoot outside sessionRoots (e.g. `git -C /otherRepo`)
// still applies the rule — targets are what's evaluated, not the CWD repo.
// @param toolName, toolInput, sessionRoots, repoRoot — see getSessionRepoRoots().
// @param ir  optional pre-parsed IR; parsed internally when omitted.
// @returns {{ verdict: 'allow' | 'abstain', reason?: string }}
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

    // Guard 2 (C1 fail-closed): real sequencing (outside any heredoc body — #2121,
    // hasCommandSequencing is heredoc-aware) may hide repo-internal write segments
    // from any single extractor. Abstain UNLESS all write segments are provably
    // outside session scope (#1448A).
    if (hasCommandSequencing(cmd)) {
      const seqIr = parse(cmd);
      if (areAllWriteSegmentsOutsideSessionScope(seqIr, repoRoot, sessionRoots)) {
        return { verdict: "allow", reason: "all write segments outside session scope" };
      }
      return { verdict: "abstain" };
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
    // each target's .path internally (centralized quote-strip — CPR-SSOT), so no
    // pre-stripping is needed here. Fail-closed to abstain if any target is in scope.
    // Heredoc commands are excluded here; they must clear the narrower
    // plans-dir/claude gate in Guard 6 below.
    if (!hasHeredoc(cmd) && areAllBashTargetsOutsideSessionScope(targets, sessionRoots)) {
      return { verdict: "allow", reason: "all write targets outside session scope" };
    }

    // Guard 6 (#1109): sequencing-free command whose only operators (if any) were
    // heredoc-body-internal — allow when all write targets are under plans-dir or
    // the claude scratchpad (safe non-repo external writes).
    if (hasHeredoc(cmd) && (areAllBashTargetsUnderPlansDir(targets) || areAllBashTargetsUnderClaude(targets))) {
      return { verdict: "allow", reason: "heredoc-body-only sequencing; all write targets under plans-dir or claude scratchpad" };
    }
    return { verdict: "abstain" };
  } catch (_) {
    // Any unexpected exception → abstain (fail-closed).
    return { verdict: "abstain" };
  }
}

module.exports = { checkUniversalTargetAllow };
