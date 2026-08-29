// hooks/enforce-worktree/handle-bash-write.js
// Extracted (mechanical move, file-split rules/coding/file-split.md) from the
// `Bash` branch of hooks/enforce-worktree.js. Handles Bash-tool write-target
// extraction, the protected-marker gate, the universal target-aware allow,
// Bug1/Bug2 checks, and the gh-write session-scope gate.
//
// Returns { repoRoot, writeDetector } on natural fall-through so the entrypoint
// can continue its post-dispatch checks. Calls `done()` (via ctx) for every
// allow/block exit — `done()` exits the process, so control never returns past it.

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
const { isGitWriteIR } = require("../lib/bash-write-patterns/patterns");
const { checkUniversalTargetAllow } = require("./universal-target-allow");
const { buildExtras } = require("./report-extras");
const { commandTextOf } = require("../lib/write-tools");

// Compute the write-target list and protected-marker-hit flag ONCE, ahead of
// every allow path below: several allow paths (universal-target-allow,
// Bug2's `repoRoot !== null` disjunct) approve purely on "outside session
// scope" — trivially true for the default workflow-dir location — without
// ever consulting the marker check. This single centralized gate skips ALL
// allow paths when any target hits a protected marker basename, falling
// through to fail-closed enforcement (same idiom as parseFailure below).
function handleBashWrite(ctx) {
  const { toolName, toolInput, _toolCwd, done, reportContext, sessionCtx } = ctx;
  // #2108: `{ sessionId, transcriptPath }` from the hook's stdin, forwarded to
  // every protected-basename decision so a stem can be tested against the ids a
  // clearance reader is actually keyed on. Absent means "cannot observe", which
  // the classifier resolves fail-closed.
  const _stemOpts = { sessionCtx };

  let repoRoot = null;
  let writeDetector = null;

  // runInTerminal/runCommands reach this handler too; runCommands carries an
  // ARRAY under `commands`, not `.command` — commandTextOf() normalizes both
  // so `if (!cmd) done()` can't approve a runCommands write via an empty read.
  const cmd = commandTextOf(toolName, toolInput);
  if (!cmd) done();
  const ir = parse(cmd);
  writeDetector = detectWritePredicate(ir);
  if (!writeDetector) done(); // read-only command — allow

  // `targets` / `parseFailure` / `_markerHit` are computed HERE, ahead of EVERY
  // allow path in this function (including the `git worktree remove/prune` and
  // `git branch -d/-D` branches below) — a sequenced command like
  // `git worktree prune && rm .workflow-off` must not ride a marker write out
  // on an earlier branch's allow. `repoRoot` moves up with it since
  // collectBashWriteTargets needs it; the worktree-remove/prune block below
  // still resolves its own `cwdRoot` from CWD on purpose, unaffected by this.
  repoRoot = findRepoRootForBash(cmd, _toolCwd);
  const { targets, parseFailure } = collectBashWriteTargets(ir, repoRoot);
  const _markerHit = parseFailure || bashTargetsHitProtectedMarker(targets, _stemOpts);

  // Early-exit for git worktree remove/prune (write confirmed above): resolve
  // repo root from CWD, not -C, so the CWD checkout type drives the decision
  // (prevents a -C target from wrongly allowing a linked-CWD/cross-repo call).
  // `!_markerHit &&` gates the WHOLE block: a marker-hit command must fall
  // through to fail-closed enforcement below rather than being answered by
  // either arm here (which would report a worktree-shaped reason for a
  // marker-shaped cause).
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
  // Both ALLOW exits carry `!_markerHit &&`: a protected-marker write riding
  // along on a branch-delete command must never be approved here — on a marker
  // hit it falls through to this block's own block reason instead (imprecise
  // wording, but the invariant that `_markerHit` never produces an ALLOW holds).
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

  // isGhWriteIR() classifies the WHOLE command as gh-write as soon as ANY segment
  // matches, so `gh issue comment 1 --body hi && rm .workflow-off` could reach the
  // unconditional allow below without the OTHER segment's marker write ever being
  // checked — gating entry on `_markerHit` (computed at the top) closes that gap.

  // gh write commands (Group B) get an extra session-scope check before the
  // standard main/worktree enforcement below. The whitelist defines the repos this
  // session manages; gh writes outside the set are blocked even from a worktree,
  // since out-of-session repos are not the current task's concern.
  if (!_markerHit && isGhWriteCommand(ir)) {
    // gh issue create skill-context gate: from the main worktree, require the
    // ISSUE_CREATE_SKILL=1 inline prefix so /issue-create (survey-first +
    // duplicate check) is used instead of a bare call. Linked worktrees are
    // unrestricted. isMainCheckout is trivalue-aware — null routes to block,
    // same as the main-path check below.
    if (/\bgh\s+issue\s+create\b/.test(stripQuotedArgs(cmd))) {
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
              " enforcement bypass.)",
          });
        }
        // Sanctioned: fall through to session-scope check below.
      }
      // Linked worktree: fall through to session-scope check below.
    }

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

  // A parse failure is treated as a marker hit for the allow paths' purposes:
  // when targets can't be extracted at all, nothing can be vouched for, so the
  // fast-paths must stay disabled rather than re-enabled (downstream branches
  // separately treat `parseFailure` as fail-closed for their own decisions).

  // Universal target-aware allow: allow if all extracted write targets are
  // outside the session scope, before shape-based predicate checks. Sequenced
  // commands and parse failures abstain (fail-closed).
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
      // Workflow state dir is runtime state, never source: writes fully under it
      // are allowed independent of sequencing (`mkdir -p WFDIR && echo x > WFDIR/f`
      // is not blocked). Checked per-segment, not the flat merged target list —
      // a sequenced command mixing one workflow-dir target with one
      // non-extractable write must still fail closed to the sequencing guard
      // below, which areAllWriteSegmentsUnderWorkflowDir (unlike the flat-list
      // areAllBashTargetsUnderWorkflowDir) guarantees.
      if (areAllWriteSegmentsUnderWorkflowDir(ir, repoRoot, _stemOpts)) done();

      // Commands with sequencing operators (;, &&, ||) may contain un-extracted
      // in-scope writes (e.g. `echo x > /tmp/out; rm README.md`). Skip the
      // session-scope / EXCLUDE fast-paths for those; fall through to the
      // main-checkout block (fail-closed). Single | (pipe) is allowed — it is
      // needed for `cmd | tee /out` and carries no sequencing risk beyond the tee.
      if (!hasCommandSequencing(cmd)) {
        // Bug 2: all targets resolve outside session scope → allow. When repoRoot
        // is null (non-git CWD), also require every target to resolve to a
        // non-git path or live under plans-dir/.claude — otherwise an empty
        // sessionRoots can't protect non-session git repos from cross-repo writes.
        if (areAllBashTargetsOutsideSessionScope(targets, sessionRoots) &&
            (repoRoot !== null ||
             areAllBashTargetsUnderPlansDir(targets) ||
             areAllBashTargetsUnderClaude(targets) ||
             areAllBashTargetsUnderWorkflowDir(targets, _stemOpts) ||
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
                  areAllBashTargetsUnderWorkflowDir(targets, _stemOpts))) {
        // Sequencing operators appear only inside a heredoc body (e.g. shell
        // fragments written by `cat <<'EOF' > plans-dir/file.md`) — the actual
        // write target is under plans-dir. Allow.
        done();
      } else if (excludePatterns.length > 0 &&
                 isEverySegmentExcluded(ir, repoRoot, excludePatterns)) {
        // Sequenced command where every write segment's targets are covered by
        // EXCLUDE (e.g. `mkdir -p .worktree-backup/x && cp src .worktree-backup/x/f`).
        done();
      }
    }

    // git -C <path> style (no file targets extracted): use repoRoot for scope check.
    // Gated on isGitWriteIR(ir) — without it, ANY write-detected command whose
    // target extraction comes up empty (npm install, rm -rf, Set-Content, eval,
    // bash -c, heredocs, sed -i, ...) would fall into this branch and get
    // evaluated against `isInSessionScope`, which never contains the main
    // worktree by design — silently ALLOWing every one of them from main.
    if (!targets && !parseFailure && repoRoot && isGitWriteIR(ir)) {
      if (!isInSessionScope(repoRoot, sessionRoots)) done();
    }
    // parseFailure → fail-closed: fall through to main-checkout block below.
  }

  // The one allow that is DEFINED on parse failure: /worktree-end's own backup
  // `cp` into `.worktree-backup`. It is kept outside the `_markerHit` guard
  // above because that guard now treats a parse failure itself as "cannot
  // vouch" — this narrow, shape-anchored escape is the deliberate exception,
  // named rather than left implicit (CPR-UNV).
  if (parseFailure && hasWorktreeEndSkillPrefix(cmd) && /^cp\s/.test(stripWorktreeEndSkillPrefix(cmd)) && /\.worktree-backup/.test(cmd)) done();

  return { repoRoot, writeDetector };
}

module.exports = { handleBashWrite };
