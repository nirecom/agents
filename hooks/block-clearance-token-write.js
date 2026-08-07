#!/usr/bin/env node
// PreToolUse hook: block direct writes to — and deletions of — any CLEARANCE TOKEN,
// the class of session-scoped files that decide what the pipeline believes about
// user authorization (#1608). Only their owning minters may create them:
//   .off-clearance             bin/request-off-clearance (after a Phase1 examination)
//
// DELETE is guarded as strictly as overwrite: removing a clearance token re-arms it.
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
  "Direct write to (or deletion of) a clearance token blocked.",
  "Clearance tokens are minted only by their owning tool — never by hand:",
  "  .off-clearance             bash \"$AGENTS_CONFIG_DIR/bin/request-off-clearance\" --target <workflow|worktree> --category <rubric category> --detail \"<why>\"",
  "If the minter itself is broken, use the EMERGENCY OFF sentinel (human approval required).",
].join("\n");

// The clearance-token class (CPR-E2C). Adding a suffix here extends the guard to a new
// token in one place — the class, not one member, is what is protected.
const CLEARANCE_SUFFIXES = [
  "off-clearance",
];

// Basename match, intentionally directory-agnostic: the token directory varies by
// CLAUDE_WORKFLOW_DIR, and a token written anywhere is still an attempt to forge one.
// `.tmp` is included because the atomic-write staging path is renamed onto the token.
// The `$` anchor is what keeps neighbours writable: `off-clearance-notes.md` and
// `docs/off-clearance.md` are documents, not tokens, and must not be caught.
const TOKEN_BASENAME_RE = new RegExp("\\.(" + CLEARANCE_SUFFIXES.join("|") + ")(\\.tmp)?$");

function hitsToken(filePath) {
  if (!filePath || typeof filePath !== "string") return false;
  return TOKEN_BASENAME_RE.test(path.basename(filePath.replace(/\\/g, "/")));
}

// A lexical sweep of every word in the command. The command-IR below only reports the
// WRITE targets of verbs it models; deletion, truncation, in-place edits, `command`/`env`
// prefixes, subshells and heredocs all reach the token without ever being a "write
// target". Whatever the route, a literally-spelled token path still appears as a word,
// so the word list is the route-independent observation.
const WORD_SPLIT_RE = /[\s;&|()<>"'`=,{}]+/;

function commandMentionsToken(cmd) {
  for (const word of cmd.split(WORD_SPLIT_RE)) {
    if (word && hitsToken(word)) return true;
  }
  return false;
}

function bashHitsToken(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  if (commandMentionsToken(cmd)) return true;
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
// one-liner whose body mentions a clearance-token name. Only literal mentions
// are caught; any constructed or encoded path escapes it by design.
const INTERPRETER_RE = /\b(node|nodejs|python|python3|perl|ruby|deno|bun|pwsh|powershell)\b[^\n]*\s-(e|c|Command|command)\b/;
const INTERPRETER_BODY_RE = /(off-clearance)/;

function hitsTokenViaInterpreter(cmd) {
  if (!INTERPRETER_RE.test(cmd)) return false;
  return INTERPRETER_BODY_RE.test(cmd);
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
