"use strict";
// bin/worker-dispatch/anchor.js
//
// Trust anchor derivation + the path canonicalization primitives every other
// dispatcher module shares.
//
// Four anchors, in derivation order:
//   ACD        this checkout of the agents repo, resolved from THIS module's own
//              realpath. The AGENTS_CONFIG_DIR env candidate is dropped on
//              purpose: env is attacker-reachable, a module path is not.
//   MAIN_ROOT  argv[3], accepted only if it is a *main* worktree (its
//              --git-common-dir parent is itself). Linked worktrees are rejected.
//   FAMILY     MAIN_ROOT plus every worktree git itself has registered for it.
//   PLANS_DIR  the workflow plans directory.
//
// This module never reads the process working directory and never asks git for a
// toplevel — the caller's location must not be able to influence any anchor.
// tests/feature-1643-worker-dispatch-anchor.sh asserts both by source scan.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const { normalizeCwd } = require("../../hooks/lib/path-normalize");
const { configDirCandidates, _resolveFromCandidates } = require("../../hooks/lib/agents-config-dir");
const { getWorkflowPlansDir } = require("../../hooks/lib/workflow-plans-dir");

const GIT_TIMEOUT_MS = 20000;
const REALPATH_MAX_DEPTH = 64;

// ---------------------------------------------------------------------------
// Path primitives
// ---------------------------------------------------------------------------

// Absolute-only canonical form. Relative input is REJECTED, never resolved —
// resolving it would silently reintroduce a caller-location dependency.
// normalizeCwd() applies the repo's Windows path convention (POSIX/msys form to
// drive-letter form) so every downstream fs.* and spawnSync call site agrees.
function absPath(input) {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (trimmed === "") return null;
  const normalized = normalizeCwd(trimmed) || trimmed;
  if (!path.isAbsolute(normalized)) return null;
  return path.normalize(normalized);
}

function stripTrailingSep(p) {
  let out = p;
  while (out.length > 1 && (out.endsWith(path.sep) || out.endsWith("/"))) {
    const next = out.slice(0, -1);
    if (/^[A-Za-z]:$/.test(next)) break;
    out = next;
  }
  return out;
}

// Case-insensitive comparison on Windows only.
function sameString(a, b) {
  if (process.platform === "win32") return a.toLowerCase() === b.toLowerCase();
  return a === b;
}

// Canonicalize symlinks as far up the chain as actually exists, then re-append
// the not-yet-existing tail. A plain fs.realpathSync would throw for a path that
// is about to be created, and skipping realpath entirely would let a symlinked
// leaf escape its declared anchor.
function realAbs(input) {
  const abs = absPath(input);
  if (abs === null) return null;
  const tail = [];
  let cur = abs;
  for (let i = 0; i < REALPATH_MAX_DEPTH; i += 1) {
    let real = null;
    try {
      real = fs.realpathSync(cur);
    } catch (_e) {
      real = null;
    }
    if (real !== null) return path.resolve(real, ...tail);
    const parent = path.dirname(cur);
    if (!parent || parent === cur) return abs;
    tail.unshift(path.basename(cur));
    cur = parent;
  }
  return abs;
}

function samePath(a, b) {
  const ra = realAbs(a);
  const rb = realAbs(b);
  if (ra === null || rb === null) return false;
  return sameString(stripTrailingSep(ra), stripTrailingSep(rb));
}

// Containment on separator boundaries, never a raw string prefix: `<plans>-evil`
// must not count as living under `<plans>`. Both sides are realpath-canonical, so
// `..` segments and symlink escapes are resolved before the comparison.
function isUnder(childInput, parentInput, allowEqual) {
  const child = realAbs(childInput);
  const parent = realAbs(parentInput);
  if (child === null || parent === null) return false;
  const c = stripTrailingSep(child);
  const p = stripTrailingSep(parent);
  if (sameString(c, p)) return allowEqual === true;
  const prefix = p + path.sep;
  if (process.platform === "win32") return c.toLowerCase().startsWith(prefix.toLowerCase());
  return c.startsWith(prefix);
}

// ---------------------------------------------------------------------------
// git probes (the only two git subcommands this dispatcher ever runs before a
// worker module takes over; the capability suite asserts nothing else appears)
// ---------------------------------------------------------------------------

function git(args, workDir) {
  const res = spawnSync("git", args, {
    cwd: workDir,
    shell: false,
    encoding: "utf8",
    timeout: GIT_TIMEOUT_MS,
    windowsHide: true,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (res.error || res.status !== 0) return null;
  return String(res.stdout === null || res.stdout === undefined ? "" : res.stdout).trim();
}

// ---------------------------------------------------------------------------
// Anchor derivation
// ---------------------------------------------------------------------------

function resolveAcd() {
  const candidates = configDirCandidates().filter((c) => c && c.source !== "env");
  const resolved = _resolveFromCandidates(candidates, { silent: true });
  if (!resolved) return null;
  return realAbs(resolved);
}

function resolveMainRoot(mainRootArg) {
  const abs = absPath(mainRootArg);
  if (abs === null) return { error: "main-root must be an absolute path" };
  let stat = null;
  try {
    stat = fs.statSync(abs);
  } catch (_e) {
    return { error: "main-root does not exist" };
  }
  if (!stat.isDirectory()) return { error: "main-root is not a directory" };

  const root = realAbs(abs);
  const commonDir = git(["-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"], root);
  if (commonDir === null) return { error: "main-root is not a git repository" };
  const commonAbs = absPath(commonDir);
  if (commonAbs === null) return { error: "main-root git common dir is not absolute" };
  const owner = realAbs(path.dirname(commonAbs));
  if (owner === null || !sameString(stripTrailingSep(owner), stripTrailingSep(root))) {
    return { error: "main-root is not a main worktree" };
  }
  return { value: root };
}

function resolveFamily(mainRoot) {
  const listing = git(["-C", mainRoot, "worktree", "list", "--porcelain"], mainRoot);
  if (listing === null) return null;
  const family = [];
  for (const line of listing.split(/\r?\n/)) {
    const m = /^worktree (.+)$/.exec(line);
    if (m === null) continue;
    const wt = realAbs(m[1]);
    if (wt === null) continue;
    if (!family.some((f) => sameString(f, wt))) family.push(wt);
  }
  if (!family.some((f) => sameString(f, mainRoot))) family.unshift(mainRoot);
  return family;
}

// Never throws: callers (including the anchor probe in the test suite) rely on
// getting a structured result back rather than an exception.
function resolveAnchors(mainRootArg) {
  const out = { acd: null, mainRoot: null, family: [], plansDir: null, error: null };

  out.acd = resolveAcd();
  if (out.acd === null) {
    out.error = "cannot resolve the agents config dir from this module's location";
    return out;
  }

  const main = resolveMainRoot(mainRootArg);
  if (main.error) {
    out.error = main.error;
    return out;
  }
  out.mainRoot = main.value;

  const family = resolveFamily(out.mainRoot);
  if (family === null) {
    out.error = "cannot enumerate the worktree family of main-root";
    return out;
  }
  out.family = family;

  let plans = null;
  try {
    plans = realAbs(getWorkflowPlansDir());
  } catch (_e) {
    plans = null;
  }
  if (plans === null) {
    out.error = "cannot resolve the workflow plans directory";
    return out;
  }
  out.plansDir = plans;

  return out;
}

module.exports = {
  resolveAnchors,
  absPath,
  realAbs,
  isUnder,
  samePath,
  sameString,
  stripTrailingSep,
};
