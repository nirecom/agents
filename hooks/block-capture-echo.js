#!/usr/bin/env node
// PreToolUse hook: refuses "assign a command substitution to a variable, then do
// nothing but display it" — the model should reissue the inner command bare and
// read its stdout instead (rules/shell-commands.md, Command-Line Issuance
// Discipline). Unconditional deny: no marker (.workflow-off / .worktree-off) is
// honoured, because issuance discipline is orthogonal to workflow on/off.
// Dispatch only; the predicate lives in block-capture-echo/shape.js and the
// wording in block-capture-echo/remedy.js (rules/coding/file-split.md Pattern A).
"use strict";

const fs = require("fs");
const { isCommandTool, commandListOf } = require("./lib/tool-command-text");
// Imported from the clearance-token scanner because that file is the ONE sanctioned
// site enabling the preserveSubstitutionSpans option (fix-1780-round11 X1/X2).
const { parseWithSubstitutionSpans } = require("./block-clearance-token-write/bash-scan/scan");
const { detectCaptureEcho } = require("./block-capture-echo/shape");
const { buildRemedy } = require("./block-capture-echo/remedy");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    for (;;) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(Buffer.from(buf.slice(0, n)));
    }
  } catch (_e) {
    /* EOF on a pipe surfaces as an exception on some platforms */
  }
  return Buffer.concat(chunks).toString("utf8");
}

function passThrough() {
  console.log("{}");
  process.exit(0);
}

// Dual-field output, following hooks/check-worktree-notes-lang.js: `decision`
// blocks before the permission prompt resolves, `hookSpecificOutput` is the
// current-form spelling of the same verdict. Always exit 0 — never exit 2.
function block(reason) {
  console.log(JSON.stringify({
    decision: "block",
    reason,
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

// PARSE-ONCE contract, specialised to this hook: the unit is not the tool call but
// the EXECUTION UNIT (one element of commandListOf). Never parse the same unit
// twice, and never share state across units — detectCaptureEcho is pure.
// commandTextOf's newline join must NEVER be used here: newlines are not segment
// separators, so joining two genuinely separate shell executions would fabricate a
// single assignment→echo unit and reject a shape that never existed.
function main() {
  let input;
  try {
    const raw = readStdin();
    if (!raw) passThrough();
    input = JSON.parse(raw);
  } catch (_e) {
    passThrough();
  }
  if (!input || typeof input !== "object") passThrough();
  if (!isCommandTool(input.tool_name)) passThrough();

  const units = commandListOf(input.tool_name, input.tool_input);
  if (!Array.isArray(units) || units.length === 0) passThrough();

  for (const unit of units) {
    const hit = detectCaptureEcho(parseWithSubstitutionSpans(unit));
    if (hit) block(buildRemedy(hit));
  }
  passThrough();
}

if (require.main === module) {
  try {
    main();
  } catch (_e) {
    passThrough();
  }
}

module.exports = { main };
