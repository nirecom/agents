#!/usr/bin/env node
"use strict";
// hooks/subagent-dispatch-prompt.js — PreToolUse (Agent|Task) hook. Appends the canonical line of
// rules/shell-commands.md "Subagent Dispatch Prompts" to a dispatch prompt that lacks it, via
// updatedInput; a JSON-object prompt gets it under the reserved dispatch_directive key instead.
// Never returns a permission decision; every failure is a passthrough (fail-open).

const fs = require("fs");
const path = require("path");
const { readHookInput } = require("./lib/read-stdin");
const { toWindowsPath } = require("./lib/branch-diff");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..");
const RULE_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "rules", "shell-commands.md").replace(/\\/g, "/");

const CANONICAL_TEMPLATE =
  "Read `{RULE_PATH}` before the first Bash command and before writing a file, follow its Subagent Dispatch Prompts section, and end the final report with a `Command-form deviations` section counting every blocked or rejected command (write `0` when none) unless your own output contract fixes the exact shape of your reply.";
const RULE_PATH_SLOT = "{RULE_PATH}";
const DIRECTIVE_KEY = "dispatch_directive";
const WRITE_CAPABLE_TOOLS = new Set(["Bash", "Write", "Edit"]);
const DISPATCH_TOOLS = new Set(["Agent", "Task"]);
const AGENT_NAME_RE = /^[a-z0-9-]+$/;

const CANONICAL_LINE = CANONICAL_TEMPLATE.split(RULE_PATH_SLOT).join(RULE_PATH);

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const CANONICAL_RE = new RegExp(
  "^" +
    CANONICAL_TEMPLATE.split(RULE_PATH_SLOT)
      .map(escapeRe)
      .join("(?:[A-Za-z]:)?/(?:\\S*/)?rules/shell-commands\\.md") +
    "$"
);

function passthrough() {
  return {};
}

function isCanonicalLine(line) {
  return typeof line === "string" && CANONICAL_RE.test(line.trim());
}

function agentToolList(agentFile) {
  const text = fs.readFileSync(agentFile, "utf8");
  const m = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(text);
  if (!m) return null;
  const tools = /^tools:[ \t]*(.*)$/m.exec(m[1]);
  if (!tools) return null;
  return tools[1].split(",").map((t) => t.trim().replace(/^[[\s"']+|[\]\s"']+$/g, "")).filter(Boolean);
}

function isExemptAgent(subagentType, agentsDir) {
  if (typeof subagentType !== "string" || !AGENT_NAME_RE.test(subagentType)) return false;
  let tools;
  try {
    tools = agentToolList(path.join(agentsDir, subagentType + ".md"));
  } catch (_e) {
    return false;
  }
  if (!tools) return false;
  return !tools.some((t) => WRITE_CAPABLE_TOOLS.has(t));
}

function parseJsonObject(prompt) {
  if (!prompt.trim().startsWith("{")) return null;
  let parsed;
  try { parsed = JSON.parse(prompt); } catch (_e) { return null; }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  return parsed;
}

function rewrittenPrompt(prompt) {
  const obj = parseJsonObject(prompt);
  if (obj) {
    if (isCanonicalLine(obj[DIRECTIVE_KEY])) return null;
    return JSON.stringify({ ...obj, [DIRECTIVE_KEY]: CANONICAL_LINE });
  }
  if (prompt.split(/\r?\n/).some(isCanonicalLine)) return null;
  return prompt + "\n\n" + CANONICAL_LINE;
}

function decide(input, opts = {}) {
  try {
    if (!input || !DISPATCH_TOOLS.has(input.tool_name)) return passthrough();
    const toolInput = input.tool_input;
    if (!toolInput || typeof toolInput !== "object" || Array.isArray(toolInput)) return passthrough();
    const prompt = toolInput.prompt;
    if (typeof prompt !== "string" || !prompt.trim()) return passthrough();
    const agentsDir = opts.agentsDir
      ? toWindowsPath(opts.agentsDir)
      : path.join(SCRIPT_CHECKOUT_ROOT, "agents");
    if (isExemptAgent(toolInput.subagent_type, agentsDir)) return passthrough();
    const next = rewrittenPrompt(prompt);
    if (next === null) return passthrough();
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: { ...toolInput, prompt: next },
      },
    };
  } catch (_e) {
    return passthrough();
  }
}

function main() {
  let out = passthrough();
  try {
    const r = readHookInput();
    if (r.kind === "ok") out = decide(r.input);
  } catch (_e) {
    out = passthrough();
  }
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

module.exports = { decide, passthrough, isCanonicalLine, CANONICAL_TEMPLATE, DIRECTIVE_KEY };

if (require.main === module) main();
