#!/usr/bin/env node
// hooks/cleanup-orphan-dir.js
//
// Safely delete an orphan directory left behind by `git worktree remove`.
// Replaces `rm -rf` / `Remove-Item -Recurse -Force` calls from worktree-end —
// those commands are blocked by enforce-worktree.js + settings.json deny rules.
//
// Usage:
//   node hooks/cleanup-orphan-dir.js <path>
//   node hooks/cleanup-orphan-dir.js --force-if-not-registered <path>
//
// Default mode requires the target to be empty. With
// `--force-if-not-registered`, a non-empty target is removed recursively as
// long as it contains no `.git` entry anywhere in its subtree and is not a
// registered worktree. This covers Windows CWD-lock cases where files were
// recreated under the worktree after `git worktree remove` succeeded.
//
// Validation pipeline (fail-fast — refuse with exit 1 unless noted):
//   1. Parse args: optional `--force-if-not-registered`, exactly one
//      positional path; any other flag → refuse.
//   2. WORKTREE_BASE_DIR env var must be set.
//   3. Base dir floor check: ≥ 3 path segments from root.
//   4. Resolution + strict containment under base (via path.relative).
//   5. lstat: ENOENT → exit 0 (idempotent); symlink/junction/reparse → refuse;
//      non-directory → refuse.
//   6. Registered worktree check via `git worktree list --porcelain` from this
//      script's own repo (__dirname/..); if resolved path is a registered
//      worktree → refuse.
//   7. No `.git` entry — immediate child (default mode) or anywhere in the
//      subtree (force mode). `.git` as file (gitlink) also refused.
//   8. Default mode only: empty (readdir length === 0); non-empty → refuse.
//   9. Delete: rmdirSync (default) or fs.rmSync({recursive:true, force:true})
//      under force mode.
//
// Failure modes (documented, intentional):
//   - TOCTOU between step 8 and 9: rmdirSync on non-empty dir throws → safe.
//   - TOCTOU between step 6 and 9: same risk as today's `rm -rf` workflow.
//   - Corrupted repo (worktree list fails) → refuse (fail-closed).
//   - Subtree exceeds MAX_GIT_SCAN_ENTRIES under force mode → refuse (fail-closed).

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { getWorktreeBaseDirResolved } = require("./enforce-worktree");

function refuse(msg, code) {
  process.stderr.write(`cleanup-orphan-dir: ${msg}\n`);
  process.exit(code || 1);
}

function ok(payload) {
  process.stdout.write(JSON.stringify(payload) + "\n");
  process.exit(0);
}

// Fail-closed cap on subtree scan under --force-if-not-registered.
// A typical orphan-dir contains at most a few stale files; legitimate use
// will not approach this cap. Exceeding it indicates either a misuse or an
// unexpectedly large tree — we refuse rather than potentially nuke it.
const MAX_GIT_SCAN_ENTRIES = 5000;

// Returns true if any entry named `.git` (file or dir) is found anywhere in
// the subtree rooted at `dir`. Returns null when the scan is aborted because
// the entry budget is exhausted — callers must treat null as fail-closed.
// Does NOT descend into symlinked directories (uses fs.lstat).
function containsAnyGitEntry(dir) {
  const stack = [dir];
  let visited = 0;
  while (stack.length > 0) {
    const cur = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(cur, { withFileTypes: true });
    } catch (e) {
      // Unreadable subdir → treat as suspect (fail-closed).
      return null;
    }
    for (const ent of entries) {
      if (++visited > MAX_GIT_SCAN_ENTRIES) return null;
      if (ent.name === ".git") return true;
      const sub = path.join(cur, ent.name);
      if (ent.isDirectory() && !ent.isSymbolicLink()) stack.push(sub);
    }
  }
  return false;
}

function main(argv) {
  // 1. Parse args: optional --force-if-not-registered + exactly one positional.
  let forceIfNotRegistered = false;
  const positionals = [];
  for (const a of argv.slice(2)) {
    if (a === "--force-if-not-registered") {
      forceIfNotRegistered = true;
    } else if (a.startsWith("-")) {
      refuse(`flags not accepted: ${a}`);
    } else {
      positionals.push(a);
    }
  }
  if (positionals.length !== 1) {
    refuse(`expected 1 positional path arg, got ${positionals.length}`);
  }
  const input = positionals[0];

  // 2. WORKTREE_BASE_DIR must be set.
  const baseRaw = getWorktreeBaseDirResolved();
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

  // 7. No `.git` entry — immediate child (always), or anywhere in subtree
  //    (force mode). `.git` as a file (gitlink) also counts.
  if (fs.existsSync(path.join(resolved, ".git"))) {
    refuse(`target contains a .git entry: ${resolved}`);
  }
  if (forceIfNotRegistered) {
    const hit = containsAnyGitEntry(resolved);
    if (hit === null) {
      refuse(`subtree scan exceeded ${MAX_GIT_SCAN_ENTRIES} entries or hit unreadable subdir: ${resolved}`);
    }
    if (hit) refuse(`target subtree contains a .git entry: ${resolved}`);
  }

  // 8. Default mode: target must be empty. Force mode: skip emptiness check.
  if (!forceIfNotRegistered) {
    let entries;
    try {
      entries = fs.readdirSync(resolved);
    } catch (e) {
      refuse(`readdir failed: ${e.message}`);
    }
    if (entries.length !== 0) {
      refuse(`target is not empty (${entries.length} entries): ${resolved}`);
    }
  }

  // 9. Delete: rmdirSync (default) or recursive rmSync (force mode).
  try {
    if (forceIfNotRegistered) {
      fs.rmSync(resolved, { recursive: true, force: true });
    } else {
      fs.rmdirSync(resolved);
    }
  } catch (e) {
    refuse(`${forceIfNotRegistered ? "rm" : "rmdir"} failed: ${e.message}`);
  }

  ok({ deleted: true, path: resolved, recursive: !!forceIfNotRegistered });
}

if (require.main === module) {
  main(process.argv);
}

module.exports = { main };
