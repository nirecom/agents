#!/usr/bin/env node
// PreToolUse hook: block direct writes to an OFF-clearance token
// (<workflowDir>/<sid>.off-clearance), which only bin/request-off-clearance may
// mint after a Phase1 examination (#1608).
//
// TRUST MODEL (accepted limitation): this is a BEST-EFFORT deterrent, not a hard
// gate. Dynamic path construction (variable concatenation, base64, an alternate
// interpreter) and edits to the examiner / codex / this hook itself are NOT
// detectable here. The real gate is Phase2 human approval (settings.json `ask`,
// which the model cannot self-approve) plus the audit trail.
//
// Fail-open: every error path approves rather than blocking.
"use strict";
const path = require("path");
const fs = require("fs");
const { parse } = require("./lib/command-ir");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("./lib/bash-write-targets");

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

const BLOCK_MSG = [
  "Direct write to an OFF-clearance token blocked.",
  "Clearance tokens are minted only by the Phase1 examination:",
  "  bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> --category <rubric category> --detail \"<why>\"",
  "If the examiner itself is broken, use the EMERGENCY OFF sentinel (human approval required).",
].join("\n");

// Basename match, intentionally directory-agnostic: the token directory varies by
// CLAUDE_WORKFLOW_DIR, and a token written anywhere is still an attempt to forge one.
const TOKEN_BASENAME_RE = /\.off-clearance(\.tmp)?$/;

function hitsToken(filePath) {
  if (!filePath || typeof filePath !== "string") return false;
  return TOKEN_BASENAME_RE.test(path.basename(filePath.replace(/\\/g, "/")));
}

function bashHitsToken(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  try {
    const ir = parse(cmd);
    if (ir && !ir.parseFailure) {
      const { targets } = collectWriteTargetsFromSegments(ir.segments, { verbs: SHELL_CONFIG_VERB_SET });
      if (targets && targets.some(t => t && hitsToken(t.path))) return true;
    }
  } catch (_e) { /* fall through to the heuristic */ }
  return hitsTokenViaInterpreter(cmd);
}

// vector2 heuristic (best-effort, deliberately incomplete): an interpreter
// one-liner whose body mentions the clearance-token name. Only literal mentions
// are caught; any constructed or encoded path escapes it by design.
const INTERPRETER_RE = /\b(node|nodejs|python|python3|perl|ruby|deno|bun|pwsh|powershell)\b[^\n]*\s-(e|c|Command|command)\b/;

function hitsTokenViaInterpreter(cmd) {
  if (!INTERPRETER_RE.test(cmd)) return false;
  return /off-clearance/.test(cmd);
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (_e) {
  approve();
}
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

let tokenHit = false;
try {
  switch (toolName) {
    case "Edit":
    case "Write":
    case "MultiEdit":
    case "editFiles":
      tokenHit = hitsToken(toolInput.file_path);
      break;
    case "Bash":
    case "runInTerminal":
    case "runCommands":
      tokenHit = bashHitsToken(toolInput.command);
      break;
    default:
      break;
  }
} catch (_e) {
  approve(); // fail-open
}

if (!tokenHit) approve();

block(BLOCK_MSG);
