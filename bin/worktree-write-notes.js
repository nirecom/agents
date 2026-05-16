#!/usr/bin/env node
// Generate WORKTREE_NOTES.md and register it in <mainRoot>/.git/info/exclude.
//
// Usage:
//   COPIED_JSON='<step-9-stdout>' node bin/worktree-write-notes.js \
//     <mainRoot> <worktreePath> <branch> [<baseDir>]
//
// COPIED_JSON: full stdout JSON from worktree-copy-include.js (we read .copied).
//              Empty / unset → treated as []. Invalid JSON → exit 1.
// baseDir argv[5]: optional. Empty string or missing → process.env.WORKTREE_BASE_DIR || null.

"use strict";

const fs = require("fs");
const lib = require("../hooks/lib/worktree-notes");

function die(msg) {
  process.stderr.write(msg + "\n");
  process.exit(1);
}

function normalizePath(p) {
  return String(p).replace(/\\/g, "/");
}

const [, , mainRootRaw, worktreePathRaw, branch, baseDirRaw] = process.argv;

if (!mainRootRaw || !worktreePathRaw || !branch) {
  die("Usage: worktree-write-notes.js <mainRoot> <worktreePath> <branch> [<baseDir>]");
}

const copiedRaw = process.env.COPIED_JSON || "";
let copiedFiles = [];
if (copiedRaw.trim().length > 0) {
  let parsed;
  try {
    parsed = JSON.parse(copiedRaw);
  } catch (e) {
    die(`Invalid JSON in COPIED_JSON: ${e.message}`);
  }
  if (parsed && Array.isArray(parsed.copied)) {
    copiedFiles = parsed.copied;
  } else if (Array.isArray(parsed)) {
    copiedFiles = parsed;
  }
}

const mainRoot = normalizePath(mainRootRaw);
const worktreePath = normalizePath(worktreePathRaw);
const baseDir =
  baseDirRaw && baseDirRaw.length > 0
    ? baseDirRaw
    : process.env.WORKTREE_BASE_DIR || null;

let result;
try {
  result = lib.run({
    mainRoot,
    worktreePath,
    branch,
    createdDate: new Date().toISOString().slice(0, 10),
    resolvedPath: worktreePath,
    baseDir,
    copiedFiles,
    excludePattern: "WORKTREE_NOTES.md",
  });
} catch (e) {
  die(`Unexpected error: ${e.message}`);
}

process.stdout.write(JSON.stringify(result) + "\n");

if (!result.notesWritten) {
  for (const err of result.errors) process.stderr.write(err + "\n");
  process.exit(1);
}
process.exit(0);
