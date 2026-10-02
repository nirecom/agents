#!/usr/bin/env node
// Claude Code PreToolUse hook: block raw `gh issue close` invocations through
// the Bash tool. Forces routing via /issue-close-finalize (Phase 2), which
// calls bin/github-issues/close-completed.sh (subprocess of bash — invisible
// to this hook). Phase 1 (/issue-close-stage) does not call `gh issue close`
// and therefore is not affected by this hook.
//
// Scope: Claude Code Bash tool only. Web UI, mobile, gh from another shell —
// all bypass this hook. Use /issue-reconcile to recover from those.

const fs = require("fs");
const { hasCommandHead } = require("./lib/command-head");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "enforce-issue-close";

const r = readHookInput();
if (r.kind === "read-error") {
  process.stderr.write(readFailureReason(HOOK_NAME, r.error) + "\n");
  process.exit(2);
}
if (r.kind === "json-invalid") {
  try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
  process.exit(0);
}

const parsed = r.input;
if (!parsed || parsed.tool_name !== "Bash") {
  process.exit(0);
}

// Session-scoped overrides: bypass gh issue close guard for this session.
{
  const sid = parsed.session_id;
  const { isWorkflowOff, isIssueCloseVerified } = require("./lib/session-markers");
  if (isWorkflowOff(sid)) { process.exit(0); }
  if (isIssueCloseVerified(sid)) { process.exit(0); }
}

const cmd = (parsed.tool_input && parsed.tool_input.command) || "";

const isGhIssueClose = (tokens) =>
  tokens[0] === "gh" && tokens[1] === "issue" && tokens[2] === "close";
if (!hasCommandHead(cmd, isGhIssueClose)) {
  process.exit(0);
}

// Skill bypass.
if (process.env.ISSUE_CLOSE_SKILL === "1") {
  process.exit(0);
}

const isNotPlanned = cmd.includes("--reason not_planned") ||
  cmd.includes('--reason "not planned"') ||
  cmd.includes("--reason not planned");
process.stderr.write(
  isNotPlanned
    ? "Direct `gh issue close` is not allowed. Use /issue-close-migrated <N> --type migrated|cancelled instead.\n"
    : "Direct `gh issue close` is not allowed. Use /issue-close-finalize <N> instead.\n" +
      "(If Phase 1 is not yet done, first run /issue-close-stage <N> from a linked worktree.\n" +
      " /issue-close-finalize then performs a transaction-safe close and posts the resolved-by sentinel.)\n"
);
try {
  const { reportBlock } = require("./lib/supervisor-emit");
  reportBlock("enforce-issue-close", cmd, parsed.session_id);
} catch (_) { /* fail-open */ }
process.exit(2);
