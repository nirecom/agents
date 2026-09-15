#!/usr/bin/env node
// Claude Code PostToolUse hook: intercept workflow markers from skill completions.
// Markers are standalone `echo "<<WORKFLOW_...>>"` sentinels; multiple may be chained
// with ` && ` (each part evaluated independently). Families: MARK_STEP, RESET_FROM,
// USER_VERIFIED, {RESEARCH,OUTLINE,DETAIL,WRITE_TESTS}_NOT_NEEDED, and
// ENFORCE_{WORKTREE,WORKFLOW}_{OFF,ON} (session-scoped bypass; reasons mandatory;
// works around CLAUDE_ENV_FILE propagation bug #27987). Dispatch is split across
// hooks/workflow-mark/ sibling modules; this file holds the CLI bootstrap (stdin
// parse, merge-class push detection, sentinel decomposition) + the dispatch loop.

"use strict";

const fs = require("fs");
const { execSync } = require("child_process");
const {
  resolveSessionId,
  markStep,
  setLastPushedSha,
  readState,
} = require("./workflow-state");
const { isMergeToProtectedCommand } = require("./lib/merge-detect");
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
const enforceOverrideHandlers = require("./workflow-mark/enforce-override-handlers");
const resetHandler = require("./workflow-mark/reset-handler");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function done(additionalContext) {
  const out = additionalContext ? { additionalContext } : {};
  console.log(JSON.stringify(out));
  process.exit(0);
}

if (require.main === module) {

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

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

// Reset user_verification only after a successful merge-class operation
// (push to a protected branch / gh pr merge). Feature-branch pushes leave
// verification state alone so the upcoming gh pr merge gate can pass.
// Scan every command-tool element: a protected push/merge in any runCommands
// element must reset user_verification (SSOT: tool-command-text.js).
const mergeResult =
  commandListOf(input.tool_name, input.tool_input)
    .map((el) => isMergeToProtectedCommand(el))
    .find((h) => h.hit) || { hit: false };
if (mergeResult.hit) {
  let msg;
  if (exitCode === 0 && sessionId) {
    if (mergeResult.kind === "git-push-protected") {
      msg = "workflow-mark: protected push detected — user_verification reset to pending.";
      try { markStep(sessionId, "user_verification", "pending"); }
      catch (e) { msg = `workflow-mark: protected push detected — user_verification reset FAILED: ${e.message}`; }
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
    } else {
      // gh pr merge: reset verification but do not record a sha
      // (no local push happened in this command).
      msg = "workflow-mark: gh pr merge detected — user_verification reset to pending.";
      try { markStep(sessionId, "user_verification", "pending", { reset_reason: "post-merge" }); }
      catch (e) { msg = `workflow-mark: gh pr merge detected — user_verification reset FAILED: ${e.message}`; }
    }
    done(msg);
  }
  done();
}

// Backstop: subagent calls must not drive the workflow state machine.
// push/merge detection above still runs for subagents (C1 regression guard).
if (isSubagentCall(input)) done();

// Decompose into sentinel sub-commands (SSOT: sentinel-command.js). Bash/
// runInTerminal `&&` chains stay order-independent all-or-nothing; the runCommands
// array additionally rejects a non-sentinel element that follows a sentinel.
const analysis = analyzeSentinelCommand(input.tool_name, input.tool_input);
if (!analysis.sentinelPresent) done(); // no sentinel content — nothing to record
if (!analysis.clean) done(); // impure chain or trailing non-sentinel — reject whole
const sentinelParts = analysis.sentinelParts;
if (sentinelParts.length === 0) done();

if (exitCode !== 0) {
  done(
    `workflow-mark: echo exited ${exitCode} — ${sentinelParts.length} sentinel operation(s) NOT applied.`
  );
}

// Accumulate per-part messages; emit them together at end.
const messages = [];
// When set, the loop tail flushes messages to stderr and exits with code 2 so
// the harness surfaces the failure instead of silently swallowing it.
let fatalError = false;

const state = readState(sessionId);
const repoCwd = resolveRepoCwd({ command, input, stateCwd: state && state.cwd });

const ctx = {
  sessionId,
  pushMessage: (m) => messages.push(m),
  signalFatal: (m) => { messages.push(m); fatalError = true; },
  repoCwd,
};

for (const cmd of sentinelParts) {
  // Dispatch order matters: USER_VERIFIED must precede MARK_STEP to prevent
  // bypass via WORKFLOW_MARK_STEP_user_verification.
  if (notNeededHandlers.handle({ ...ctx, cmd })) continue;
  if (clarifyIntentCompleteHandler.handle({ ...ctx, cmd })) continue;
  if (branchingHandler.handle({ ...ctx, cmd })) continue;
  // CONFIRM_OUTLINE / CONFIRM_DETAIL record the plan approval that the
  // completion-boundary invariant requires; must precede mark-step-handler so a
  // chained "CONFIRM && MARK_STEP" records the approval before the completion.
  if (confirmApprovalHandler.handle({ ...ctx, cmd })) continue;
  if (userVerifiedHandler.handle({ ...ctx, cmd })) continue;
  // review-tests-handler must run BEFORE mark-step-handler so the dedicated
  // REVIEW_TESTS_COMPLETE / REVIEW_TESTS_WARNINGS sentinels reach their owner
  // (mark-step-handler would otherwise process a manual MARK_STEP form here).
  if (reviewTestsHandler.handle({ ...ctx, cmd })) continue;
  if (markStepHandler.handle({ ...ctx, cmd })) continue;
  if (enforceOverrideHandlers.handle({ ...ctx, cmd })) continue;
  if (resetHandler.handle({ ...ctx, cmd })) continue;
}

if (fatalError) {
  process.stderr.write(messages.join("\n") + "\n");
  process.exit(2);
}
done(messages.length > 0 ? messages.join("\n") : undefined);

} // end if (require.main === module)
