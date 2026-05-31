#!/usr/bin/env node
// PreToolUse hook: block direct Write/Edit/MultiEdit/editFiles on user shell
// config files under $HOME, plus Bash write-redirect / tee / PowerShell-cmdlet /
// cp / mv targets that resolve to those files. These are user-owned environment
// settings and must not be modified by the agent without explicit approval.
// Fail-open: any error path approves rather than blocking.
"use strict";
const fs = require("fs");
const { isUnderAnyRoot } = require("./lib/path-match");
const {
  extractRedirectTargets, extractTeeTargets,
  extractPwshWriteTargets, extractCpMvDestination,
} = require("./lib/bash-write-targets");

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
  const targets = [];
  if (/(?:^|[\s;|&])(?:\d*)(?:&>>?|>>?)(?!>|\d)/.test(cmd)) {
    const r = extractRedirectTargets(cmd);
    if (r) targets.push(...r);
  }
  if (/(?:^|[\s;|&])tee\b/.test(cmd)) {
    const t = extractTeeTargets(cmd);
    if (t) targets.push(...t);
  }
  if (/\b(?:Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item)\b/i.test(cmd)
      || /(?:^|[\s;|&])(?:sc|ac|ni|ri|mi|ci)\b/.test(cmd)) {
    const p = extractPwshWriteTargets(cmd);
    if (p) targets.push(...p);
  }
  if (/(?:^|[\s;|&])(?:cp|mv)\b/.test(cmd)) {
    const d = extractCpMvDestination(cmd);
    if (d) targets.push(d);
  }
  return targets.some(isProtectedPath);
}

const BLOCK_MSG =
  "Direct writes to user shell config files (~/.bashrc, ~/.zshrc, ~/.profile, " +
  "~/.bash_profile, ~/.profile_common) are blocked. These are user-owned " +
  "environment settings — request explicit approval before modifying.";

let input;
try {
  input = JSON.parse(readStdin());
} catch (_e) {
  approve();
}
if (!input || typeof input !== "object") approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isProtectedPath(toolInput.file_path)) block(BLOCK_MSG);
    break;
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (bashHitsProtected(toolInput.command)) block(BLOCK_MSG);
    break;
  default:
    break;
}

approve();
