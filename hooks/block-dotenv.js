#!/usr/bin/env node
// Claude Code PreToolUse hook: block access to .env files
// Matches: Bash, Read, Grep, Glob tools
// Allows: .env.example, .env.sample, .env.template, .env.dist

const fs = require("fs");

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

function isSafeDotenv(name) {
  return SAFE_SUFFIXES.some((s) => name.endsWith(s));
}

// Check if a path's basename is a .env file (not a safe variant)
// Matches: .env, .env.local, .env.production, etc.
// Does NOT match: .envrc, .environment, envconfig.js, etc.
function isDotenvPath(filePath) {
  if (!filePath) return false;
  // Normalize to forward slashes and get basename
  const basename = filePath.replace(/\\/g, "/").split("/").pop();
  if (!basename) return false;
  // Exact .env
  if (basename === ".env") return true;
  // .env.xxx but not .envrc, .environment, etc.
  if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
  return false;
}

// For Bash commands: detect .env file references in the command string
function checkBashCommand(command) {
  if (!command) return false;

  // Skip echo/printf commands — they output text, not access files
  // Note: "echo foo && cat .env" is still caught by deny rule Bash(*.env*)
  const trimmed = command.trimStart();
  if (/^(?:echo|printf)\s/.test(trimmed)) return false;

  // Strip git commit -m message arguments — text, not file access
  let sanitized = command;
  sanitized = sanitized.replace(/\bgit\s+commit\b[^;|&]*/, (match) =>
    match.replace(
      /-m\s+(?:"(?:[^"\\]|\\.)*"|'[^']*'|\$'(?:[^'\\]|\\.)*'|\$\([^)]*\))\s*/g,
      ""
    )
  );

  // Match .env file references in the command
  // Lookbehind: path separator, whitespace, quote, =, <, >, (, or start of string
  // The .env part: optional path prefix, then .env optionally followed by .<suffix>
  // Lookahead: whitespace, quote, pipe, semicolon, ), >, &, or end of string
  const envPattern = /(?:^|[\s/"'=<>|;(])(\/?(?:[\w./-]*\/)?\.env(?:\.[a-zA-Z0-9_]+)?)(?=[\s"'|;)<>&]|$)/g;

  const matches = [];
  let m;
  while ((m = envPattern.exec(sanitized)) !== null) {
    matches.push(m[1].trim());
  }

  if (matches.length === 0) return false;

  // If any match is unsafe, block
  return matches.some((match) => {
    const basename = match.replace(/\\/g, "/").split("/").pop();
    if (basename === ".env") return true;
    if (basename.startsWith(".env.")) return !isSafeDotenv(basename);
    return false;
  });
}

// For Glob patterns: detect .env search patterns
function checkGlobPattern(pattern) {
  if (!pattern) return false;
  const basename = pattern.replace(/\\/g, "/").split("/").pop();
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

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Bash":
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

  default:
    break;
}

approve();
