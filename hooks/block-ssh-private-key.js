#!/usr/bin/env node
// PreToolUse hook: block read/write of files under ~/.ssh/.
// Tool-name dispatch mirrors block-dotenv.js.
"use strict";
const fs = require("fs");
const path = require("path");
const os = require("os");
const { checkBashCommand } = require("./lib/command-parser");

// --- I/O helpers (copy verbatim from block-dotenv.js) ---
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {
    // EOF or error
  }
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

const HOME = os.homedir();
const SSH_DIR = path.join(HOME, ".ssh");

function normalizeSlash(p) { return p.replace(/\\/g, "/"); }
// Collapse `/./` segments so `~/./.ssh/x` matches `~/.ssh/x`.
function normalizeDot(p) { return p.replace(/\/\.\//g, "/"); }
function normalize(p) { return normalizeDot(normalizeSlash(p)); }

// True for ~/.ssh OR any descendant. Bare directory included.
// .pub files NOT allowlisted (uniform policy).
function isSshPath(p) {
  if (!p) return false;
  const s = normalize(p);
  if (s === "~/.ssh" || s.startsWith("~/.ssh/")) return true;
  const sshNorm = normalize(SSH_DIR);
  if (s === sshNorm || s.startsWith(sshNorm + "/")) return true;
  if (s === "$HOME/.ssh" || s.startsWith("$HOME/.ssh/")) return true;
  if (s === "${HOME}/.ssh" || s.startsWith("${HOME}/.ssh/")) return true;
  // Windows homedir env-var form (PowerShell / CMD parity).
  if (s === "$USERPROFILE/.ssh" || s.startsWith("$USERPROFILE/.ssh/")) return true;
  if (s === "${USERPROFILE}/.ssh" || s.startsWith("${USERPROFILE}/.ssh/")) return true;
  // Literal root homedir — covered by SSH_DIR only when running as root.
  if (s === "/root/.ssh" || s.startsWith("/root/.ssh/")) return true;
  return false;
}

// True for glob/grep patterns targeting ~/.ssh/.
function isSshGlobPattern(pattern) {
  if (!pattern) return false;
  const s = normalizeSlash(pattern);
  return (
    s.includes("~/.ssh/") || s.includes("/.ssh/") ||
    s === "~/.ssh" || s.endsWith("/.ssh")
  );
}

// -i REMOVED from PATH_FLAGS: collides with sed -i / grep -i / cp -i.
// Positional fallback still catches `ssh -i ~/.ssh/key host`.
const TEXT_FLAGS = new Set([
  "-m", "--message", "--body", "--title", "--notes", "--description",
  "--subject", "--branch", "--label", "--assignee", "--reviewer",
  "--milestone", "--project", "--head", "--base", "--config",
]);
const PATH_FLAGS = new Set([
  "-f", "--file", "-o", "--output", "--input",
  "--from-file", "--to-file", "-T", "--upload-file",
]);
const TEXT_CMDS = new Set(["echo", "printf"]);
const SHELL_BINS = new Set(["bash", "sh", "dash", "zsh", "ksh"]);

function checkBash(command) {
  return checkBashCommand(command, {
    isTargetPath: isSshPath,
    textFlags: TEXT_FLAGS,
    pathFlags: PATH_FLAGS,
    textCmds: TEXT_CMDS,
    shellBins: SHELL_BINS,
  });
}

const BLOCK_MSG =
  "Access to ~/.ssh/ files is blocked by hooks/block-ssh-private-key.js. " +
  "If this is a false-positive (e.g. the path appears only inside a text-flag " +
  "value or a quoted message), file an issue.";

const raw = readStdin();
let input;
try { input = JSON.parse(raw); } catch { approve(); }
const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (checkBash(toolInput.command || "")) block(BLOCK_MSG);
    break;
  case "Read":
    if (isSshPath(toolInput.file_path)) block(BLOCK_MSG);
    break;
  case "Grep":
    if (isSshPath(toolInput.path) || isSshGlobPattern(toolInput.glob)) block(BLOCK_MSG);
    break;
  case "Glob":
    if (isSshGlobPattern(toolInput.pattern)) block(BLOCK_MSG);
    break;
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isSshPath(toolInput.file_path)) block(BLOCK_MSG);
    break;
  default:
    break;
}
approve();
