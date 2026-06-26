#!/usr/bin/env node
// PreToolUse hook: block direct Write/Edit/MultiEdit/editFiles and Bash shell
// write-redirects on the memory directory (~/.claude/projects/c--git-agents/memory/).
// Behavioral issues should be filed as GitHub Issues, not saved to memory.
// Fail-open: any error path approves rather than blocking.
"use strict";
const os = require("os");
const path = require("path");
const fs = require("fs");
const { isUnderPath } = require("./lib/path-match");
const { isWorkflowOff } = require("./lib/session-markers");
const { resolveSessionId } = require("./lib/workflow-state/session-id");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
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

const MEMORY_DIR = path.join(os.homedir(), ".claude", "projects", "c--git-agents", "memory");
const BLOCK_MSG = [
  "Memory write intercepted. This may be an agents-repo behavior improvement that belongs in GitHub Issues.",
  "",
  "Please ask the user:",
  "1. Create a GitHub issue with /issue-create (Recommended)",
  "2. Allow this memory write",
  "3. Cancel / do nothing",
  "4. Other",
].join("\n");

function hitsMemory(filePath) {
  return isUnderPath(filePath, MEMORY_DIR);
}

function bashHitsMemory(cmd) {
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
  return targets.some(t => isUnderPath(t, MEMORY_DIR));
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

let memoryHit = false;
switch (toolName) {
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    memoryHit = hitsMemory(toolInput.file_path);
    break;
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    memoryHit = bashHitsMemory(toolInput.command);
    break;
  default:
    break;
}

if (!memoryHit) approve();

const sid = resolveSessionId({ sessionIdFromInput: input.session_id });
if (sid) {
  try {
    const plansDir = getWorkflowPlansDir();
    const markerPath = path.join(plansDir, sid + ".memory-write-allow.tmp");
    try {
      if (fs.existsSync(markerPath)) {
        fs.unlinkSync(markerPath);
        approve();
      }
    } catch (_e) {
      // fall through to block
    }
  } catch (_e) {
    // plansDir unavailable, skip marker check
  }

  if (isWorkflowOff(sid)) approve();
}

block(BLOCK_MSG);
