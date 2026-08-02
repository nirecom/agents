// hooks/enforce-worktree/handle-bash-write.js
// Extracted verbatim (mechanical move only — no logic/behavior change) from the
// `if (toolName === "Bash") { ... }` branch of hooks/enforce-worktree.js
// (file-split, rules/coding/file-split.md — entrypoint exceeded the 500-line HARD
// limit). Handles all Bash-tool write-target extraction, the #1780 H-3 protected-
// marker gate, the universal target-aware allow (#1045), Bug1/Bug2 checks, and the
// gh-write (#713 / Group B) session-scope gate.
//
// Returns { repoRoot, writeDetector } on natural fall-through (no allow/block
// decision reached inside this branch) so the entrypoint can continue with its
// post-dispatch main-checkout / protected-branch checks using the same values
// the inline code would have left in `repoRoot` / `_writeDetector`.
// Calls `done()` (passed in via ctx) for every allow/block exit, exactly as the
// original inline code did — `done()` calls process.exit(0), so control never
// returns past those points.

"use strict";

const { stripQuotedArgs } = require("../lib/strip-quoted-args");
const { detectWritePredicate } = require("./write-detector");
const { parse } = require("../lib/command-ir");
const { findRepoRootForBash, isMainCheckout, normalizeForCompare, findRepoRoot } = require("./git-repo-detection");
const { getSessionRepoRoots } = require("./session-scope");
const { hasGitHooksBypass } = require("./git-hooks-bypass");
const { hasCommandSequencing, hasCommandSequencingOutsideHeredoc, getExcludePatterns, hasWorktreeEndSkillPrefix, stripWorktreeEndSkillPrefix } = require("./shared-cmd-utils");
const { isBranchDeleteCommand, isAllowedBranchDeleteWhenNotCheckedOut } = require("./branch-delete-guard");
const { isAllowedWorktreeCommand } = require("./main-worktree-allows");
const { isInSessionScope, collectBashWriteTargets, areAllBashTargetsOutsideSessionScope, areAllWriteSegmentsUnderWorkflowDir, areAllBashTargetsUnderPlansDir, areAllBashTargetsUnderClaude, areAllBashTargetsUnderWorkflowDir, isWriteTargetAllExcluded, isEverySegmentExcluded, isGhWriteCommand, bashTargetsHitProtectedMarker } = require("./bash-write-scope");
const { checkUniversalTargetAllow } = require("./universal-target-allow");
const { buildExtras } = require("./report-extras");
const { commandTextOf } = require("../lib/write-tools");

// #1780 H-3 (security-scanner round 8): compute the write-target list and the
// protected-marker-hit flag ONCE, ahead of every allow path below.
// checkUniversalTargetAllow's session-scope guard and the Bug2
// `repoRoot !== null` disjunct both approve purely on "outside session scope" —
// trivially true for the default workflow-dir location — without ever calling
// areAllBashTargetsUnderWorkflowDir(), the only function that previously
// consulted PROTECTED_MARKER_BASENAME_RE. A single centralized early gate (per
// the scanner's own stated preference over scattering the check into each
// allow path) skips ALL allow paths when any target hits a protected marker
// basename, falling through to fail-closed enforcement — same idiom already
// used for parseFailure below.
function handleBashWrite(ctx) {
  const { toolName, toolInput, _toolCwd, done, reportContext } = ctx;

  let repoRoot = null;
  let writeDetector = null;

  // H-2 (#1780 round-4): runInTerminal/runCommands reach this handler too, and
  // runCommands carries an ARRAY under `commands`. Reading `.command` yielded ""
  // for it, so `if (!cmd) done()` approved every runCommands write outright.
  const cmd = commandTextOf(toolName, toolInput);
  if (!cmd) done();
  const ir = parse(cmd);
  writeDetector = detectWritePredicate(ir);
  if (!writeDetector) done(); // read-only command — allow

  // #1780 round-13 (CPR-5 sibling-symmetry gap): `targets` / `parseFailure` /
  // `_markerHit` are computed HERE — ahead of EVERY allow path in this function,
  // which is what the centralized-gate comment above handleBashWrite has always
  // stated the design to be. The round-13 fix that introduced the gate only
  // hoisted the computation above the gh-write branch, leaving two earlier
  // branches — `git worktree remove/prune` and `git branch -d/-D` — able to
  // reach `done()` (allow) without ever consulting it. A sequenced command such
  // as `git worktree prune && rm .workflow-off` therefore rode its protected-
  // marker write out on the worktree-prune allow. `repoRoot` moves up with it
  // because collectBashWriteTargets needs it; the worktree-remove/prune block
  // below never read the outer `repoRoot` (it resolves its own `cwdRoot` from
  // the CWD on purpose), so the earlier assignment changes nothing for it.
  repoRoot = findRepoRootForBash(cmd, _toolCwd);
  const { targets, parseFailure } = collectBashWriteTargets(ir, repoRoot);
  const _markerHit = parseFailure || bashTargetsHitProtectedMarker(targets);

  // Early-exit for git worktree remove/prune (write confirmed above): resolve
  // repo root from CWD (not from -C flag) so the CWD checkout type drives the
  // allow/block decision. This prevents the main-path isMainCheckout(repoRoot)
  // from wrongly resolving via a -C target and allowing linked-CWD or
  // cross-repo invocations. Non-git CWD (cwdRoot===null) falls through to the
  // main fail-closed block below.
  // `!_markerHit &&` gates entry to the WHOLE block, not just its allow arm:
  // when a target hits a protected marker basename the command must fall through
  // to the fail-closed enforcement further down — exactly as the gh-write branch
  // does — rather than being answered here by either arm (blocking here would
  // report a worktree-shaped reason for a marker-shaped cause).
  if (!_markerHit && /\bgit\b/.test(cmd) && /\bworktree\s+(?:remove|prune)\b/.test(cmd)) {
    const cwdRoot = findRepoRootForBash("git", _toolCwd);
    if (cwdRoot !== null) {
      const cwd = _toolCwd || process.cwd();
      if (isMainCheckout(cwd) === true && isAllowedWorktreeCommand(cmd, cwdRoot)) {
        done();
      } else {
        done({
          block: true,
          reason:
            "ENFORCE_WORKTREE: git worktree remove/prune blocked.\n" +
            "Reason: must be invoked from the main worktree (not a linked worktree),\n" +
            "and -C (if used) must target the main repo root.\n" +
            "Use /worktree-end to remove a linked worktree.",
        });
      }
    }
  }

  // git branch -d/-D: gated by direct check against `git worktree list --porcelain`.
  // Allowed only when the target branch is not currently checked out in any worktree.
  //
  // Both ALLOW exits carry the `!_markerHit &&` guard (same gate as the branches
  // above/below): a protected-marker write riding along on a branch-delete
  // command must never be approved here. On a marker hit the command falls to
  // this block's own `done({block:true, …})`. Its wording names branch-delete
  // rather than the marker, which is imprecise but still a correct refusal — the
  // invariant that matters is that `_markerHit` can never produce an ALLOW.
  if (isBranchDeleteCommand(cmd)) {
    if (!_markerHit && !repoRoot) done(); // not in a git repo — allow (matches policy below)
    if (!_markerHit && isAllowedBranchDeleteWhenNotCheckedOut(cmd, repoRoot)) done();
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: git branch -d/-D blocked — target branch is still " +
        "checked out in a worktree, force-delete was issued without the " +
        "`WORKTREE_END_SKILL=1 git -C <path> branch -D <branch>` inline prefix " +
        "shape required for /worktree-end Step WE-19 authorization, or " +
        "`git worktree list` failed.\n" +
        "- If the worktree is still active: run `/worktree-end` first to remove it, then retry.\n" +
        "- If the worktree was already removed but the registry is stale: run " +
        "`git worktree prune`, then retry.\n" +
        "- If you need to force-delete an unmerged branch: set " +
        "`ENFORCE_WORKTREE=off` in agents config, run the delete, then restore it.\n" +
        "- Or run `/sweep-worktrees --apply` to reclaim merged zombie worktrees.",
    });
  }

  if (hasGitHooksBypass(cmd)) {
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: git hooks bypass blocked. Reason: hook-disabling override.\n" +
        "Blocked: git -c core.hooksPath=…, git --config-env=core.hooksPath=…,\n" +
        "GIT_CONFIG_PARAMETERS=…core.hooksPath… git …, and\n" +
        "GIT_CONFIG_KEY_<n>=core.hooksPath … git ….\n" +
        "These disable pre-commit / commit-msg / pre-push hooks.\n" +
        "Remove the override, or set ENFORCE_WORKTREE=off in agents config\n" +
        "if the bypass is intentional.",
    });
  }

  // #1780 scanner G: `_markerHit` is now computed at the TOP of this function
  // (see the round-13 comment there); it was hoisted here first, ahead of the
  // gh-write branch below, and later all the way up so the two git branches
  // above are covered too. isGhWriteIR()
  // classifies the WHOLE command as gh-write as soon as ANY segment matches a
  // gh-write pattern (hooks/lib/bash-write-patterns/patterns.js) — so a
  // sequenced command like `gh issue comment 1 --body hi && rm .workflow-off`
  // was reaching the gh-write branch's unconditional `done()` (allow) below
  // without ever consulting bashTargetsHitProtectedMarker on its OTHER
  // segment, letting a protected-marker write ride along inside an
  // otherwise-legitimate gh command. Computing `_markerHit` first and gating
  // entry to the gh-write branch on it (see the `!_markerHit &&` below) closes
  // that gap: a marker hit now falls through to the same fail-closed
  // enforcement every other allow path already defers to (see the
  // centralized-gate comment above `handleBashWrite`).

  // gh write commands (Group B) get an extra session-scope check before the
  // standard main/worktree enforcement below. The whitelist defines the set of
  // repos this session manages; gh writes outside the set are blocked even
  // from a worktree, on the principle that out-of-session repos are not the
  // current task's concern.
  if (!_markerHit && isGhWriteCommand(ir)) {
    // --- #713: gh issue create skill-context gate ---
    // Stage A: determine main worktree vs linked worktree.
    // Stage B (main only): require ISSUE_CREATE_SKILL=1 inline prefix to enforce
    // that /issue-create skill (survey-first + duplicate check) is used.
    // Linked worktrees bypass Stage B — bare `gh issue create` is unrestricted there.
    if (/\bgh\s+issue\s+create\b/.test(stripQuotedArgs(cmd))) {
      // Axis A (#885): trivalue-aware — null (isMainCheckout indeterminate) routes
      // to the block side, same as the main-path at line 441.
      const mainCheckoutResultGate = repoRoot ? isMainCheckout(repoRoot) : false;
      if (mainCheckoutResultGate !== false) {
        const SANCTIONED_RE =
          /^[ \t]*(?:MSYS_NO_PATHCONV=1[ \t]+)?ISSUE_CREATE_SKILL=1[ \t]+gh[ \t]+issue[ \t]+create\b/;
        if (!SANCTIONED_RE.test(cmd)) {
          reportContext.extras = buildExtras(cmd, _toolCwd, repoRoot, mainCheckoutResultGate);
          done({
            block: true,
            reason:
              "ENFORCE_WORKTREE: bare `gh issue create` blocked from main worktree.\n" +
              "Reason: /issue-create skill must be used (survey-first + duplicate check).\n" +
              "Run `/issue-create --title ... --body ...` from this session, or from a linked\n" +
              "worktree if you really need bare `gh issue create`.\n" +
              "(`ISSUE_CREATE_SKILL=1` is a content-integrity marker — NOT a worktree-\n" +
              " enforcement bypass; cf. #672 removal of ISSUE_CLOSE_SKILL bypass.)",
          });
        }
        // Sanctioned: fall through to session-scope check below.
      }
      // Linked worktree → Stage B skip → session-scope check below.
    }
    // --- end #713 gate ---

    const sessionRoots = getSessionRepoRoots();
    const detected = repoRoot ? normalizeForCompare(repoRoot) : null;

    if (!detected) {
      done({
        block: true,
        reason:
          "ENFORCE_WORKTREE: gh write blocked. Reason: cannot determine repo root for this command.\n" +
          "Run gh from inside a session repo's worktree, or set ENFORCE_WORKTREE=off." +
          (writeDetector ? `\nDetected by: ${writeDetector.detail} (${writeDetector.name})` : ""),
      });
    }
    if (!sessionRoots.has(detected)) {
      done({
        block: true,
        reason:
          `ENFORCE_WORKTREE: gh write blocked. Reason: target repo (${repoRoot}) is not in session scope.\n` +
          "Add this repo to ENFORCE_WORKTREE_ADDITIONAL_REPOS in agents config, or run from a session repo.\n" +
          "Or set ENFORCE_WORKTREE=off to bypass." +
          (writeDetector ? `\nDetected by: ${writeDetector.detail} (${writeDetector.name})` : ""),
      });
    }
    // gh writes are GitHub operations, not local file writes — session-scope is sufficient.
    done();
  }

  const sessionRoots = getSessionRepoRoots();

  // #1780 round-5 HIGH-2: `!parseFailure &&` inverted the sense of this gate.
  // `_markerHit` means "skip every allow fast-path", so a command whose targets
  // could not be extracted at all — the exact state in which nothing can be
  // vouched for — was the one state that re-enabled them. A parse failure is a
  // marker hit as far as the allow paths are concerned; the downstream branches
  // already treat `parseFailure` as fail-closed for their own decisions.
  // (`targets` / `parseFailure` / `_markerHit` themselves are now computed once,
  // ahead of the gh-write branch above — see the scanner G comment there.)

  // Universal target-aware allow (L1, #1045): allow if all extracted write targets
  // are outside the session scope, before shape-based predicate checks.
  // Sequenced commands and parse failures → abstain (fail-closed, C1).
  if (!_markerHit) {
    const _ur = checkUniversalTargetAllow(toolName, toolInput, sessionRoots, repoRoot, ir);
    if (_ur.verdict === "allow") done();
  }

  // Bug 2 + Bug 1: non-gh Bash writes — check actual write targets.
  if (!_markerHit) {
    // sessionRoots and targets/parseFailure are already in scope (hoisted above
    // for the marker gate and universal-rule reuse).
    const excludePatterns = getExcludePatterns();

    if (!parseFailure) {
      // #1709: workflow state dir is runtime state, never source. Writes whose
      // targets all resolve under the workflow dir are always allowed, independent
      // of sequencing — hoisted above the Bug2 branch so that
      // `mkdir -p WFDIR && echo x > WFDIR/f` (sequenced, but every target still
      // under the workflow dir) is not blocked.
      // H-2 fix: per-segment check, not the flat merged target list — a sequenced
      // command mixing one extractable workflow-dir target with one
      // non-extractable write (e.g. `echo x > WFDIR/f && bash ./build.sh`) must
      // still fail closed to the sequencing guard below. areAllWriteSegmentsUnderWorkflowDir
      // fails closed on any write segment whose targets aren't all provably under
      // the workflow dir, unlike the flat-list areAllBashTargetsUnderWorkflowDir.
      if (areAllWriteSegmentsUnderWorkflowDir(ir, repoRoot)) done();

      // Commands with sequencing operators (;, &&, ||) may contain un-extracted
      // in-scope writes (e.g. `echo x > /tmp/out; rm README.md`). Skip the
      // session-scope / EXCLUDE fast-paths for those; fall through to the
      // main-checkout block (fail-closed). Single | (pipe) is allowed — it is
      // needed for `cmd | tee /out` and carries no sequencing risk beyond the tee.
      if (!hasCommandSequencing(cmd)) {
        // Bug 2: all targets resolve outside session scope → allow.
        // Non-git CWD (#1448B): when repoRoot is null, also require that every target
        // resolves to a non-git path (findRepoRoot===null) or is under plans-dir/.claude.
        // Without repoRoot, sessionRoots may be empty and cannot reliably protect
        // non-session git repos from accidental cross-repo writes.
        // #1709: the workflow-dir allow is handled unconditionally above; the
        // disjunct below is a separate condition of the Bug 2 rule.
        if (areAllBashTargetsOutsideSessionScope(targets, sessionRoots) &&
            (repoRoot !== null ||
             areAllBashTargetsUnderPlansDir(targets) ||
             areAllBashTargetsUnderClaude(targets) ||
             areAllBashTargetsUnderWorkflowDir(targets) ||
             targets.every(t => findRepoRoot(String(t.path || '').replace(/^["']|["']$/g, '')) === null))) {
          done();
        }

        // Bug 1: all targets covered by EXCLUDE → allow.
        if (excludePatterns.length > 0 &&
            isWriteTargetAllExcluded(cmd, targets, repoRoot, excludePatterns)) {
          done();
        }
      } else if (!hasCommandSequencingOutsideHeredoc(cmd) &&
                 (areAllBashTargetsUnderPlansDir(targets) || areAllBashTargetsUnderClaude(targets) ||
                  areAllBashTargetsUnderWorkflowDir(targets))) {
        // #1109: sequencing operators appear ONLY inside a heredoc body (e.g.
        // shell fragments written by `cat <<'EOF' > plans-dir/file.md`).
        // The actual write target is under plans-dir — allow.
        done();
      } else if (excludePatterns.length > 0 &&
                 isEverySegmentExcluded(ir, repoRoot, excludePatterns)) {
        // #739: sequenced commands where every write segment's targets are all
        // covered by EXCLUDE → allow (e.g. `mkdir -p .worktree-backup/x && cp src .worktree-backup/x/f`).
        done();
      }
    }

    // git -C <path> style (no file targets extracted): use repoRoot for scope check.
    if (!targets && !parseFailure && repoRoot) {
      if (!isInSessionScope(repoRoot, sessionRoots)) done();
    }
    // parseFailure → fail-closed: fall through to main-checkout block below.
  }

  // The one allow that is DEFINED on parse failure: /worktree-end's own backup
  // `cp` into `.worktree-backup`. It is kept outside the `_markerHit` guard
  // above because that guard now treats a parse failure itself as "cannot
  // vouch" — this narrow, shape-anchored escape is the deliberate exception,
  // named rather than left implicit (CPR-8).
  if (parseFailure && hasWorktreeEndSkillPrefix(cmd) && /^cp\s/.test(stripWorktreeEndSkillPrefix(cmd)) && /\.worktree-backup/.test(cmd)) done();

  return { repoRoot, writeDetector };
}

module.exports = { handleBashWrite };
