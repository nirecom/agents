#!/usr/bin/env node
// Claude Code PreToolUse hook: block system-wide irreversible operations.
// Categories: A (pkg install), B (power), C (svc stop/disable/mask),
//             D (user/group), E (reg/boot), F (disk/FS).
// Detection lives in hooks/lib/system-ops-categories.js (shared with the
// scratchpad-script auto-approve content scan).
// Bypass: set SYSTEM_OPS_APPROVED=1 in the environment BEFORE launching Claude Code.
// Inline prefix (SYSTEM_OPS_APPROVED=1 cmd) does NOT reach this hook's process.env.
// lib/load-env.js is intentionally NOT loaded (would allow .env-based bypass).
// Scope: Bash, runInTerminal, runCommands.

"use strict";

const fs = require("fs");
const { stripQuotedArgs } = require("./lib/strip-quoted-args");
const { getBlockCategory } = require("./lib/system-ops-categories");

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
    // EOF or no stdin
  }
  return Buffer.concat(chunks).toString("utf8");
}

// Tool set + payload-shape normalization are shared with
// hooks/block-clearance-token-write/dispatch.js and
// hooks/supervisor-off-proposal-shim.js (CPR-SSOT). This file modeled the
// runCommands array shape correctly first; the helper preserves that
// contract verbatim (join with "\n").
const { COMMAND_TOOL_NAMES, commandTextOf } = require("./lib/tool-command-text");

const ALLOWED_TOOLS = new Set(COMMAND_TOOL_NAMES);

const input = readStdin();
if (!input || !input.trim()) process.exit(0);

let parsed;
try {
  parsed = JSON.parse(input);
} catch (e) {
  process.exit(0);
}

if (!parsed || !ALLOWED_TOOLS.has(parsed.tool_name)) process.exit(0);

const rawCmd = commandTextOf(parsed.tool_name, parsed.tool_input);

if (!rawCmd) process.exit(0);

// Bypass: inherited env only. Inline VAR=1 prefix does not propagate to this process.
if (process.env.SYSTEM_OPS_APPROVED === "1") process.exit(0);

// Extract inner command body from interpreter -c '...' invocations BEFORE stripping,
// so `bash -c 'winget install jq'` is caught even though the outer stripped form is `bash -c ''`.
function getInnerBodies(raw) {
  const bodies = [];
  const re = /(?:^|[\s;|&])(?:bash|sh|zsh|pwsh|powershell(?:\.exe)?)\b[^|;&\n]*-c\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)")/gi;
  let m;
  while ((m = re.exec(raw)) !== null) {
    const body = m[1] !== undefined ? m[1] : m[2];
    if (body) bodies.push(body);
  }
  return bodies;
}

const innerBodies = getInnerBodies(rawCmd);
const stripped = stripQuotedArgs(rawCmd);
const candidates = [stripped, ...innerBodies];

let blockedCategory = null;
for (const candidate of candidates) {
  const cat = getBlockCategory(candidate);
  if (cat) {
    blockedCategory = cat;
    break;
  }
}

if (!blockedCategory) process.exit(0);

process.stderr.write(
  `enforce-system-ops: blocked (${blockedCategory}). System-wide irreversible operations\n` +
    `require explicit user approval — escalate via Rule 2 per rules/user-escalation.md.\n` +
    `If this is a legitimate installer flow, set SYSTEM_OPS_APPROVED=1 in the\n` +
    `environment that LAUNCHES Claude Code (inline prefix does NOT bypass this guard).\n` +
    `Read rules/installer.md and rules/ops.md before proceeding — rules/ops.md is\n` +
    `on-demand-only (never auto-injected), so this Read is the only way it arrives.\n`
);
process.exit(2);
