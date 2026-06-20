#!/usr/bin/env node
// Claude Code PreToolUse hook: block access to .env files and .private-info-allowlist
// Matches: Bash, Read, Grep, Glob, Edit, Write, MultiEdit tools
// Allows: .env.example, .env.sample, .env.template, .env.dist

const fs = require("fs");
const { checkBashCommand: checkCmd } = require("./lib/command-parser");
const { getBasename } = require("./lib/path-match");

// Read stdin (cross-platform: fs.readSync for Windows compatibility)
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

// Suffixes that are safe to access (documentation/template files)
const SAFE_SUFFIXES = [".env.example", ".env.sample", ".env.template", ".env.dist"];

// Flags whose VALUE is text (not a path). The token after these is skipped.
//
// Single-letter short forms `-l`, `-a`, `-r`, `-c` are intentionally OMITTED
// even though gh/git accept them, because they collide with very common Unix
// flags (`wc -l file`, `ls -a dir`, `cp -r src dst`, `bash -c script`) and
// would create read/write bypasses for `.env`. Users must use the long form
// (`--label`, `--assignee`, `--reviewer`) when targeting gh from this hook's
// scope. `-c` is handled separately via shell-wrapper recursion (SHELL_BINS).
//
// `-m` is kept (highly common for `git commit -m`, `gh pr create -m`); its
// value is text not a path, and `-m .env` as a literal git-commit message
// happens to be safe — it's a message string, not a file access.
const TEXT_FLAGS = new Set([
  "-m", "--message",
  "--body", "--title", "--notes", "--description", "--subject",
  "--branch",
  "--label",
  "--assignee",
  "--reviewer",
  "--milestone", "--project",
  "--head", "--base",
  "--config",
]);

// Flags whose VALUE is a path. The token after is checked with isDotenvPath.
const PATH_FLAGS = new Set([
  "-f", "--file",
  "-o", "--output",
  "-i", "--input",
  "--from-file", "--to-file",
  "-T", "--upload-file",
]);

// Shell-wrapper basenames whose `-c <script>` value is parsed recursively.
const SHELL_BINS = new Set(["bash", "sh", "dash", "zsh", "ksh"]);

// Commands whose positional arguments are message text, not paths.
// Without this exemption, `echo "copy .env to prod"` would tokenize to `.env`
// and incorrectly block.
const TEXT_CMDS = new Set(["echo", "printf"]);

function isSafeDotenv(name) {
  return SAFE_SUFFIXES.some((s) => name.endsWith(s));
}

// Check if a path's basename is a .env file (not a safe variant)
// Matches: .env, .env.local, .env.production, etc.
// Does NOT match: .envrc, .environment, envconfig.js, etc.
function isDotenvPath(filePath) {
  if (!filePath) return false;
  // Normalize to forward slashes and get basename
  const basename = getBasename(filePath);
  if (!basename) return false;
  // Exact .env
  if (basename === ".env") return true;
  // .env.xxx but not .envrc, .environment, etc.
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// Path-position parser: tokenize the command, walk argv, check only tokens at
// path-bearing positions. Replaces the previous strip-then-regex approach;
// text-flag values (-m, --body, --title, etc.) are skipped by construction so
// `gh pr create --body "Fix .env hook"` and `git commit -m "..."` are no
// longer false-positives.
//
// Substitutions ($(...) and backticks) are recursed into BEFORE stripping,
// because they execute as shell commands — `gh pr create --body "$(cat .env)"`
// must block.
function checkBashCommand(command) {
  return checkCmd(command, {
    isTargetPath: isDotenvPath,
    textFlags: TEXT_FLAGS,
    pathFlags: PATH_FLAGS,
    textCmds: TEXT_CMDS,
    shellBins: SHELL_BINS,
  });
}

function isProtectedPath(filePath) {
  if (!filePath) return false;
  const basename = getBasename(filePath);
  return basename === ".private-info-allowlist" || basename === ".offensive-content-blocklist";
}

// For Glob patterns: detect .env search patterns
function checkGlobPattern(pattern) {
  if (!pattern) return false;
  const basename = getBasename(pattern);
  if (!basename) return false;

  // Wildcarded .env patterns
  if (basename === ".env" || basename === ".env.*" || basename === ".env*") return true;
  // Specific .env.xxx — check if safe
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// Parse stdin
let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  // Invalid JSON — approve (fail-open for non-matching input)
  approve();
}

// Session-scoped WORKFLOW override: bypass all .env checks for this session.
const { isWorkflowOff } = require("./lib/session-markers");
if (isWorkflowOff(input.session_id)) approve();

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (checkBashCommand(toolInput.command)) {
      block("Access to .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Read":
    if (isDotenvPath(toolInput.file_path)) {
      block("Reading .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Grep":
    if (isDotenvPath(toolInput.path) || checkGlobPattern(toolInput.glob)) {
      block("Searching .env files is blocked. Use .env.example for documentation.");
    }
    break;

  case "Glob":
    if (checkGlobPattern(toolInput.pattern)) {
      block("Searching for .env files is blocked.");
    }
    break;

  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isDotenvPath(toolInput.file_path)) {
      block("Writing .env files is blocked. Use .env.example for documentation.");
    }
    if (isProtectedPath(toolInput.file_path)) {
      const basename = getBasename(toolInput.file_path);
      if (basename === ".private-info-allowlist") {
        block("Writing .private-info-allowlist is blocked. Edit manually if an exception is genuinely needed.");
      } else {
        block("Writing .offensive-content-blocklist is blocked. Edit manually if a pattern change is genuinely needed.");
      }
    }
    break;

  default:
    break;
}

approve();
