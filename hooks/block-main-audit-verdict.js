#!/usr/bin/env node
// PreToolUse hook (#2853): an audit verdict is written only by the supervisor-audit subagent.
// The main conversation (no non-empty-string agent_id) is blocked from bin/supervisor-write-audit-verdict
// and from bin/supervisor-write-audit --set-audit-verdict, so it cannot settle its own plan's audit.
// Its exit is the ask-gated WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel (ARP-EXBG).
// Unreadable stdin and broken JSON block (fail-closed); other tools and other commands pass.

"use strict";

const { readHookInput, readFailureReason } = require("./lib/read-stdin");
const { isSubagentCall } = require("./lib/subagent-detect");
const { isCommandTool, isPowerShellTool, commandListOf } = require("./lib/tool-command-text");

const HOOK_NAME = "block-main-audit-verdict";

const BLOCK_MESSAGE =
  "the main conversation cannot write a supervisor audit verdict — verdicts are written only by the " +
  "supervisor-audit subagent. To accept an audit result as the main conversation, use the ask-gated " +
  "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel instead.";

// A path segment ending in bin/<name> (either slash), ended by whitespace, a quote, or the line end.
const binRe = (name) => new RegExp("(^|[\\s\"'/\\\\])bin[/\\\\]+" + name + "(?=$|[\\s\"'])");
const VERDICT_CLI_RE = binRe("supervisor-write-audit-verdict");
const AUDIT_CLI_RE = binRe("supervisor-write-audit");
const SET_VERDICT_FLAG_RE = /(^|\s)--set-audit-verdict(?=$|[\s=])/;

function isVerdictWrite(command) {
  if (VERDICT_CLI_RE.test(command)) return true;
  return AUDIT_CLI_RE.test(command) && SET_VERDICT_FLAG_RE.test(command);
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

module.exports = { BLOCK_MESSAGE, isVerdictWrite };

if (require.main === module) {
  const r = readHookInput();
  if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
  if (r.kind === "json-invalid") block(`[${HOOK_NAME}] hook input is not valid JSON, so the call is blocked (fail-closed).`);
  const input = r.input || {};

  if (!isCommandTool(input.tool_name) && !isPowerShellTool(input.tool_name)) approve();
  if (isSubagentCall(input)) approve();

  for (const raw of commandListOf(input.tool_name, input.tool_input)) {
    if (isVerdictWrite(String(raw))) block(BLOCK_MESSAGE);
  }
  approve();
}
