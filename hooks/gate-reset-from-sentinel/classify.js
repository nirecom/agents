"use strict";
// Stage 1 of gate-reset-from-sentinel (#2852): light modules only. A command tool whose text holds
// the sentinel token is judged (stage 2) only when it is exactly one canonical RESET_FROM echo;
// a chained, piped, multi-element or misspelled form asks, and everything else abstains.
// A non-Bash command tool carrying the token always asks: it may drive pwsh, where smart quotes
// close a string, so only Bash (as in hooks/bash-guard/judge.js) is judged.

const { readHookInput } = require("../lib/read-stdin");
const { isCommandTool, commandListOf, commandTextOf } = require("../lib/tool-command-text");
const { RESET_FROM_RE_DQ, hasUnsafeSentinelBody } = require("../lib/sentinel-patterns");

const TOKEN = "<<WORKFLOW_RESET_FROM_";

// classify() -> { kind: "none" } | { kind: "ask", reason } | { kind: "judge", input, target, reason }.
// Token present on a non-Bash command tool -> ask (pwsh quoting is not covered by RESET_FROM_RE_DQ).
function classify() {
  const r = readHookInput();
  if (r.kind !== "ok" || !r.input || typeof r.input !== "object") return { kind: "none" };
  const input = r.input;
  if (!isCommandTool(input.tool_name)) return { kind: "none" };
  const text = String(commandTextOf(input.tool_name, input.tool_input) || "");
  if (!text.includes(TOKEN)) return { kind: "none" };
  if (input.tool_name !== "Bash") {
    return { kind: "ask", reason: "RESET_FROM sentinel on a non-Bash command tool; asking instead of judging the reset allowance." };
  }
  const list = commandListOf(input.tool_name, input.tool_input);
  const m = list.length === 1 ? RESET_FROM_RE_DQ.exec(String(list[0]).trim()) : null;
  if (!m) {
    return { kind: "ask", reason: "RESET_FROM sentinel is not one canonical echo command; asking instead of judging the reset allowance." };
  }
  if (hasUnsafeSentinelBody(m[2])) {
    return { kind: "ask", reason: "RESET_FROM sentinel reason holds a quote, backtick, $, backslash or line break; asking instead of judging the reset allowance." };
  }
  return { kind: "judge", input, target: m[1], reason: m[2] };
}

module.exports = { classify };
