#!/usr/bin/env node
// PreToolUse hook: when a command tool is about to run the <<WORKFLOW_USER_VERIFIED>>
// sentinel, emit a "User verification context:" systemMessage (staged files + open PR
// URL) BEFORE the permission dialog. Protocol: skills/_shared/user-verified.md.
// PreToolUse payloads carry no tool_response, so no exit-code gating is performed.
// Fail-open on all error paths — must never block the workflow.
"use strict";

const fs = require("fs");
const { spawnSync } = require("child_process");

// #2256 S5-a2: Bash/runInTerminal/runCommands normalization (SSOT: hooks/lib/tool-command-text.js).
// USER_VERIFIED_RE is unanchored, so the joined command text finds a sentinel in any element.
const { isCommandTool, commandTextOf } = require("./lib/tool-command-text");


// Match the reason-bearing form only — the bare form was removed from the contract (#404).
const USER_VERIFIED_RE = /<<WORKFLOW_USER_VERIFIED: [^>]+>>/;

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

function noopExit() { process.stdout.write(""); process.exit(0); }

// cwd resolution: prefer tool_input.cwd (Claude Code Bash payload field), then
// process.cwd(). CLAUDE_PROJECT_DIR is intentionally excluded — it points to the
// main worktree, causing gh pr view to find no PR when emitting from a linked worktree.
function resolveCwd(input) {
  const tiCwd = input.tool_input && input.tool_input.cwd;
  if (tiCwd && typeof tiCwd === "string" && tiCwd.trim()) {
    return tiCwd.trim();
  }
  return process.cwd();
}

function getStagedFiles(cwd) {
  try {
    const r = spawnSync("git", ["-C", cwd, "diff", "--cached", "--name-only"], {
      encoding: "utf8", timeout: 5000,
    });
    if (r.status !== 0) return [];
    return r.stdout.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  } catch (_) { return []; }
}

function getPrUrl(cwd) {
  try {
    const r = spawnSync("gh", ["pr", "view", "--json", "url", "-q", ".url"], {
      cwd, encoding: "utf8", timeout: 5000,
    });
    if (r.status !== 0 || !r.stdout.trim()) return "";
    return r.stdout.trim();
  } catch (_) { return ""; }
}

if (require.main === module) {
  let input = {};
  try { input = JSON.parse(readStdin()); } catch { noopExit(); }

  if (!isCommandTool(input.tool_name)) noopExit();

  const command = commandTextOf(input.tool_name, input.tool_input);
  if (!USER_VERIFIED_RE.test(command)) noopExit();

  const cwd = resolveCwd(input);
  const staged = getStagedFiles(cwd);
  const prUrl = getPrUrl(cwd);

  // Fixed prefix matches outline.md description — single SSOT for the surfaced wording.
  const lines = ["User verification context:", "Staged files:"];
  if (staged.length === 0) {
    lines.push("  (none)");
  } else {
    for (const f of staged) lines.push(`  - ${f}`);
  }
  if (prUrl) lines.push(`Open PR: ${prUrl}`);
  // SSOT: approval instruction. Prompts must NOT duplicate this wording (rules/prompt.md §3.1).
  lines.push("Click Allow on the next dialog to approve; click Deny to stop.");

  process.stdout.write(JSON.stringify({ systemMessage: lines.join("\n") }));
  process.exit(0);
}

module.exports = { USER_VERIFIED_RE };
