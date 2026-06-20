#!/usr/bin/env node
// Claude Code PostToolUse hook: intercept workflow markers from skill completions
//
// Supported markers (each marker must be a standalone echo, but multiple markers
// may be chained with ` && ` in a single Bash command — each part is evaluated
// independently):
//   echo "<<WORKFLOW_MARK_STEP_<step>_<status>>>"   — mark a step
//   echo "<<WORKFLOW_RESET_FROM_<step>>>"            — reset state from a step
//   echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"      — record user verification (reason mandatory)
//   echo "<<WORKFLOW_{RESEARCH,OUTLINE,DETAIL,WRITE_TESTS}_NOT_NEEDED: <reason>>"
//
// Bypasses CLAUDE_ENV_FILE propagation issue in Bash subprocesses (Anthropic bug #27987).
//   echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: <reason>>>"  — session-scoped ENFORCE_WORKTREE bypass (reason mandatory)
//   echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: <reason>>>"   — restore enforcement (delete marker; reason mandatory)
//   echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>"  — session-scoped ENFORCE_WORKFLOW bypass (reason mandatory)
//   echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>>"   — restore enforcement (delete marker; reason mandatory)
//
// Dispatch implementation is split across sibling modules under hooks/workflow-mark/:
//   skip-reason / not-needed-handlers / clarify-intent-complete-handler /
//   branching-handler / user-verified-handler / mark-step-handler /
//   enforce-override-handlers / reset-handler.
// This file holds the CLI bootstrap (stdin parse, merge-class push detection,
// `&&` chain split, sentinel-only validation) plus the sequential dispatch loop.

"use strict";

const fs = require("fs");
const { execSync } = require("child_process");
const {
  resolveSessionId,
  markStep,
  setLastPushedSha,
  readState,
} = require("./lib/workflow-state");
const { isMergeToProtectedCommand } = require("./lib/merge-detect");
const { resolveRepoCwd } = require("./lib/path-normalize");
// Sentinel recognition centralized in hooks/lib/sentinel-patterns.js (SSOT).
const { isSentinel } = require("./lib/sentinel-patterns");

const notNeededHandlers = require("./workflow-mark/not-needed-handlers");
const clarifyIntentCompleteHandler = require("./workflow-mark/clarify-intent-complete-handler");
const branchingHandler = require("./workflow-mark/branching-handler");
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

// Only handle Bash tool
if (input.tool_name !== "Bash") done();

const command = ((input.tool_input && input.tool_input.command) || "").trim();

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
const mergeResult = isMergeToProtectedCommand(command);
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
      try { markStep(sessionId, "user_verification", "pending"); }
      catch (e) { msg = `workflow-mark: gh pr merge detected — user_verification reset FAILED: ${e.message}`; }
    }
    done(msg);
  }
  done();
}

// Split on `&&` so multiple sentinel echos chained in one Bash call are all processed.
// All-or-nothing: if any part is NOT a sentinel, reject the whole command.
const commandParts = command
  .split(/\s*&&\s*/)
  .map((s) => s.trim())
  .filter(Boolean);
if (commandParts.length === 0) done();
const allAreSentinels = commandParts.every(isSentinel);
if (!allAreSentinels) done(); // prefix-chained or mixed-content command — reject
const sentinelParts = commandParts;

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

const ctx = {
  sessionId,
  pushMessage: (m) => messages.push(m),
  signalFatal: (m) => { messages.push(m); fatalError = true; },
};

for (const cmd of sentinelParts) {
  // Dispatch order matters: USER_VERIFIED must precede MARK_STEP to prevent
  // bypass via WORKFLOW_MARK_STEP_user_verification.
  if (notNeededHandlers.handle({ ...ctx, cmd })) continue;
  if (clarifyIntentCompleteHandler.handle({ ...ctx, cmd })) continue;
  if (branchingHandler.handle({ ...ctx, cmd })) continue;
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
