#!/usr/bin/env node
// CLI entry point for the .worktreeinclude copy mechanism.
//
// Input arrives one of two ways (argv takes precedence when --main-root present):
//   (1) argv flags: --main-root <p> --worktree-path <p> [--include-file <p>]
//   (2) JSON object on stdin (legacy): { mainRoot, worktreePath, includeFile }
// The argv form lets callers invoke the tool directly without constructing the
// input JSON inline (#1102 — removes a `node -e` from worktree-copy-worker.md).
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
    if (argv[i] === "--main-root") out.mainRoot = argv[++i];
    else if (argv[i] === "--worktree-path") out.worktreePath = argv[++i];
    else if (argv[i] === "--include-file") out.includeFile = argv[++i];
  }
  return out;
}

const argvInput = parseArgv(process.argv.slice(2));

let input;
if (argvInput.mainRoot !== undefined) {
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

if (!input.mainRoot || typeof input.mainRoot !== "string") {
  process.stderr.write("Missing or invalid 'mainRoot' field\n");
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

if (hasTraversal(input.mainRoot) || hasTraversal(input.worktreePath)) {
  process.stderr.write("Path traversal detected in mainRoot or worktreePath\n");
  process.exit(1);
}

if (input.includeFile && hasTraversal(input.includeFile)) {
  process.stderr.write("Path traversal detected in includeFile\n");
  process.exit(1);
}

const mainRoot = normalizePath(input.mainRoot);
const worktreePath = normalizePath(input.worktreePath);
const includeFile = input.includeFile ? normalizePath(input.includeFile) : null;

let result;
try {
  result = copyInclude({ mainRoot, worktreePath, includeFile });
} catch (e) {
  process.stderr.write(`Unexpected error: ${e.message}\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(result) + "\n");
