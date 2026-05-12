#!/usr/bin/env node
// hooks/cleanup-orphan-dir.js
//
// Safely delete an empty orphan directory left behind by `git worktree remove`.
// Replaces `rm -rf` / `Remove-Item -Recurse -Force` calls from worktree-end —
// those commands are blocked by enforce-worktree.js + settings.json deny rules.
//
// Usage: node hooks/cleanup-orphan-dir.js <path>
//
// Validation pipeline (fail-fast — refuse with exit 1 unless noted):
//   1. Exactly one positional arg; any flag → refuse.
//   2. WORKTREE_BASE_DIR env var must be set.
//   3. Base dir floor check: ≥ 3 path segments from root.
//   4. Resolution + strict containment under base (via path.relative).
//   5. lstat: ENOENT → exit 0 (idempotent); symlink/junction/reparse → refuse;
//      non-directory → refuse.
//   6. Registered worktree check via `git worktree list --porcelain` from this
//      script's own repo (__dirname/..); if resolved path is a registered
//      worktree → refuse.
//   7. No `.git` child (belt-and-suspenders).
//   8. Empty (readdir length === 0); non-empty → refuse.
//   9. fs.rmdirSync(resolved).
//
// Failure modes (documented, intentional):
//   - TOCTOU between step 8 and 9: rmdirSync on non-empty dir throws → safe.
//   - TOCTOU between step 6 and 9: same risk as today's `rm -rf` workflow.
//   - Corrupted repo (worktree list fails) → refuse (fail-closed).

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { getWorktreeBaseDir } = require("./enforce-worktree");

function refuse(msg, code) {
  process.stderr.write(`cleanup-orphan-dir: ${msg}\n`);
  process.exit(code || 1);
}

function ok(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
  process.exit(0);
}

function main(argv) {
  // 1. Args: exactly one positional, no flags.
  const args = argv.slice(2);
  if (args.length !== 1) refuse(`expected 1 positional path arg, got ${args.length}`);
  const input = args[0];
  if (input.startsWith("-")) refuse(`flags not accepted: ${input}`);

  // 2. WORKTREE_BASE_DIR must be set.
  const baseRaw = getWorktreeBaseDir();
  if (!baseRaw) refuse("WORKTREE_BASE_DIR is not set");

  let base;
  try {
    base = path.resolve(normalizeCwd(baseRaw) || baseRaw);
  } catch (e) {
    refuse(`cannot resolve WORKTREE_BASE_DIR: ${e.message}`);
  }

  // 3. Floor check: ≥ 3 path segments from root.
  // Windows: C:\a\b ✓ (segments: C:, a, b after normalization)
  // POSIX: /a/b/c ✓ (segments: a, b, c)
  const baseSegments = base.split(/[\\/]/).filter(Boolean);
  if (baseSegments.length < 3) {
    refuse(`WORKTREE_BASE_DIR too shallow (< 3 segments): ${base}`);
  }

  // 4. Resolve target and verify strict containment under base.
  let resolved;
  try {
    resolved = path.resolve(normalizeCwd(input) || input);
  } catch (e) {
    refuse(`cannot resolve target path: ${e.message}`);
  }

  const rel = path.relative(base, resolved);
  if (rel === "") refuse(`target equals WORKTREE_BASE_DIR: ${resolved}`);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    refuse(`target is outside WORKTREE_BASE_DIR: ${resolved}`);
  }

  // 5. lstat: idempotent on ENOENT, refuse on symlink/non-dir.
  let lstats;
  try {
    lstats = fs.lstatSync(resolved);
  } catch (e) {
    if (e.code === "ENOENT") ok({ alreadyAbsent: true, path: resolved });
    refuse(`lstat failed: ${e.message}`);
  }
  if (lstats.isSymbolicLink()) refuse(`target is a symlink: ${resolved}`);
  // Windows reparse-point bit (S_IFLNK on POSIX; junctions on Windows show
  // as symbolic-link-like via isSymbolicLink() in modern Node, but be defensive).
  const FILE_TYPE_MASK = 0o170000;
  const SYMLINK_TYPE = 0o120000;
  if ((lstats.mode & FILE_TYPE_MASK) === SYMLINK_TYPE) {
    refuse(`target is a symlink/reparse-point: ${resolved}`);
  }
  if (!lstats.isDirectory()) refuse(`target is not a directory: ${resolved}`);

  // 6. Registered worktree check via this script's own repo.
  //    Script lives at <repo>/hooks/cleanup-orphan-dir.js — repo is one level up.
  const scriptRepo = path.dirname(__dirname);
  const wtRes = spawnSync(
    "git", ["-C", scriptRepo, "worktree", "list", "--porcelain"],
    { encoding: "utf8", timeout: 5000 }
  );
  if (wtRes.status !== 0) {
    refuse(`git worktree list failed (status ${wtRes.status}): ${(wtRes.stderr || "").trim()}`);
  }
  const lines = (wtRes.stdout || "").split("\n");
  const registered = lines
    .filter((l) => l.startsWith("worktree "))
    .map((l) => l.slice("worktree ".length).trim())
    .map((p) => {
      try { return path.resolve(normalizeCwd(p) || p); } catch (e) { return null; }
    })
    .filter(Boolean);

  const cmpKey = (p) => process.platform === "win32" ? p.toLowerCase() : p;
  const resolvedKey = cmpKey(resolved);
  if (registered.some((r) => cmpKey(r) === resolvedKey)) {
    refuse(`target is a registered git worktree: ${resolved}`);
  }

  // 7. No `.git` child.
  if (fs.existsSync(path.join(resolved, ".git"))) {
    refuse(`target contains a .git entry: ${resolved}`);
  }

  // 8. Empty.
  let entries;
  try {
    entries = fs.readdirSync(resolved);
  } catch (e) {
    refuse(`readdir failed: ${e.message}`);
  }
  if (entries.length !== 0) {
    refuse(`target is not empty (${entries.length} entries): ${resolved}`);
  }

  // 9. Delete via rmdirSync (only removes empty dirs).
  try {
    fs.rmdirSync(resolved);
  } catch (e) {
    refuse(`rmdir failed: ${e.message}`);
  }

  ok({ deleted: true, path: resolved });
}

if (require.main === module) {
  main(process.argv);
}

module.exports = { main };
