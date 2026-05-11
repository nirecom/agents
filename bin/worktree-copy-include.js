#!/usr/bin/env node
// CLI entry point for the .worktreeinclude copy mechanism.
//
// Reads a JSON object from stdin:
//   { mainRoot: string, worktreePath: string, includeFile: string|null }
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

const raw = fs.readFileSync(0, "utf8");

let input;
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
