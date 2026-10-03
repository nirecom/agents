#!/usr/bin/env node
// PreToolUse hook: block direct Write/Edit/MultiEdit/editFiles on user shell
// config files under $HOME, plus Bash write-redirect / tee / PowerShell-cmdlet /
// cp / mv targets that resolve to those files. These are user-owned environment
// settings and must not be modified by the agent without explicit approval.
// Unreadable stdin blocks; other error paths approve.
"use strict";
const fs = require("fs");
const { isUnderAnyRoot } = require("./lib/path-match");
const { parse } = require("./lib/command-ir");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("./lib/bash-write-targets");
const { isCommandTool } = require("./lib/tool-command-text");
const { scannableCommandListOf } = require("./lib/scannable-command-list");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "block-shell-config";

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

const PROTECTED_ROOTS = [
  "~/.bashrc",
  "~/.zshrc",
  "~/.profile",
  "~/.bash_profile",
  "~/.profile_common",
];

function isProtectedPath(p) {
  return isUnderAnyRoot(p, PROTECTED_ROOTS, []);
}

function bashHitsProtected(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(cmd);
  if (!ir || ir.parseFailure) return false;
  const { targets } = collectWriteTargetsFromSegments(ir.segments, { verbs: SHELL_CONFIG_VERB_SET });
  if (!targets) return false;
  return targets.some((t) => isProtectedPath(t.path));
}

const BLOCK_MSG =
  "Direct writes to user shell config files (~/.bashrc, ~/.zshrc, ~/.profile, " +
  "~/.bash_profile, ~/.profile_common) are blocked. These are user-owned " +
  "environment settings — request explicit approval before modifying.";

const r = readHookInput();
if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
if (r.kind === "json-invalid") {
  try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
  approve();
}
const input = r.input;
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

if (isCommandTool(toolName)) {
  if (scannableCommandListOf(toolName, toolInput).some((cmd) => bashHitsProtected(cmd))) block(BLOCK_MSG);
}

switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isProtectedPath(toolInput.file_path)) block(BLOCK_MSG);
    break;
  default:
    break;
}

approve();
