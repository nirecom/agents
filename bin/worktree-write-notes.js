#!/usr/bin/env node
// CLI entry point for generating WORKTREE_NOTES.md and registering it in
// <mainRoot>/.git/info/exclude.
//
// Reads a JSON object from stdin:
//   {
//     mainRoot: string,
//     worktreePath: string,
//     branch: string,
//     createdDate?: string,        // YYYY-MM-DD; defaults to today
//     resolvedPath?: string,       // defaults to worktreePath
//     baseDir?: string|null,       // defaults to process.env.WORKTREE_BASE_DIR || null
//     copiedFiles: string[],       // relative paths (forward slashes)
//     excludePattern?: string      // defaults to "WORKTREE_NOTES.md"
//   }
//
// Writes a JSON object to stdout:
//   {
//     notesPath: string|null,
//     notesWritten: boolean,
//     excludePath: string|null,
//     excludeAdded: boolean,
//     excludeSkipReason: string|null,
//     errors: string[]
//   }
//
// Exit codes:
//   - 0 on success (notesWritten=true; appendExclude may soft-fail with errors[])
//   - 1 on bad input, traversal violation, internal error, or notesWritten=false
//
// IMPORTANT: `mainRoot` must point to the **main repository root** (directory
// containing `.git/` as a real directory). Passing a linked worktree's root
// (where `.git` is a file) will be rejected with an error.

"use strict";

const fs = require("fs");
const lib = require("../hooks/lib/worktree-notes");

const raw = fs.readFileSync(0, "utf8");

let input;
try {
  input = JSON.parse(raw);
} catch (e) {
  process.stderr.write(`Invalid JSON on stdin: ${e.message}\n`);
  process.exit(1);
}

if (!input || typeof input !== "object" || Array.isArray(input)) {
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

if (!input.branch || typeof input.branch !== "string") {
  process.stderr.write("Missing or invalid 'branch' field\n");
  process.exit(1);
}

if (!Array.isArray(input.copiedFiles)) {
  process.stderr.write("Missing or invalid 'copiedFiles' field (must be an array)\n");
  process.exit(1);
}

function normalizePath(p) {
  return String(p).replace(/\\/g, "/");
}

const mainRoot = normalizePath(input.mainRoot);
const worktreePath = normalizePath(input.worktreePath);
const resolvedPath = input.resolvedPath
  ? normalizePath(input.resolvedPath)
  : worktreePath;

const createdDate =
  typeof input.createdDate === "string" && input.createdDate.length > 0
    ? input.createdDate
    : new Date().toISOString().slice(0, 10);

let baseDir;
if (Object.prototype.hasOwnProperty.call(input, "baseDir")) {
  baseDir = input.baseDir;
} else {
  baseDir = process.env.WORKTREE_BASE_DIR || null;
}

const excludePattern =
  typeof input.excludePattern === "string" && input.excludePattern.length > 0
    ? input.excludePattern
    : "WORKTREE_NOTES.md";

let result;
try {
  result = lib.run({
    mainRoot,
    worktreePath,
    branch: input.branch,
    createdDate,
    resolvedPath,
    baseDir,
    copiedFiles: input.copiedFiles,
    excludePattern,
  });
} catch (e) {
  process.stderr.write(`Unexpected error: ${e.message}\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(result) + "\n");

if (!result.notesWritten) {
  for (const err of result.errors) {
    process.stderr.write(`${err}\n`);
  }
  process.exit(1);
}

process.exit(0);
