#!/usr/bin/env node
// PreToolUse hook (matcher: Monitor|EnterWorktree|Bash|runInTerminal|runCommands):
// auto-approves low-risk tool calls so the user is not interrupted for routine,
// non-destructive actions — background Monitor polling, EnterWorktree moves inside
// the sanctioned WORKTREE_BASE_DIR tree, and `bash <this session's scratchpad>.sh`.
//
// Fail-safe by construction: any missing input, missing config, or
// unexpected shape falls through to "no output, exit 0" — which leaves the
// existing confirm flow in control. This hook only ever ADDS an allow; it
// never denies (no permissionDecision:"deny" branch exists here).
"use strict";

const fs = require("fs");
const path = require("path");
const { isCommandTool, commandListOf } = require("./lib/tool-command-text");
const { isAllowedScratchpadInvocation } = require("./preuse-auto-approve/scratchpad-script");

try {
  require("./lib/load-env").loadDefaultEnv();
} catch (_e) {
  /* fail-open: proceed with whatever process.env already has */
}

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {
    /* fail-open: treat as empty stdin */
  }
  return Buffer.concat(chunks).toString("utf8");
}

function passThrough() {
  console.log("{}");
  process.exit(0);
}

function allow(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

// normalizeForCompare collapses backslashes to forward slashes, resolves
// `.`/`..` segments (so a `../../etc` traversal attempt cannot forge a
// prefix match against WORKTREE_BASE_DIR), and lowercases the result (so
// Windows drive-letter casing does not defeat the comparison).
function normalizeForCompare(p) {
  if (typeof p !== "string" || p.length === 0) return "";
  const slashed = p.replace(/\\/g, "/");
  let normalized;
  try {
    normalized = path.posix.normalize(slashed);
  } catch (_e) {
    normalized = slashed;
  }
  // Strip a single trailing slash (except root) so boundary comparison below
  // is consistent regardless of whether the input had one.
  if (normalized.length > 1 && normalized.endsWith("/")) {
    normalized = normalized.slice(0, -1);
  }
  return normalized.toLowerCase();
}

// isInsideBase answers "does candidatePath live under baseDir?" using a
// segment-boundary check (not a bare startsWith), so WORKTREE_BASE_DIR=/foo
// does not falsely match a sibling directory like /foobar.
function isInsideBase(candidatePath, baseDir) {
  const normCandidate = normalizeForCompare(candidatePath);
  const normBase = normalizeForCompare(baseDir);
  if (!normCandidate || !normBase) return false;
  return normCandidate === normBase || normCandidate.startsWith(normBase + "/");
}

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

  const autoApprove = process.env.AUTO_APPROVE_TOOLS;
  if (typeof autoApprove === "string" && autoApprove.trim().toLowerCase() === "off") {
    passThrough();
  }

  const tool = input.tool_name;

  if (tool === "Monitor") {
    allow("Monitor auto-approved: low-risk background monitoring");
    return;
  }

  if (tool === "EnterWorktree") {
    const base = process.env.WORKTREE_BASE_DIR;
    if (typeof base !== "string" || base.trim().length === 0) passThrough();

    const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
    const targetPath = toolInput.path;
    if (typeof targetPath !== "string" || targetPath.trim().length === 0) passThrough();

    // Resolve symlinks so a symlink inside WORKTREE_BASE_DIR that points
    // outside cannot be used to bypass the boundary check.
    let resolvedPath = targetPath;
    try {
      resolvedPath = fs.realpathSync(targetPath);
    } catch (_e) {
      // If the path doesn't exist yet or realpath fails, use the original path.
      // This is fail-open for the symlink check: an unresolvable path still
      // proceeds through isInsideBase with the original value.
    }

    if (isInsideBase(resolvedPath, base)) {
      allow("EnterWorktree auto-approved: path is within WORKTREE_BASE_DIR");
      return;
    }
    passThrough();
    return;
  }

  if (isCommandTool(tool)) {
    let units = null;
    try {
      units = commandListOf(tool, input.tool_input);
    } catch (_e) {
      passThrough();
    }
    // One execution unit only: a list is several independent commands, and this
    // allow covers exactly one `bash <scratchpad script>` invocation.
    if (Array.isArray(units) && units.length === 1 && isAllowedScratchpadInvocation(units[0])) {
      allow("Scratchpad script auto-approved: bash invocation of a .sh file inside this session's scratchpad");
      return;
    }
    passThrough();
    return;
  }

  passThrough();
}

if (require.main === module) {
  main();
}

module.exports = { normalizeForCompare, isInsideBase };
