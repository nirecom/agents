#!/usr/bin/env node
// Safely delete an orphan dir under the worktree base left by `git worktree remove` (worktree-end
// WE-12), in place of the blocked `rm -rf`. Usage: [--repo <dir>] [--force-if-not-registered
// [--expect-main-root <main>]] <path>. Default: an empty dir only (rmdir). Force: recursive, when no `.git` sits anywhere
// in the subtree (scan capped at MAX_GIT_SCAN_ENTRIES), and only with a resolvable repo. Gitlink path (#322 / #2875): a target whose
// `.git` is a gitlink file goes only in force mode with --expect-main-root, as an unregistered
// leftover of that main checkout (cleanup-orphan-dir/leftover.js): uncapped walk, nested `.git` or
// unreadable subdir refused, links never followed. Every other check fails closed with exit 1 and a
// `cleanup-orphan-dir: ` line; the steps are numbered in main(). ENOENT is idempotent success.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

try { require("./lib/load-env").loadDefaultEnv(); } catch (e) { /* fail-open */ }

const { normalizeCwd } = require("./lib/path-normalize");
const { resolveWorktreeBase, explicitWorktreeBase } = require("./lib/worktree-base");
const { leftoverRefusal, subtreeRefusal } = require("./cleanup-orphan-dir/leftover");

function isGitlinkFile(p) {
  try {
    return fs.lstatSync(p).isFile();
  } catch (e) {
    return false;
  }
}

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

// Repo precedence: --repo > --expect-main-root > CWD. Only an unresolvable non---repo candidate
// may fall back to an explicit WORKTREE_BASE_DIR; there this checkout answers Step 6, not the repo
// owning the target, so main() limits the fallback to the empty-dir rmdir.
function resolveScope(repoArg, expectMainRoot) {
  const r = resolveWorktreeBase(path.resolve(repoArg || expectMainRoot || process.cwd()));
  if (r.ok) return { base: path.resolve(r.base), registryRepo: r.mainDir, fallback: false };
  const explicit = repoArg ? null : explicitWorktreeBase();
  if (explicit === null) refuse(`cannot resolve the worktree base: ${r.reason}`);
  return { base: explicit, registryRepo: path.dirname(__dirname), fallback: true };
}

function main(argv) {
  // 1. Parse args: optional --force-if-not-registered + exactly one positional.
  let forceIfNotRegistered = false;
  let expectMainRoot = null;
  let repoArg = null;
  const positionals = [];
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--force-if-not-registered") {
      forceIfNotRegistered = true;
    } else if (a === "--expect-main-root" || a === "--repo") {
      const v = args[++i];
      if (typeof v !== "string" || v === "" || v.startsWith("-")) refuse(`${a} requires a path value`);
      if (a === "--repo") repoArg = normalizeCwd(v) || v;
      else expectMainRoot = normalizeCwd(v) || v;
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

  // 2. Worktree base and the repo whose registry Step 6 asks (hooks/lib/worktree-base.js).
  const { base, registryRepo, fallback } = resolveScope(repoArg, expectMainRoot);
  if (fallback && forceIfNotRegistered) {
    refuse("--force-if-not-registered needs a resolvable repo (--repo, --expect-main-root, or a repo CWD); the explicit-base fallback allows only an empty-dir rmdir");
  }

  // 3. Floor check: ≥ 3 path segments from root (C:\a\b, /var/wt/x).
  const baseSegments = base.split(/[\\/]/).filter(Boolean);
  if (baseSegments.length < 3) {
    refuse(`worktree base too shallow (< 3 segments): ${base}`);
  }

  // 4. Resolve target and verify strict containment under base.
  let resolved;
  try {
    resolved = path.resolve(normalizeCwd(input) || input);
  } catch (e) {
    refuse(`cannot resolve target path: ${e.message}`);
  }

  const rel = path.relative(base, resolved);
  if (rel === "") refuse(`target equals the worktree base: ${resolved}`);
  // Segment-aware: a child named "..x" stays inside the base.
  if (rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) {
    refuse(`target is outside the worktree base ${base}: ${resolved}`);
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

  // 6. Registered worktree check via the target repo's main root.
  const wtRes = spawnSync(
    "git", ["-C", registryRepo, "worktree", "list", "--porcelain"],
    { encoding: "utf8", timeout: 5000, windowsHide: true }
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
  //    (force mode). A gitlink file passes only on the proven-leftover path.
  const gitlinkLeftover = isGitlinkFile(path.join(resolved, ".git"));
  if (gitlinkLeftover && forceIfNotRegistered && expectMainRoot !== null) {
    const why = leftoverRefusal(resolved, expectMainRoot) || subtreeRefusal(resolved);
    if (why) refuse(why);
  } else if (fs.existsSync(path.join(resolved, ".git"))) {
    refuse(`target contains a .git entry: ${resolved}`);
  }
  if (forceIfNotRegistered && !gitlinkLeftover) {
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
