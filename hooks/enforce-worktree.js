#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce worktree-based parallel session workflow.
//
// Blocks Edit/Write/MultiEdit/Bash write operations when:
//   1. Running in the main git checkout (not a linked worktree), regardless of branch.
//   2. Running on a protected branch even inside a linked worktree.
// Allows writes only from a linked worktree on a non-protected branch.
//
// Implementation is split across sibling modules under hooks/enforce-worktree/:
//   config / git-repo-detection / session-scope / git-hooks-bypass /
//   shared-cmd-utils / branch-delete-guard / main-worktree-allows / bash-write-scope.
// This file holds the dispatch block plus three small helpers (readStdin / done /
// getWorktreeBaseDirResolved). docs(history|changelog) writes use the GitHub REST
// API and bypass local file/git writes (Contents API: bin/lib/github-contents-write.sh,
// Git Data API: bin/lib/github-git-data-write.sh). Limitations: Bash write detection
// is pattern-based (UX guard, not a security boundary). Use ENFORCE_WORKTREE=off to
// bypass for trivial direct-main work.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { resolveSessionId } = require("./lib/workflow-state");
const { stripQuotedArgs } = require("./lib/strip-quoted-args");
const { classify } = require("./lib/bash-write-patterns");
const { parseCdCommand } = require("./lib/parse-git-args");
const { isEnforceWorktreeOn, getProtectedBranches, getCurrentBranch } = require("./enforce-worktree/config");
const { isMainCheckout, parseGitCPath, findRepoRootForBash, normalizeForCompare, findRepoRoot } = require("./enforce-worktree/git-repo-detection");
const { setPayloadDerivedPaths, _getPayloadDerivedPaths, getSessionRepoRoots } = require("./enforce-worktree/session-scope");
const { hasGitHooksBypass } = require("./enforce-worktree/git-hooks-bypass");
const { findFirstUnquotedAnd, hasCommandSequencing, isExcluded, getExcludePatterns, hasWorktreeEndSkillPrefix, stripWorktreeEndSkillPrefix } = require("./enforce-worktree/shared-cmd-utils");
const { isBranchDeleteCommand, parseBranchDeleteTarget, isAllowedBranchDeleteWhenNotCheckedOut } = require("./enforce-worktree/branch-delete-guard");
const { isAllowedWorktreeCommand, isAllowedFastForwardMerge, isAllowedReadOnlyConfigCheck, isAllowedPushAllExcluded, isAllowedMidOperationAbort, isAllowedMainWorktreeCleanup, isAllowedComposeDocAppend } = require("./enforce-worktree/main-worktree-allows");
const { isInSessionScope, collectBashWriteTargets, areAllBashTargetsOutsideSessionScope, areAllBashTargetsUnderPlansDir, isWriteTargetAllExcluded, isEverySegmentExcluded, isGhWriteCommand } = require("./enforce-worktree/bash-write-scope");
const { checkUniversalTargetAllow } = require("./enforce-worktree/universal-target-allow");

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (e) {
    return "";
  }
}

// Resolve WORKTREE_BASE_DIR with ~ expansion and a default of ~/git/worktrees.
// Per rules/worktree.md, this is the parent directory all linked worktrees live under.
function getWorktreeBaseDirResolved() {
  const raw = (process.env.WORKTREE_BASE_DIR || "").trim();
  const baseRaw = raw || path.join(os.homedir(), "git", "worktrees");
  const expanded = baseRaw.startsWith("~")
    ? path.join(os.homedir(), baseRaw.slice(1).replace(/^[\/\\]/, ""))
    : baseRaw;
  return path.resolve(expanded);
}

// Captured at hook-input parse time so the `done()` helper can self-report on block.
let _reportContext = { sessionId: undefined, command: undefined, toolName: undefined, extras: undefined };

const { buildExtras } = require("./enforce-worktree/block-extras");

function done(decision) {
  if (decision && decision.block) {
    try {
      const { reportBlock } = require("./lib/supervisor-emit");
      reportBlock(
        "enforce-worktree",
        _reportContext.command || _reportContext.toolName || "<unknown>",
        _reportContext.sessionId,
        _reportContext.extras || {}
      );
    } catch (_) { /* fail-open */ }
    console.log(JSON.stringify({ decision: "block", reason: decision.reason }));
  } else {
    console.log(JSON.stringify({}));
  }
  process.exit(0);
}

// ── Main ──────────────────────────────────────────────────────────────────────
// Wrapped in `if (require.main === module)` so the file can be `require()`d
// from tests without executing the CLI flow (which reads stdin and exits).

if (require.main === module) {

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

if (!isEnforceWorktreeOn()) done();

// Session-scoped WORKFLOW override (broader than WORKTREE; bypasses everything
// except enforce-system-ops). Placed BEFORE the worktree-off check because
// WORKFLOW_OFF subsumes WORKTREE_OFF.
{
  const sid = (input && input.session_id) || resolveSessionId();
  const { isWorkflowOff, workflowOffNoticeText } = require("./lib/session-markers");
  if (isWorkflowOff(sid)) {
    process.stderr.write(workflowOffNoticeText("enforce-worktree", sid) + "\n");
    process.exit(0);
  }
}

// Session-scoped escape hatch: if the current session has a marker file,
// treat as ENFORCE_WORKTREE=off for this session only. Set via:
//   echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF[: reason]>>"
// Restore by deleting the marker. Fail-closed when sessionId is unresolvable.
try {
  const sid = (input && input.session_id) || resolveSessionId();
  const { isWorktreeOff, worktreeOffNoticeText } = require("./lib/session-markers");
  if (isWorktreeOff(sid)) {
    process.stderr.write(worktreeOffNoticeText("enforce-worktree", sid) + "\n");
    done();
  }
} catch (e) {
  process.stderr.write(
    `enforce-worktree: marker check failed (${e.message}); enforcement remains ON.\n`
  );
}

// Defence-in-depth: if process.cwd() is unresolvable (e.g. after
// git worktree remove from inside the removed worktree), fail-open.
// Root cause fix: skills/worktree-end/SKILL.md Step WE-13 (cd <main> before remove).
// See issue #268. Fail-open ONLY for ENOENT / missing-dir — not all errors.
let _cwd;
try {
  _cwd = process.cwd();
} catch (e) {
  if (e && e.code === "ENOENT") {
    process.stderr.write(
      "enforce-worktree: fail-open — process.cwd() threw ENOENT (issue #268 backstop).\n"
    );
    done();
  }
  throw e; // unexpected error: do not silently fail-open
}
if (!fs.existsSync(_cwd)) {
  process.stderr.write(
    "enforce-worktree: fail-open — process.cwd() points to a deleted directory (issue #268 backstop).\n"
  );
  done();
}

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

// Populate supervisor-emit context for done() block self-report.
_reportContext = {
  sessionId: (input && input.session_id) || undefined,
  command: (toolInput && toolInput.command) || undefined,
  toolName,
  extras: undefined,
};

// toolInput.cwd is the Bash tool's `cwd` parameter when explicitly provided.
// We populate context.cwd from it when present; falls back to process.cwd()
// only in places where we need a real path (not propagated to extras).
const _toolCwd = typeof toolInput.cwd === "string" ? toolInput.cwd : undefined;

// Populate payload-derived-path cache for this invocation (issue #321).
// Read by getSessionRepoRoots() to scope the gh-write guard to the paths
// the CURRENT command names explicitly.
{
  const derived = [];
  if (toolName === "Bash") {
    const _cmd = toolInput.command || "";
    const _cArg = parseGitCPath(_cmd);
    if (_cArg && path.isAbsolute(_cArg)) derived.push(_cArg);
    const _cdArg = parseCdCommand(_cmd);
    if (_cdArg) derived.push(_cdArg);
  } else if (toolName === "Edit" || toolName === "Write" || toolName === "MultiEdit") {
    const fp = toolInput.file_path || toolInput.path;
    if (fp && typeof fp === "string" && path.isAbsolute(fp)) derived.push(fp);
    if (toolName === "MultiEdit" && Array.isArray(toolInput.edits)) {
      for (const e of toolInput.edits) {
        if (e && typeof e.file_path === "string" && path.isAbsolute(e.file_path)) {
          derived.push(e.file_path);
        }
      }
    }
  }
  setPayloadDerivedPaths(derived);
}

let repoRoot = null;

if (toolName === "Bash") {
  const cmd = toolInput.command || "";
  if (!cmd) done();
  if (classify(cmd) !== "write") done(); // read-only command — allow
  repoRoot = findRepoRootForBash(cmd, _toolCwd);

  // git branch -d/-D: gated by direct check against `git worktree list --porcelain`.
  // Allowed only when the target branch is not currently checked out in any worktree.
  if (isBranchDeleteCommand(cmd)) {
    if (!repoRoot) done(); // not in a git repo — allow (matches policy below)
    if (isAllowedBranchDeleteWhenNotCheckedOut(cmd, repoRoot)) done();
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

  // gh write commands (Group B) get an extra session-scope check before the
  // standard main/worktree enforcement below. The whitelist defines the set of
  // repos this session manages; gh writes outside the set are blocked even
  // from a worktree, on the principle that out-of-session repos are not the
  // current task's concern.
  if (isGhWriteCommand(cmd)) {
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
          _reportContext.extras = buildExtras(cmd, _toolCwd, repoRoot, mainCheckoutResultGate);
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
          "Run gh from inside a session repo's worktree, or set ENFORCE_WORKTREE=off.",
      });
    }
    if (!sessionRoots.has(detected)) {
      done({
        block: true,
        reason:
          `ENFORCE_WORKTREE: gh write blocked. Reason: target repo (${repoRoot}) is not in session scope.\n` +
          "Add this repo to ENFORCE_WORKTREE_EXTRA_REPOS in agents config, or run from a session repo.\n" +
          "Or set ENFORCE_WORKTREE=off to bypass.",
      });
    }
    // gh writes are GitHub operations, not local file writes — session-scope is sufficient.
    done();
  }

  const sessionRoots = getSessionRepoRoots();

  // Universal target-aware allow (L1, #1045): allow if all extracted write targets
  // are outside the session scope, before shape-based predicate checks.
  // Sequenced commands and parse failures → abstain (fail-closed, C1).
  {
    const _ur = checkUniversalTargetAllow(toolName, toolInput, sessionRoots, repoRoot);
    if (_ur.verdict === "allow") done();
  }

  // Bug 2 + Bug 1: non-gh Bash writes — check actual write targets.
  {
    // sessionRoots is already in scope (hoisted above for universal-rule reuse)
    const excludePatterns = getExcludePatterns();
    const { targets, parseFailure } = collectBashWriteTargets(cmd);

    if (!parseFailure) {
      // Commands with sequencing operators (;, &&, ||) may contain un-extracted
      // in-scope writes (e.g. `echo x > /tmp/out; rm README.md`). Skip the
      // session-scope / EXCLUDE fast-paths for those; fall through to the
      // main-checkout block (fail-closed). Single | (pipe) is allowed — it is
      // needed for `cmd | tee /out` and carries no sequencing risk beyond the tee.
      if (!hasCommandSequencing(cmd)) {
        // Bug 2: all targets resolve outside session scope (incl. non-git paths) → allow.
        // Non-git CWD (#878): allow when all targets are provably under plans-dir;
        // arbitrary external paths (e.g. /tmp/x) remain fail-closed.
        if (areAllBashTargetsOutsideSessionScope(targets, sessionRoots) &&
            (repoRoot || areAllBashTargetsUnderPlansDir(targets))) done();

        // Bug 1: all targets covered by EXCLUDE → allow.
        if (excludePatterns.length > 0 &&
            isWriteTargetAllExcluded(cmd, targets, repoRoot, excludePatterns)) {
          done();
        }
      } else if (excludePatterns.length > 0 &&
                 isEverySegmentExcluded(cmd, repoRoot, excludePatterns)) {
        // #739: sequenced commands where every write segment's targets are all
        // covered by EXCLUDE → allow (e.g. `mkdir -p .worktree-backup/x && cp src .worktree-backup/x/f`).
        done();
      }
    }

    // git -C <path> style (no file targets extracted): use repoRoot for scope check.
    if (!targets && !parseFailure && repoRoot) {
      if (!isInSessionScope(repoRoot, sessionRoots)) done();
    }
    if (parseFailure && hasWorktreeEndSkillPrefix(cmd) && /^cp\s/.test(stripWorktreeEndSkillPrefix(cmd)) && /\.worktree-backup/.test(cmd)) done();
    // parseFailure → fail-closed: fall through to main-checkout block below.
  }
} else if (["Edit", "Write", "MultiEdit"].includes(toolName)) {
  const sessionRoots = getSessionRepoRoots();
  const excludePatterns = getExcludePatterns();

  if (toolName === "MultiEdit" && Array.isArray(toolInput.edits) && toolInput.edits.length > 0) {
    // Check every edit target — a mixed-repo MultiEdit must not slip through.
    for (const edit of toolInput.edits) {
      const fp = edit.file_path;
      if (!fp || typeof fp !== "string") continue;

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
        _reportContext.extras = buildExtras(undefined, _toolCwd, root, isMC);
        done({
          block: true,
          reason: `ENFORCE_WORKTREE: write blocked. Reason: main worktree (${branchDesc}).\nWork from a linked worktree (/worktree-start) or set ENFORCE_WORKTREE=off.`,
        });
      }
      if (branch && protected_.includes(branch)) {
        _reportContext.extras = buildExtras(undefined, _toolCwd, root, isMC);
        done({
          block: true,
          reason: `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${branch}' in linked worktree.\nSwitch to a feature branch or set ENFORCE_WORKTREE=off.`,
        });
      }
    }
    done(); // all edits passed
  }
  const filePath = toolInput.file_path || toolInput.path;
  if (!filePath || typeof filePath !== "string") done();

  // Bug 1: EXCLUDE match → allow.
  if (isExcluded(filePath, excludePatterns)) done();

  repoRoot = findRepoRoot(filePath);

  // Bug 2: non-git path or outside session scope → allow.
  if (!repoRoot || !isInSessionScope(repoRoot, sessionRoots)) done();
} else {
  done(); // unrecognised tool — allow
}

// Change ④ (#672): Bash → fail-closed (deny); Edit/Write/MultiEdit → fail-open (allow).
// Bash writes from a non-git CWD are anomalous when sequencing/parseFailure prevents
// target extraction. Edit/Write/MultiEdit still target $HOME/.workflow-plans/ staging
// paths, which must remain allowed (the earlier isInSessionScope guard at line ~1266
// already handles tool inputs).
if (!repoRoot) {
  if (toolName === "Bash") {
    // Axis A (#885): repoRoot was probed and absent → null sentinel for the
    // extras builder (vs. undefined which means "inspection didn't run").
    _reportContext.extras = buildExtras(toolInput.command || undefined, _toolCwd, null, undefined);
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: Bash write blocked. Reason: cannot determine repo root\n" +
        "(non-git CWD or parseFailure). If this is a legitimate non-repo write,\n" +
        "use Edit/Write tools or set ENFORCE_WORKTREE=off.",
    });
  }
  done(); // Edit/Write/MultiEdit: fail-open maintained (staging dir writes)
}

const mainCheckout = isMainCheckout(repoRoot);
const currentBranch = getCurrentBranch(repoRoot);
const protectedBranches = getProtectedBranches(repoRoot);

// Axis A (#885): trivalue isMainCheckout — null (indeterminate) routes
// to the block side, not allow. Only an explicit `false` (linked worktree
// confirmed) permits the detached-HEAD allow path here.
if (!currentBranch && mainCheckout === false) done();

if (mainCheckout !== false) {
  // Allow isolated worktree lifecycle commands (Bash only).
  // These operate on .git/worktrees/ metadata or external paths, not tracked files,
  // and must be invoked from the main worktree.
  if (toolName === "Bash") {
    const cmd = toolInput.command || "";
    if (isAllowedWorktreeCommand(cmd, repoRoot)) done();
    if (isAllowedFastForwardMerge(cmd)) done();
    if (isAllowedReadOnlyConfigCheck(cmd)) done();
    if (isAllowedPushAllExcluded(cmd, repoRoot, getExcludePatterns())) done();
    if (isAllowedMidOperationAbort(cmd, repoRoot)) done();
    if (isAllowedMainWorktreeCleanup(cmd, repoRoot)) done();
    if (isAllowedComposeDocAppend(cmd, repoRoot)) done();
  }

  const branchDesc = currentBranch ? `branch '${currentBranch}'` : "detached HEAD";
  _reportContext.extras = buildExtras(toolInput.command || undefined, _toolCwd, repoRoot, mainCheckout);
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: main worktree (${branchDesc}).\n` +
      "Main worktree is reserved for merge/pull only. Work from a linked worktree.\n" +
      "Run: /worktree-start <task-name>\n" +
      "Or set ENFORCE_WORKTREE=off in agents config to allow direct main work.",
  });
}

if (currentBranch && protectedBranches.includes(currentBranch)) {
  _reportContext.extras = buildExtras(toolInput.command || undefined, _toolCwd, repoRoot, mainCheckout);
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${currentBranch}' in linked worktree.\n` +
      "Switch to a feature branch before writing.\n" +
      "Run: git switch -c feature/<task-name>\n" +
      "Or set ENFORCE_WORKTREE=off in agents config.",
  });
}

done(); // linked worktree on feature branch — allow

} // end if (require.main === module)

module.exports = {
  isAllowedFastForwardMerge,
  isBranchDeleteCommand,
  parseBranchDeleteTarget,
  isAllowedBranchDeleteWhenNotCheckedOut,
  isAllowedReadOnlyConfigCheck,
  getWorktreeBaseDirResolved,
  isAllowedPushAllExcluded,
  hasGitHooksBypass,
  findFirstUnquotedAnd,
  isAllowedMainWorktreeCleanup,
  findRepoRootForBash,
  getSessionRepoRoots,
  parseGitCPath,
  setPayloadDerivedPaths,
  _getPayloadDerivedPaths,
};
