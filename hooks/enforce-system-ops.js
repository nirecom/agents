#!/usr/bin/env node
// Claude Code PreToolUse hook: block system-wide irreversible operations.
// Categories: A (pkg install), B (power), C (svc stop/disable/mask),
//             D (user/group), E (reg/boot), F (disk/FS).
// Detection lives in hooks/lib/system-ops-categories.js (shared with the
// scratchpad-script auto-approve content scan).
// Bypass: set SYSTEM_OPS_APPROVED=1 in the environment BEFORE launching Claude Code.
// Inline prefix (SYSTEM_OPS_APPROVED=1 cmd) does NOT reach this hook's process.env.
// lib/load-env.js is intentionally NOT loaded (would allow .env-based bypass).
// Scope: Bash, runInTerminal, runCommands. Unreadable stdin blocks (exit 2).

"use strict";

const fs = require("fs");
const { stripQuotedArgs } = require("./lib/strip-quoted-args");
const { getBlockCategory } = require("./lib/system-ops-categories");
const { inlineBodiesOf } = require("./lib/interpreter-inline-body");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "enforce-system-ops";

// Tool set + payload shape are shared (CPR-SSOT); the deny-side list also keeps a
// runCommands scalar `.command`, joined with "\n" as separate statements.
const { COMMAND_TOOL_NAMES } = require("./lib/tool-command-text");
const { scannableCommandListOf } = require("./lib/scannable-command-list");

const ALLOWED_TOOLS = new Set(COMMAND_TOOL_NAMES);

// Bypass: inherited env only. Inline VAR=1 prefix does not propagate to this process.
if (process.env.SYSTEM_OPS_APPROVED === "1") process.exit(0);

const r = readHookInput();
if (r.kind === "read-error") {
  process.stderr.write(readFailureReason(HOOK_NAME, r.error) + "\n");
  process.exit(2);
}
if (r.kind === "json-invalid") {
  try {
    fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n");
  } catch (_) {}
  process.exit(0);
}

const parsed = r.input;
if (!parsed || !ALLOWED_TOOLS.has(parsed.tool_name)) process.exit(0);

const rawCmd = scannableCommandListOf(parsed.tool_name, parsed.tool_input).join("\n");

if (!rawCmd) process.exit(0);

function failClosed(why) {
  process.stderr.write(`enforce-system-ops: blocked (fail-closed): ${why}. Split the command into simpler calls.\n`);
  process.exit(2);
}

// Pre-IR regex extraction, kept for lines the IR rejects (`bash -c '…' # it's`):
// quote-stripping alone would hide the wrapped body there.
const LEGACY_BODY_RE = /(?:^|[\s;|&])(?:bash|sh|zsh|dash|fish|ksh|ksh93|mksh|ash|pwsh|powershell)(?:\.exe)?\b[^|;&\n]*?-\w*c\w*\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)")/gi;

function legacyBodiesOf(line) {
  const bodies = [];
  for (const m of line.matchAll(LEGACY_BODY_RE)) {
    const body = m[1] !== undefined ? m[1] : m[2];
    if (body) bodies.push(body);
  }
  return bodies;
}

// unparsedLines is the fail-safe for lines the IR rejects; judged quote-stripped so
// an example inside quotes does not block merely because its line failed to parse.
let blockedCategory = null;
try {
  const { bodies, unparsedLines, overflow } = inlineBodiesOf(rawCmd);
  if (overflow) failClosed("inline interpreter bodies exceed the scan limit");
  const legacy = unparsedLines.flatMap(legacyBodiesOf);
  const legacyNested = inlineBodiesOf(legacy.join("\n"));
  if (legacyNested.overflow) failClosed("inline interpreter bodies exceed the scan limit");
  const candidates = [stripQuotedArgs(rawCmd), ...bodies, ...unparsedLines.map(stripQuotedArgs), ...legacy, ...legacyNested.bodies];
  for (const candidate of candidates) {
    const cat = getBlockCategory(candidate);
    if (cat) {
      blockedCategory = cat;
      break;
    }
  }
} catch (e) {
  failClosed(`classification error (${(e && e.name) || "unknown"})`);
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
