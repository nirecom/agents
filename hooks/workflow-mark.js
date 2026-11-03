#!/usr/bin/env node
// Claude Code PostToolUse hook: intercept workflow markers from skill completions.
// Markers are standalone `echo "<<WORKFLOW_...>>"` sentinels; multiple may be chained
// with ` && ` (each part evaluated independently). Families: MARK_STEP, RESET_FROM,
// USER_VERIFIED, {RESEARCH,OUTLINE,DETAIL,WRITE_TESTS}_NOT_NEEDED, and
// ENFORCE_{WORKTREE,WORKFLOW}_{OFF,ON} (session-scoped bypass; reasons mandatory;
// reads session_id from hook stdin, not from the Bash env). Dispatch is split across
// hooks/workflow-mark/ sibling modules; this file holds the CLI bootstrap (stdin
// parse, merge-class push detection, sentinel decomposition) + the dispatch loop.

"use strict";

const fs = require("fs");
const { execSync } = require("child_process");
const {
  resolveSessionId,
  setLastPushedSha,
  readState,
} = require("./workflow-state");
const { isMergeToProtectedCommand } = require("./lib/merge-detect");
const { resetUserVerificationForDelivery } = require("./workflow-mark/delivery-boundary-reset");
const { resolveRepoCwd } = require("./lib/path-normalize");
// #2256 S5-a1: command-tool normalization + sentinel decomposition shared with
// workflow-gate.js (SSOT: hooks/lib/tool-command-text.js, sentinel-command.js).
const { isCommandTool, commandTextOf, commandListOf } = require("./lib/tool-command-text");
const { analyzeSentinelCommand } = require("./lib/sentinel-command");
const { isSubagentCall } = require("./lib/subagent-detect");

const notNeededHandlers = require("./workflow-mark/not-needed-handlers");
const clarifyIntentCompleteHandler = require("./workflow-mark/clarify-intent-complete-handler");
const branchingHandler = require("./workflow-mark/branching-handler");
const confirmApprovalHandler = require("./workflow-mark/confirm-approval-handler");
const userVerifiedHandler = require("./workflow-mark/user-verified-handler");
const markStepHandler = require("./workflow-mark/mark-step-handler");
const reviewTestsHandler = require("./workflow-mark/review-tests-handler");
const runTestsAcceptHandler = require("./workflow-mark/run-tests-accept-handler");
const glossaryAcceptHandler = require("./workflow-mark/glossary-accept-handler");
const enforceOverrideHandlers = require("./workflow-mark/enforce-override-handlers");
const supervisorBlockOverrideHandler = require("./workflow-mark/supervisor-block-override-handler");
const resetHandler = require("./workflow-mark/reset-handler");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");
const { createSink, flush } = require("./workflow-mark/emit");
const { recordReceipt, recordOutcome } = require("./lib/sentinel-receipt");

// Every message carries its severity (emit.js): INFO on the normal channel, UNAPPLIED on the strong one.
const sink = createSink();
const { pushMessage, pushUnapplied } = sink;
const done = () => flush(sink.messages);

const HANDLERS = [
  // Dispatch order matters: USER_VERIFIED must precede MARK_STEP to prevent
  // bypass via WORKFLOW_MARK_STEP_user_verification.
  notNeededHandlers, clarifyIntentCompleteHandler, branchingHandler,
  // CONFIRM_INTENT / _OUTLINE / _DETAIL record the plan approval that the
  // completion-boundary invariant requires; must precede mark-step-handler so a
  // chained "CONFIRM && MARK_STEP" records the approval before the completion.
  confirmApprovalHandler, userVerifiedHandler,
  // review-tests-handler must run BEFORE mark-step-handler so the dedicated
  // REVIEW_TESTS_COMPLETE / REVIEW_TESTS_WARNINGS sentinels reach their owner.
  reviewTestsHandler, runTestsAcceptHandler, glossaryAcceptHandler, markStepHandler,
  enforceOverrideHandlers, supervisorBlockOverrideHandler, resetHandler,
];

if (require.main === module) {

const hookInput = readHookInput();
if (hookInput.kind !== "ok") {
  try {
    fs.writeSync(2, readFailOpenDiagnostic("workflow-mark", hookInput, "step mark not recorded") + "\n");
  } catch (e) {}
  done();
}
const input = hookInput.input;

// Only handle command tools (Bash / runInTerminal / runCommands).
if (!isCommandTool(input.tool_name)) done();

// Joined blob for merge/push detection and repoCwd resolution; per-element
// sentinel decomposition happens via analyzeSentinelCommand below.
const command = commandTextOf(input.tool_name, input.tool_input).trim();

// Hoist: needed by push-reset below and by sentinel logic further down.
const toolResponse = input.tool_response || {};
const exitCode =
  toolResponse.exit_code ??
  toolResponse.exitCode ??
  (toolResponse.success === false ? 1 : 0);
const sessionId = resolveSessionId({
  sessionIdFromInput: input.session_id,
  transcriptPath: input.transcript_path,
});

// Decompose into sentinel sub-commands (SSOT: sentinel-command.js). Bash/
// runInTerminal `&&` chains stay order-independent all-or-nothing; the runCommands
// array additionally rejects a non-sentinel element that follows a sentinel.
const analysis = analyzeSentinelCommand(input.tool_name, input.tool_input);
// #2877: the receipt says the sentinel reached this hook; its outcome says the run finished.
// The Stop backstop tells the user about a sentinel with neither.
const toolUseId = input.tool_use_id;
const receipted = analysis.sentinelPresent && !!sessionId && recordReceipt(sessionId, toolUseId, analysis.sentinelParts);
const applied = [];
const unappliedParts = [];
function finish() {
  if (receipted) recordOutcome(sessionId, toolUseId, { applied, unapplied: unappliedParts });
  done();
}
function refuseAll(text) {
  pushUnapplied(text);
  unappliedParts.push(...(analysis.sentinelParts.length > 0 ? analysis.sentinelParts : [command]));
  finish();
}

// Reset user_verification only after a successful merge-class operation
// (push to a protected branch / gh pr merge / glab mr merge). Feature-branch
// pushes leave verification state alone so the upcoming merge gate can pass.
// Scan every command-tool element: a protected push/merge in any runCommands
// element must reset user_verification (SSOT: tool-command-text.js).
const mergeResult =
  commandListOf(input.tool_name, input.tool_input)
    .map((el) => isMergeToProtectedCommand(el))
    .find((h) => h.hit) || { hit: false };
if (mergeResult.hit) {
  let msg;
  if (exitCode === 0 && sessionId) {
    // #2527: idempotent boundary reset (post-push / post-merge) — workflow-mark/delivery-boundary-reset.js.
    msg = resetUserVerificationForDelivery(sessionId, mergeResult.kind);
    if (mergeResult.kind === "git-push-protected") {
      // Record last_pushed_sha for post-push-workflow-reset hook.
      try {
        const state = readState(sessionId);
        const repoCwd = resolveRepoCwd({
          command, input, stateCwd: state && state.cwd,
        });
        const sha = execSync("git rev-parse HEAD", {
          cwd: repoCwd, encoding: "utf8", timeout: 2000,
        }).trim();
        if (/^[0-9a-f]{40}$/.test(sha)) {
          setLastPushedSha(sessionId, sha);
        }
      } catch (e) { /* Fail-open */ }
    }
    // gh / glab merge records no sha: no local push happened in this command.
    if (msg) pushMessage(msg);
  }
  finish();
}

// Backstop: subagent calls must not drive the workflow state machine; a subagent's
// sentinel is refused aloud so the fork returns it instead of believing it applied.
// push/merge detection above still runs for subagents (C1 regression guard).
if (isSubagentCall(input)) {
  if (!analysis.sentinelPresent) done();
  refuseAll(
    "workflow-mark: a sentinel emitted inside a subagent / fork is NOT applied — it only takes effect " +
      "in the main conversation. Return the exact echo line to the main conversation and run it there."
  );
}

if (!analysis.sentinelPresent) done(); // no sentinel content — nothing to record
if (!analysis.clean) {
  refuseAll(
    "workflow-mark: a sentinel mixed with other commands is NOT applied (the whole command is rejected). " +
      'Re-run each sentinel as its own standalone Bash call: echo "<<WORKFLOW_...>>"'
  );
}
const sentinelParts = analysis.sentinelParts;
if (sentinelParts.length === 0) refuseAll("workflow-mark: no sentinel could be extracted from the command — NOT applied.");

if (exitCode !== 0) {
  refuseAll(
    `workflow-mark: echo exited ${exitCode} — ${sentinelParts.length} sentinel operation(s) NOT applied. ` +
      "Re-run the sentinel as one standalone Bash call."
  );
}

const state = readState(sessionId);
const repoCwd = resolveRepoCwd({ command, input, stateCwd: state && state.cwd });

// signalFatal is the pre-#2824 name of pushUnapplied, kept for the handlers not yet renamed.
const ctx = { sessionId, pushMessage, pushUnapplied, signalFatal: pushUnapplied, repoCwd };

const isUnapplied = (m) => m.severity === "unapplied";
for (const cmd of sentinelParts) {
  const before = sink.messages.filter(isUnapplied).length;
  const handler = HANDLERS.find((h) => h.handle({ ...ctx, cmd }));
  if (!handler) pushUnapplied(`workflow-mark: no handler for this sentinel — NOT applied: ${cmd}`);
  (sink.messages.filter(isUnapplied).length > before ? unappliedParts : applied).push(cmd);
}

finish();

} // end if (require.main === module)
