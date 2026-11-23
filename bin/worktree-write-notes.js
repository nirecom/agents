#!/usr/bin/env node
// Generate WORKTREE_NOTES.md and register it in <targetMainRoot>/.git/info/exclude. Usage:
//   COPIED_JSON='<json>' node bin/worktree-write-notes.js <targetMainRoot> <worktreePath> <branch> [<baseDir>] [<sessionId>]
// COPIED_JSON: worktree-copy-include.js stdout (.copied); empty → []; invalid JSON → exit 1.
// baseDir argv[5]: empty or missing → the resolver base (hooks/lib/worktree-base.js). sessionId
// argv[6]: empty or missing → no Session-ID line. A base inside the main repo is appended to its
// exclude; a failed append exits 1 unless git already ignores the base (then WARN, exit 0).

"use strict";

const { spawnSync } = require("child_process");
const lib = require("../hooks/lib/worktree-notes");
const { resolveWorktreeBase, explicitWorktreeBase, inRepoRelative } = require("../hooks/lib/worktree-base");

function die(msg) {
  process.stderr.write(msg + "\n");
  process.exit(1);
}

function normalizePath(p) {
  return String(p).replace(/\\/g, "/");
}

const [, , targetMainRootRaw, worktreePathRaw, branch, baseDirRaw, sessionIdRaw] = process.argv;

if (!targetMainRootRaw || !worktreePathRaw || !branch) {
  die("Usage: worktree-write-notes.js <targetMainRoot> <worktreePath> <branch> [<baseDir>] [<sessionId>]");
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

const siblingRaw = process.env.SIBLING_WORKTREES_JSON || "";
let siblingWorktrees = [];
if (siblingRaw.trim().length > 0) {
  try {
    const parsed = JSON.parse(siblingRaw);
    if (Array.isArray(parsed)) siblingWorktrees = parsed;
  } catch (_) {
    process.stderr.write("WARN: SIBLING_WORKTREES_JSON is not valid JSON; proceeding without sibling worktrees\n");
  }
}

const targetMainRoot = normalizePath(targetMainRootRaw);
const worktreePath = normalizePath(worktreePathRaw);
function resolverBase() {
  const r = resolveWorktreeBase(targetMainRoot);
  const base = r.ok ? r.base : explicitWorktreeBase();
  return base ? normalizePath(base) : null;
}
const baseDir = baseDirRaw && baseDirRaw.length > 0 ? baseDirRaw : resolverBase();
const baseRel = baseDir ? inRepoRelative(baseDir, targetMainRoot) : null;
const sessionId = sessionIdRaw && sessionIdRaw.length > 0 ? sessionIdRaw : null;

let result;
try {
  result = lib.run({
    targetMainRoot,
    worktreePath,
    branch,
    createdDate: new Date().toISOString().slice(0, 10),
    resolvedPath: worktreePath,
    baseDir,
    copiedFiles,
    excludePattern: "WORKTREE_NOTES.md",
    baseExcludePattern: baseRel ? `${baseRel}/` : null,
    sessionId,
    siblingWorktrees,
  });
} catch (e) {
  die(`Unexpected error: ${e.message}`);
}

process.stdout.write(JSON.stringify(result) + "\n");

if (!result.notesWritten) {
  for (const err of result.errors) process.stderr.write(err + "\n");
  process.exit(1);
}
if (result.baseExcludeError) {
  const ignored = spawnSync("git", ["-C", targetMainRoot, "check-ignore", "-q", `${baseRel}/`], { timeout: 10000, windowsHide: true }).status === 0;
  if (!ignored) {
    process.stderr.write(`base exclude append failed and git does not ignore ${baseRel}/: ${result.baseExcludeError}\n`);
    process.exit(1);
  }
  process.stderr.write(`WARN: base exclude append failed (${result.baseExcludeError}); ${baseRel}/ is already ignored\n`);
}
process.exit(0);
