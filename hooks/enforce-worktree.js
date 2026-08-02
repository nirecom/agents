#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce worktree-based parallel session workflow.
//
// Blocks every write-capable tool — the edit-write class
// (Edit/Write/MultiEdit/editFiles/NotebookEdit) and the command class
// (Bash/runInTerminal/runCommands), enumerated in hooks/lib/write-tools.js — when:
//   1. Running in the main git checkout (not a linked worktree), regardless of branch.
//   2. Running on a protected branch even inside a linked worktree.
// Allows writes only from a linked worktree on a non-protected branch.
// Implementation is split across sibling modules under hooks/enforce-worktree/
// (config / git-repo-detection / session-scope / git-hooks-bypass / shared-cmd-utils
// / branch-delete-guard / main-worktree-allows / bash-write-scope / block-extras).
// This file holds the dispatch block plus small helpers (readStdin / done /
// getWorktreeBaseDirResolved). docs(history|changelog) writes use the GitHub REST
// API and bypass local file/git writes (Contents API + Git Data API under bin/lib/).
// Limitation: Bash write detection is pattern-based (UX guard, not a security
// boundary) — use ENFORCE_WORKTREE=off to bypass for trivial direct-main work.

"use strict";

const fs = require("fs");
const path = require("path");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { resolveSessionId } = require("./workflow-state");
const { stripQuotedArgs } = require("./lib/strip-quoted-args");
const { detectWritePredicate } = require("./enforce-worktree/write-detector");
const { parse } = require("./lib/command-ir");
const { parseCdCommand } = require("./lib/parse-git-args");
const { isEnforceWorktreeOn, getProtectedBranches, getCurrentBranch, isCommandRepoExcluded } = require("./enforce-worktree/config");
const { isMainCheckout, parseGitCPath, findRepoRootForBash, normalizeForCompare, findRepoRoot } = require("./enforce-worktree/git-repo-detection");
const { setPayloadDerivedPaths, _getPayloadDerivedPaths, getSessionRepoRoots } = require("./enforce-worktree/session-scope");
const { hasGitHooksBypass } = require("./enforce-worktree/git-hooks-bypass");
const { findFirstUnquotedAnd, hasCommandSequencing, hasCommandSequencingOutsideHeredoc, isExcluded, getExcludePatterns, hasWorktreeEndSkillPrefix, stripWorktreeEndSkillPrefix } = require("./enforce-worktree/shared-cmd-utils");
const { isBranchDeleteCommand, parseBranchDeleteTarget, isAllowedBranchDeleteWhenNotCheckedOut } = require("./enforce-worktree/branch-delete-guard");
const { isAllowedWorktreeCommand, isAllowedFastForwardMerge, isAllowedReadOnlyConfigCheck, isAllowedPushAllExcluded, isAllowedMidOperationAbort, isAllowedMainWorktreeCleanup, isAllowedComposeDocAppend, isAllowedWorkerScriptInvocation, isAllowedSupervisorBinTool, isAllowedClarifyGuardLoop, isAllowedReadOnlyWorkflowCli } = require("./enforce-worktree/main-worktree-allows");
const { isInSessionScope, collectBashWriteTargets, areAllBashTargetsOutsideSessionScope, areAllWriteSegmentsUnderWorkflowDir, areAllBashTargetsUnderPlansDir, areAllBashTargetsUnderClaude, areAllBashTargetsUnderWorkflowDir, isWriteTargetAllExcluded, isEverySegmentExcluded, isGhWriteCommand, bashTargetsHitProtectedMarker } = require("./enforce-worktree/bash-write-scope");
const { checkUniversalTargetAllow } = require("./enforce-worktree/universal-target-allow");
const { buildWorktreeRemedy } = require("./enforce-worktree/worktree-remedy");
const { buildExtras } = require("./enforce-worktree/report-extras");
const { handleBashWrite } = require("./enforce-worktree/handle-bash-write");
const { handleEditWrite } = require("./enforce-worktree/handle-edit-write");
// H-2 (#1780 round-4): the guarded tool surface is a CLASS, not the four names
// this hook happened to be written against. editFiles / NotebookEdit are
// edit-write siblings and runInTerminal / runCommands are command siblings;
// every one of them bypassed main-worktree and protected-branch enforcement
// entirely. hooks/lib/write-tools.js is the SSOT for both classes and for the
// settings.json matcher string (CPR-2/CPR-5).
const { isEditWriteTool, isCommandTool, collectEditWritePaths, commandTextOf } = require("./lib/write-tools");

// readStdin / getWorktreeBaseDirResolved moved to enforce-worktree/entry-helpers.js
// (file-split, rules/coding/file-split.md). getWorktreeBaseDirResolved stays re-exported below.
const { readStdin, getWorktreeBaseDirResolved } = require("./enforce-worktree/entry-helpers");

// Captured at hook-input parse time so the `done()` helper can self-report on block.
let _reportContext = { sessionId: undefined, command: undefined, toolName: undefined, extras: undefined };

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

// buildExtras moved to enforce-worktree/report-extras.js (file-split,
// rules/coding/file-split.md) — required above; shared with handle-bash-write.js
// and handle-edit-write.js, which also populate _reportContext.extras.

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

// ENFORCE_WORKTREE_EXCLUDE: if the target repo is explicitly excluded (path-coverage),
// skip enforcement for this write without disabling enforcement globally.
if (isCommandRepoExcluded(input, process.cwd())) done();

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
// The command text is derived through the shared normalizer so a runCommands
// call self-reports what it was actually about to run, not `undefined`.
const _cmdText = isCommandTool(toolName) ? commandTextOf(toolName, toolInput) : "";

_reportContext = {
  sessionId: (input && input.session_id) || undefined,
  command: _cmdText || undefined,
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
  if (isCommandTool(toolName)) {
    const _cArg = parseGitCPath(_cmdText);
    if (_cArg && path.isAbsolute(_cArg)) derived.push(_cArg);
    const _cdArg = parseCdCommand(_cmdText);
    if (_cdArg) derived.push(_cdArg);
  } else if (isEditWriteTool(toolName)) {
    // Every path spelling the class can use, top level and per-`edits[]` entry
    // (shared with block-off-clearance-write via hooks/lib/write-tools.js).
    for (const fp of collectEditWritePaths(toolInput)) {
      if (path.isAbsolute(fp)) derived.push(fp);
    }
  }
  setPayloadDerivedPaths(derived);
}

let repoRoot = null;
let _writeDetector = null;

// Bash-tool and Edit/Write/MultiEdit-tool write-target analysis are each a
// cohesive, self-contained chunk of logic — extracted verbatim into sibling
// modules (file-split, rules/coding/file-split.md). Each helper calls the
// shared `done()` for every allow/block exit (process.exit(0) inside — control
// never returns past those calls), and returns the resolved `repoRoot` (plus
// `writeDetector` for Bash) on natural fall-through, exactly matching what the
// former inline code left in the outer `repoRoot` / `_writeDetector` variables
// for the post-dispatch main-checkout / protected-branch checks below.
if (isCommandTool(toolName)) {
  const result = handleBashWrite({ toolName, toolInput, _toolCwd, done, reportContext: _reportContext });
  repoRoot = result.repoRoot;
  _writeDetector = result.writeDetector;
} else if (isEditWriteTool(toolName)) {
  repoRoot = handleEditWrite({ input, toolName, toolInput, _toolCwd, done, reportContext: _reportContext, resolveSessionId });
} else {
  done(); // unrecognised tool — allow
}

// Change ④ (#672): Bash → fail-closed (deny); Edit/Write/MultiEdit → fail-open (allow).
// Bash writes from a non-git CWD are anomalous when sequencing/parseFailure prevents
// target extraction. Edit/Write/MultiEdit still target $HOME/.workflow-plans/ staging
// paths, which must remain allowed (the earlier isInSessionScope guard at line ~1266
// already handles tool inputs).
if (!repoRoot) {
  if (isCommandTool(toolName)) {
    // Axis A (#885): repoRoot was probed and absent → null sentinel for the
    // extras builder (vs. undefined which means "inspection didn't run").
    _reportContext.extras = buildExtras(_cmdText || undefined, _toolCwd, null, undefined);
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: Bash write blocked. Reason: cannot determine repo root\n" +
        "(non-git CWD or parseFailure). If this is a legitimate non-repo write,\n" +
        "use Edit/Write tools or set ENFORCE_WORKTREE=off." + (_writeDetector ? `\nDetected by: ${_writeDetector.detail} (${_writeDetector.name})` : ""),
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
  if (isCommandTool(toolName)) {
    const cmd = _cmdText;
    if (isAllowedWorktreeCommand(cmd, repoRoot)) done();
    if (isAllowedFastForwardMerge(cmd)) done();
    if (isAllowedReadOnlyConfigCheck(cmd)) done();
    if (isAllowedReadOnlyWorkflowCli(cmd)) done();
    if (isAllowedPushAllExcluded(cmd, repoRoot, getExcludePatterns())) done();
    if (isAllowedMidOperationAbort(cmd, repoRoot)) done();
    if (isAllowedMainWorktreeCleanup(cmd, repoRoot)) done();
    if (isAllowedComposeDocAppend(cmd, repoRoot)) done();
    if (isAllowedWorkerScriptInvocation(cmd, repoRoot)) done();
    if (isAllowedSupervisorBinTool(cmd)) done();
    if (isAllowedClarifyGuardLoop(cmd, repoRoot)) done();
  }

  const branchDesc = currentBranch ? `branch '${currentBranch}'` : "detached HEAD";
  _reportContext.extras = buildExtras(_cmdText || undefined, _toolCwd, repoRoot, mainCheckout);
  const _remedy = buildWorktreeRemedy((input && input.session_id) || resolveSessionId());
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: main worktree (${branchDesc}).\n` +
      "Main worktree is reserved for merge/pull only. Work from a linked worktree.\n" +
      _remedy +
      "Or set ENFORCE_WORKTREE=off in agents config to allow direct main work." + (_writeDetector ? `\nDetected by: ${_writeDetector.detail} (${_writeDetector.name})` : ""),
  });
}

if (currentBranch && protectedBranches.includes(currentBranch)) {
  _reportContext.extras = buildExtras(_cmdText || undefined, _toolCwd, repoRoot, mainCheckout);
  done({
    block: true,
    reason:
      `ENFORCE_WORKTREE: write blocked. Reason: protected branch '${currentBranch}' in linked worktree.\n` +
      "Switch to a feature branch before writing.\n" +
      "Run: git switch -c feature/<task-name>\n" +
      "Or set ENFORCE_WORKTREE=off in agents config." + (_writeDetector ? `\nDetected by: ${_writeDetector.detail} (${_writeDetector.name})` : ""),
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
  isAllowedClarifyGuardLoop,
  isAllowedReadOnlyWorkflowCli,
};
