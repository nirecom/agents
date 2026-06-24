#!/usr/bin/env node
// Claude Code PreToolUse hook: block raw `gh issue close` invocations through
// the Bash tool. Forces routing via /issue-close-finalize (Phase 2), which
// sets ISSUE_CLOSE_SKILL=1 to bypass this guard. Phase 1 (/issue-close-stage)
// does not call `gh issue close` and therefore is not affected by this hook.
//
// Scope: Claude Code Bash tool only. Web UI, mobile, gh from another shell —
// all bypass this hook. Use /issue-reconcile to recover from those.

const fs = require("fs");
const { hasCommandHead } = require("./lib/command-head");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (e) {
    // EOF or no stdin attached
  }
  return Buffer.concat(chunks).toString("utf8");
}

const input = readStdin();
if (!input || !input.trim()) {
  // No input — nothing to evaluate. Approve.
  process.exit(0);
}

let parsed;
try {
  parsed = JSON.parse(input);
} catch (e) {
  // Non-JSON / malformed — fail-open. The other PreToolUse hooks will catch
  // legitimately malformed payloads; we don't want to escalate here.
  process.exit(0);
}

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

const isNotPlanned = cmd.includes("--reason not_planned");
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
