#!/usr/bin/env node
// CLI entry point for the .worktreeinclude copy mechanism.
//
// Input arrives one of two ways (argv takes precedence when --target-main-root present):
//   (1) argv flags: --target-main-root <p> --worktree-path <p> [--include-file <p>]
//   (2) JSON object on stdin (legacy): { targetMainRoot, worktreePath, includeFile }
// The argv form lets callers invoke the tool directly without constructing the
// input JSON inline (#1102 — removed a `node -e` from the copy worker).
//
// Writes a JSON object to stdout:
//   { copied: string[], skipped: string[], denied: string[], errors: string[] }
//
// Exits non-zero on bad input. Path normalization (backslash → forward slash)
// is applied to all path fields to support Windows callers.

"use strict";

const fs = require("fs");
const path = require("path");
const { copyInclude } = require("../hooks/lib/worktree-copy");

function parseArgv(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--target-main-root") out.targetMainRoot = argv[++i];
    else if (argv[i] === "--worktree-path") out.worktreePath = argv[++i];
    else if (argv[i] === "--include-file") out.includeFile = argv[++i];
  }
  return out;
}

const argvInput = parseArgv(process.argv.slice(2));

let input;
if (argvInput.targetMainRoot !== undefined) {
  input = { includeFile: null, ...argvInput };
} else {
  const raw = fs.readFileSync(0, "utf8");
  try {
    input = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`Invalid JSON on stdin: ${e.message}\n`);
    process.exit(1);
  }
  if (!input || typeof input !== "object") {
    process.stderr.write("stdin must be a JSON object\n");
    process.exit(1);
  }
}

if (!input.targetMainRoot || typeof input.targetMainRoot !== "string") {
  process.stderr.write("Missing or invalid 'targetMainRoot' field\n");
  process.exit(1);
}

if (!input.worktreePath || typeof input.worktreePath !== "string") {
  process.stderr.write("Missing or invalid 'worktreePath' field\n");
  process.exit(1);
}

// Normalize paths: replace backslashes and check for traversal components
function normalizePath(p) {
  return p.replace(/\\/g, "/");
}

function hasTraversal(p) {
  return normalizePath(p).split("/").includes("..");
}

if (hasTraversal(input.targetMainRoot) || hasTraversal(input.worktreePath)) {
  process.stderr.write("Path traversal detected in targetMainRoot or worktreePath\n");
  process.exit(1);
}

if (input.includeFile && hasTraversal(input.includeFile)) {
  process.stderr.write("Path traversal detected in includeFile\n");
  process.exit(1);
}

const targetMainRoot = normalizePath(input.targetMainRoot);
const worktreePath = normalizePath(input.worktreePath);
const includeFile = input.includeFile ? normalizePath(input.includeFile) : null;

let result;
try {
  result = copyInclude({ targetMainRoot, worktreePath, includeFile });
} catch (e) {
  process.stderr.write(`Unexpected error: ${e.message}\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(result) + "\n");
