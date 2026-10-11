#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce workflow step completion before git commit
// Replaces check-tests-updated.js and check-docs-updated.js

const path = require("path");
const { readHookInput, readFailureReason } = require("./lib/read-stdin");
const {
  SKIPPABLE_STEPS,
  readState,
  getSkippableSteps,
  reconcileEffectiveState,
} = require("./workflow-state");

const { isMergeToProtectedCommand } = require("./lib/merge-detect");
const { isCommitCommand, extractCommitSegmentText } = require("./lib/commit-detect");
const { parse } = require("./lib/command-ir");
// #2256 S5-a1: command-tool normalization + sentinel decomposition shared with
// workflow-mark.js (SSOT: hooks/lib/tool-command-text.js, sentinel-command.js).
const { isCommandTool, commandListOf } = require("./lib/tool-command-text");
const { scannableCommandListOf } = require("./lib/scannable-command-list");
const { analyzeSentinelCommand } = require("./lib/sentinel-command");
const { isBaselineEvidenceRecordCommand } = require("./lib/workflow-driver-commands");

// Which steps the commit gate checks: workflow-gate/commit-gate-steps.js (SSOT: step-table.js).
const { parseGitConfigValues } = require("./lib/parse-git-args");
const { resolveInputCwd } = require("./lib/resolve-cwd");

const { normalizeForWindows } = require("./workflow-gate/path-normalize");
const {
  hasStagedTestChanges,
  isDocsOnlyStaged,
  resolveExternalDocsRepo,
  hasStagedDocChanges,
  hasStagedChanges,
  hasUnstagedTrackedChanges,
} = require("./workflow-gate/staged-evidence");
const { hasOpenPrForBranch, isBranchDirectlyMerged, isRemoteDefaultBranchAbsent } = require("./workflow-gate/gh-detect");
const {
  isWorktreeContext,
  isLinkedWorktree,
  hasWorktreeNotesDocEvidence,
} = require("./workflow-gate/worktree-context");
const {
  findAdditionalDirectories,
  resolveRepoDir,
  isAgentsSessionRepo,
} = require("./workflow-gate/repo-resolution");

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason, extras = undefined) {
  try {
    const { reportBlock } = require("./lib/supervisor-emit");
    // Axis A (#885): if no explicit extras passed but the parsed context has
    // a cwd we recorded, use it as a minimum extras payload so the supervisor
    // state finding always carries context.cwd (and git_root_resolved when
    // repoDir has been resolved).
    let effExtras = extras;
    if (effExtras === undefined) {
      if (_gateReportCtx.cwd !== undefined) {
        const ctx = { cwd: _gateReportCtx.cwd };
        if (_gateReportCtx.repoResolved !== undefined) {
          ctx.git_root_resolved = !!_gateReportCtx.repoResolved;
        }
        effExtras = { context: ctx };
      } else {
        effExtras = {};
      }
    }
    reportBlock("workflow-gate", _gateReportCtx.command || _gateReportCtx.toolName || "<unknown>", _gateReportCtx.sessionId, effExtras);
  } catch (_) { /* fail-open */ }
  try {
    const { recordGateBlock } = require("./workflow-gate/handoff-record");
    recordGateBlock(_gateReportCtx.sessionId, reason, { command: _gateReportCtx.command });
  } catch (_) { /* fail-open: a lost breadcrumb must never change the verdict */ }
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Populated at hook-input parse time so block() can self-report.
let _gateReportCtx = { sessionId: undefined, command: undefined, toolName: undefined, cwd: undefined };

// Block without emitting a supervisor L1 finding (used for supervisor pre-merge
// gates, to avoid recursing the pre-merge audit). It still leaves the #2218
// handoff breadcrumb — a block is a block and must survive a compaction; only the
// supervisor L1 finding is intentionally omitted here.
function blockWithoutError(reason) {
  try {
    const { recordGateBlock } = require("./workflow-gate/handoff-record");
    recordGateBlock(_gateReportCtx.sessionId, reason, { command: _gateReportCtx.command });
  } catch (_) { /* fail-open: a lost breadcrumb must never change the verdict */ }
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Supervisor pre-merge gate (warning-flush / audit-verdict / scope-drift):
// hooks/workflow-gate/supervisor-check.js. blockWithoutError is injected at the
// call site so the module stays free of this hook's stdout protocol.
const {
  checkSupervisorPreMerge,
  parseDetailFilesToModify,
} = require("./workflow-gate/supervisor-check");
const { checkUserVerifiedAudit } = require("./workflow-gate/user-verified-audit");
const { runEarlyGate } = require("./workflow-gate/early-gate");

if (require.main === module) {
  const r = readHookInput();
  if (r.kind === "read-error") block(readFailureReason("workflow-gate", r.error));
  const input = r.input;
  if (r.kind === "json-invalid" || !input || typeof input !== "object") {
    block("workflow-gate: failed to parse hook input — commit blocked (fail-safe).");
  }

  const toolName = input.tool_name;
  const toolInput = input.tool_input || {};
  const sessionId = input.session_id;
  _gateReportCtx = {
    sessionId,
    command: toolInput.command,
    toolName,
    cwd: typeof toolInput.cwd === "string" ? toolInput.cwd : undefined,
    repoResolved: undefined,
  };

  // WORKFLOW_OFF: bypass all workflow-gate checks (superset of WORKTREE_OFF per workflow-off.md).
  const { isWorkflowOff, isWorktreeOff } = require("./lib/session-markers");
  if (isWorkflowOff(sessionId)) approve();

  // EARLY GATE: 3-tier enforcement before Edit/Write tools (workflow_init /
  // clarify_intent / worktree-entry). Owned by workflow-gate/early-gate.js;
  // block() is injected so the module stays free of this hook stdout protocol.
  runEarlyGate(input, { block });

  if (!isCommandTool(toolName)) approve();

  // Joined blob for merge/commit detection and repoDir resolution; per-element
  // sentinel decomposition uses analyzeSentinelCommand (SSOT: sentinel-command.js).
  const command = scannableCommandListOf(toolName, toolInput).join("\n");
  if (!command) approve();

  // Internal-only door (#2431): owner and rationale in lib/workflow-driver-commands.js.
  if (commandListOf(toolName, toolInput).some(isBaselineEvidenceRecordCommand)) {
    block("workflow-gate: `run-tests-baseline-evidence record` is internal to bin/run-tests-baseline — run bin/run-tests-baseline instead.");
  }

  // SENTINEL GUARD (#382): block exactly what workflow-mark.js (PostToolUse) would
  // silently drop. analyzeSentinelCommand decomposes the call identically for both
  // layers — Bash/runInTerminal `&&` chains stay order-independent all-or-nothing,
  // and the runCommands array also rejects a non-sentinel element after a sentinel.
  const sentinelAnalysis = analyzeSentinelCommand(toolName, toolInput);

  // #2319: single resolved CWD for freshness computation, shared by BOTH the
  // USER_VERIFIED audit gate (inside the uvHit block) and the pre-merge backstop
  // (outside it), so it must live in the outer scope. Distinct from rawSentinelCwd,
  // which stays raw-null for the premature guard. resolveInputCwd is the SSOT.
  const freshnessCwd = normalizeForWindows(resolveInputCwd(toolInput.cwd));

  if (sentinelAnalysis.sentinelPresent) {
    if (!sentinelAnalysis.clean) {
      block(
        "workflow-gate: sentinel command chained with non-sentinel via `&&` is blocked.\n" +
        "Sentinel echoes must be standalone Bash calls (or chained only with other sentinels).\n" +
        "Without this guard, workflow-mark.js (PostToolUse) splits on `&&` and applies\n" +
        "all-or-nothing dispatch (issue #110): when even one part is not a recognized\n" +
        "sentinel, ALL state updates are silently dropped. This includes the case where\n" +
        "a sentinel's reason text itself contains `&&` (the naive splitter fragments it).\n\n" +
        "Fix: split into separate Bash calls. Example:\n" +
        '  call 1: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: docs-only change>>"\n' +
        "  call 2: <the other command>"
      );
    }

    // A clean sentinel emission carrying <<WORKFLOW_USER_VERIFIED>>.
    if (sentinelAnalysis.uvHit) {
      // PREMATURE USER_VERIFIED GUARD (#577, #2527 3-5): in a worktree with
      // ENFORCE_WORKTREE=on, block emission until an OPEN/MERGED PR exists. Bootstrap
      // (remote default branch absent) is exempt: no PR can exist yet. No Bash cwd -> fail-open.
      const rawSentinelCwd = typeof toolInput.cwd === "string" ? toolInput.cwd : null;
      const sentinelDir = rawSentinelCwd ? normalizeForWindows(rawSentinelCwd) : null;
      if (
        sentinelDir &&
        process.env.ENFORCE_WORKTREE !== "off" &&
        isWorktreeContext(sentinelDir) &&
        !hasOpenPrForBranch(sentinelDir) &&
        !isBranchDirectlyMerged(sentinelDir)
      ) {
        if (isRemoteDefaultBranchAbsent(sentinelDir)) {
          process.stderr.write("[workflow-gate] origin has no default-branch head; premature-UV exemption applied\n");
        } else {
          block(
            "workflow-gate: premature <<WORKFLOW_USER_VERIFIED>> emission blocked.\n\n" +
            "Under ENFORCE_WORKTREE=on, this sentinel is emitted by /get-release-approval,\n" +
            "after /commit-push has pushed the branch and opened its PR.\n\n" +
            "Defer: run /commit-push, then /get-release-approval emits the sentinel at the correct point.\n" +
            "Emergency bypass: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>\"\n" +
            "See issues #577, #2527."
          );
        }
      }

      // Block if a merge command co-appears in this runCommands: the merge gate
      // (below) never runs once approve() exits, bypassing the freshness backstop
      // (#2256 C33 leading-merge bypass).
      const hasMergeInCall = commandListOf(toolName, toolInput)
        .some((el) => isMergeToProtectedCommand(el).hit);
      if (hasMergeInCall) {
        block(
          "workflow-gate: a merge command in the same runCommands as <<WORKFLOW_USER_VERIFIED>> is blocked.\n" +
          "Emit the sentinel in a separate Bash call before the merge."
        );
      }

      // #2256 S5-b/c: TR5 user_verification audit gate — authoritative when
      // supervisor state resolves (arms/holds via blockWithoutError, or approves),
      // else a no-op.
      checkUserVerifiedAudit(sessionId, freshnessCwd, { approveFn: approve, blockFn: blockWithoutError });
    }
  }

  // MERGE GATE: hard-block gh pr merge / git push to protected branches when
  // user_verification is not complete. Runs unconditionally regardless of
  // ENFORCE_WORKTREE — protected branches are protected in all modes.
  // Scan every command-tool element: a merge in any runCommands element (even
  // after a non-merge lead) must be gated (SSOT: tool-command-text.js).
  const mergeHit =
    commandListOf(toolName, toolInput)
      .map((el) => isMergeToProtectedCommand(el))
      .find((h) => h.hit) || { hit: false };
  if (mergeHit.hit) {
    // #2256 S5-e: the supervisor freshness backstop is authoritative whenever
    // supervisor state resolves — it approves a fresh non-BLOCK TR5 run and
    // denies (via blockWithoutError, which exits) otherwise. Only when no
    // supervisor state exists does it return non-authoritative and we fall
    // through to the legacy workflow user_verification merge gate.
    const backstop = checkSupervisorPreMerge(sessionId, mergeHit.kind, freshnessCwd, {
      blockFn: blockWithoutError,
      resolveRepoDirFn: resolveRepoDir,
    });
    if (backstop && backstop.authoritative) approve();

    // Legacy user_verification merge gate (only reached when no supervisor state
    // exists). It denies via blockWithoutError: a routine "not verified yet" merge
    // block is a workflow gate, not a supervisor anomaly, so it must NOT emit a
    // supervisor L1 finding — doing so would seed a findings-only supervisor state
    // that hijacks the freshness backstop on the very next merge attempt (path
    // flip). The #2218 handoff breadcrumb is still recorded by blockWithoutError.
    if (!sessionId) {
      blockWithoutError(
        "workflow-gate: merge to protected branch blocked — session_id missing.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" first (reason: >=3 non-space chars, no \'>\', not a placeholder).'
      );
    }
    const mergeState = readState(sessionId);
    if (!mergeState) {
      blockWithoutError(
        "workflow-gate: merge to protected branch blocked — no workflow state.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" first (reason: >=3 non-space chars, no \'>\', not a placeholder).'
      );
    }
    const uv = mergeState.steps && mergeState.steps.user_verification;
    const uvStatus = uv ? uv.status : "missing";
    if (uvStatus !== "complete") {
      blockWithoutError(
        `workflow-gate: ${mergeHit.kind} blocked — user_verification is "${uvStatus}".\n\n` +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>"\n' +
        '(reason: >=3 non-space chars, no \'>\', not a placeholder; ' +
        'set Bash description: "User verification: approve if implementation is complete — approving unlocks the merge gate.")'
      );
    }
    approve();
  }

  // #2393: IR + shared wrapper model, so `rtk git commit` / chained commits reach the gate.
  const commandIr = parse(command);
  if (!isCommitCommand(commandIr)) approve();

  const repoDir = resolveRepoDir(command, input);
  // Axis A (#885): record git_root_resolved for late-block extras.
  _gateReportCtx.repoResolved = !!repoDir;

  // Cross-repo bypass (#1138): skip agents workflow-state enforcement when the
  // commit targets a repo that is NOT the agents session repo. Fail-closed:
  // isAgentsSessionRepo() returns true on error, keeping enforcement in place.
  if (!isAgentsSessionRepo(repoDir)) approve();

  const docsOnly = isDocsOnlyStaged(repoDir);
  // WIP signal: `git -c workflow.wip=1 commit ...` skips ONLY user_verification.
  // run_tests, review_security, docs still fire. See docs/architecture/claude-code/workflow.md.
  const wipValues = parseGitConfigValues(extractCommitSegmentText(commandIr), "workflow.wip");
  const isWip = wipValues.some((v) => v === "1" || v.toLowerCase() === "true");

  // Gate 1 (issue #269): hard-block commits when tracked files have unstaged
  // working-tree changes. Docs-only short-circuit does NOT skip this — docs-only
  // staged + unstaged code is still a staging integrity violation (PR #767).
  // Skipped on isWip OR WORKTREE_OFF (recovery sessions bypass Gate 1 only;
  // WORKFLOW_OFF bypasses all gates via the early-return above).
  if (!isWip && !isWorktreeOff(sessionId)) {
    const unstagedResult = hasUnstagedTrackedChanges(repoDir);
    // Gate 1 fail-open on error (helper wrote stderr); CLI side is fail-safe.
    if (unstagedResult.error === null && unstagedResult.hasChanges) {
      const fileList = unstagedResult.files.map((f) => `  ${f}`).join("\n");
      block(
        [
          "workflow-gate: tracked-file modifications were not staged before commit.",
          `${unstagedResult.files.length} file(s) modified but not staged:`,
          fileList,
          "",
          "This usually means `git add` was skipped during the commit-push flow (see PR #767).",
          "",
          "Resolve by either:",
          "  - Stage the files: git add <file>",
          "  - Stash them: git stash push -u -- <file>",
          "  - Mark as WIP: git -c workflow.wip=1 commit -m \"...\"",
          "",
          "Emergency bypass (session-scoped): echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>>\"",
        ].join("\n")
      );
    }
  }

  // Gate 3 (issue #1642): prompt extraction — §1.5 code fences and §1.3 inline
  // procedures in staged prompt files. bin/check-prompt-extraction --staged owns
  // detection and the allowlist ratchet (CPR-SSOT); this call site maps exit 1 -> block.
  //
  // Ordered BEFORE Gate 2 deliberately: Gate 3 self-limits to repos that carry a
  // .prompt-extraction-allowlist, so it stays silent everywhere it does not apply,
  // whereas Gate 2 applies repo-wide. Running the narrower gate first means an
  // infrastructure failure is reported by the gate that actually owns the repo.
  {
    const { checkPromptExtraction } = require("./workflow-gate/prompt-extraction-gate");
    const extractionVerdict = checkPromptExtraction(repoDir);
    if (extractionVerdict.action === "block") block(extractionVerdict.reason);
  }

  // Gate 2 (issue #1701): HARD file-size limit. bin/review-code-size --staged owns the
  // thresholds and line counting (CPR-SSOT); this call site only maps exit 1 -> block.
  {
    const { checkCodeSizeHardLimit } = require("./workflow-gate/code-size-gate");
    const sizeVerdict = checkCodeSizeHardLimit(repoDir);
    if (sizeVerdict.action === "block") block(sizeVerdict.reason);
  }

  // session_id is required — fail-safe if missing
  if (!sessionId) {
    block(
      "workflow-gate: session_id not found in hook input.\n" +
        "Cannot verify workflow state. Commit blocked (fail-safe).\n" +
        "To reset workflow state, run:\n" +
        '  echo "<<WORKFLOW_RESET_FROM_research: {reason}>>"'
    );
  }

  const state = readState(sessionId);

  if (!state) {
    block(
      `workflow-gate: no workflow state found for session ${sessionId}.\n` +
        "Commit blocked (fail-safe). To initialize workflow state, run:\n" +
        '  echo "<<WORKFLOW_RESET_FROM_research: {reason}>>"'
    );
  }

  // Derived view for the commit gate (#1681). resolveAll:true — every gated step
  // must be judged, not just those up to the current one. evidencePolicy
  // "staged-only" reproduces the gate's historical write_tests rule (staged
  // tests/ only; the post-merge committed-tests fallback must not satisfy a
  // commit-time gate). A veto-de-skipped or post-veto-reset step reads as
  // `pending` here and therefore blocks the commit.
  // Fail-open: on snapshot failure fall back to the raw record.
  let commitSnapshot = null;
  try {
    const { resolveSessionProfile } = require("./workflow-state/session-profile");
    commitSnapshot = reconcileEffectiveState(state, sessionId, {
      repoDir,
      profile: resolveSessionProfile(state, sessionId, { repoDir }),
      resolveAll: true,
      evidencePolicy: "staged-only",
    });
  } catch (e) { commitSnapshot = null; }

  // Step scan (#2527 3-4): commitGateOf() decides exempt / deferred-in-worktree /
  // required per step. BUGFIX sessions exclude write_tests/review_tests (#1147).
  const { collectIncompleteSteps } = require("./workflow-gate/commit-gate-steps");
  const { incomplete, incompleteReasons } = collectIncompleteSteps({
    state, commitSnapshot, sessionId, repoDir, docsOnly, isWip,
    skippable: getSkippableSteps(sessionId),
  });

  if (incomplete.length === 0) approve();

  const { buildIncompleteStepsMessage } = require("./workflow-gate/incomplete-steps-message");
  block(buildIncompleteStepsMessage(incomplete, incompleteReasons, docsOnly));
}

module.exports = { resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges, hasWorktreeNotesDocEvidence, isWorktreeContext, isDocsOnlyStaged, resolveExternalDocsRepo, hasStagedChanges, hasUnstagedTrackedChanges, findAdditionalDirectories, parseDetailFilesToModify, checkSupervisorPreMerge };
