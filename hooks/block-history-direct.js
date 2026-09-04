#!/usr/bin/env node
// PreToolUse hook: block direct writes to the append-only document family
// (see hooks/lib/history-path-check.js for the protected set) through the
// tool-write path and the shell path. These files must be modified via the
// `doc-append` CLI. Fail-open: any error path approves rather than blocking.
// Registration contract: settings.json must register this hook in BOTH
// "Edit|Write|MultiEdit|editFiles" and "Bash|runInTerminal|runCommands"
// PreToolUse matcher groups (pinned by
// tests/feature-1611-append-only-archive-guard.sh T1-R).
"use strict";
const fs = require("fs");
// Detection lives in hooks/lib/history-path-check.js (shared with the
// scratchpad-script auto-approve body scan).
const { isProtectedPath, bashHitsProtected } = require("./lib/history-path-check");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

// Shared by both dispatch lanes (CPR-ORTH): a protected hit blocks UNLESS the
// calling session has an active WORKFLOW_ENFORCE_WORKFLOW_OFF /
// WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY marker (<workflowDir>/<sid>.workflow-off),
// in which case it approves instead —
// after writing a stderr notice so the bypass is never silent. Only ever
// called once a hit has actually been detected, so a non-hit never reaches
// (and never logs via) this path.
function blockOrBypass(sid) {
  try {
    const { isWorkflowOff, workflowOffNoticeText } = require("./lib/session-markers");
    if (isWorkflowOff(sid)) {
      process.stderr.write(workflowOffNoticeText("block-history-direct", sid) + "\n");
      approve();
    }
  } catch (_e) {
    // require() or the marker check itself threw — a confirmed protected hit
    // must still block; do not let a dependency failure fail this open.
  }
  block(BLOCK_MSG);
}

const BLOCK_MSG =
  "Direct writes to the append-only document family (canonical docs/history.md and " +
  "CHANGELOG.md, plus their rotated archives under docs/history/, changelog/ and " +
  "docs/changelog/) are blocked. Use the `doc-append` CLI to add entries, or " +
  "`uv run bin/doc-rotate.py` to archive them. See rules/docs/history.md for usage.";

let input;
try {
  input = JSON.parse(readStdin());
} catch (_e) {
  approve();
}
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};
const sid = input.session_id;

switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isProtectedPath(toolInput.file_path)) blockOrBypass(sid);
    break;
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (bashHitsProtected(toolInput.command)) blockOrBypass(sid);
    break;
  default:
    break;
}

approve();
