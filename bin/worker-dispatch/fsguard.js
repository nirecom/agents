"use strict";
// bin/worker-dispatch/fsguard.js
//
// Write containment. Capability validation proves an *input* path is anchored;
// this module proves an *output* path is one the worker was ever allowed to
// touch. The two are not the same question — a worker can be handed a legal
// family worktree and still have no business writing into it.
//
// Every write scope resolves to a concrete anchor at call time. A worker whose
// registry entry declares an empty writeScopes set (test-runner) can never write
// through this module. Note the exact scope of that guarantee: it covers writes
// the DISPATCHER performs. A child process fsguard spawned — `bash`, `uv`, `git`
// — writes where its own arguments take it, and this module never sees those.
//
// Artifact bytes are also redacted here. Worker output reaches a Claude Code
// transcript by two routes, stdout and the artifact file the calling skill reads
// back; emit.js closes the first, and a third-party string (a GitHub issue title,
// a branch name) travelling the second would otherwise arrive unfiltered.

const fs = require("fs");
const path = require("path");

const registryData = require("../../hooks/lib/worker-dispatch-registry");
const { realAbs, isUnder } = require("./anchor");
const { redactSentinels } = require("./emit");

// scope token -> the anchored roots it expands to for this invocation
const SCOPE_ROOTS = {
  "plans-dir": (ctx) => (ctx.plansDir ? [ctx.plansDir] : []),
  "family-worktree": (ctx) => (Array.isArray(ctx.family) ? ctx.family.slice() : []),
  "backup-dir": (ctx) => (ctx.backupDir ? [ctx.backupDir] : []),
  "main-root-docs": (ctx) => (ctx.mainRoot ? [path.join(ctx.mainRoot, "docs")] : []),
};

function scopeRootsFor(workerName, ctx) {
  const entry = registryData.workers[workerName];
  if (!entry) throw new Error(`unknown worker '${workerName}'`);
  const scopes = Array.isArray(entry.writeScopes) ? entry.writeScopes : [];
  const roots = [];
  for (const scope of scopes) {
    const resolver = SCOPE_ROOTS[scope];
    if (!resolver) throw new Error(`worker '${workerName}' declares an unknown write scope '${scope}'`);
    for (const root of resolver(ctx || {})) {
      if (root) roots.push(root);
    }
  }
  return roots;
}

// Returns true when the write is permitted; throws otherwise. Never returns false
// silently — a denied write must be loud enough to abort the worker.
function assertWritable(workerName, targetPath, ctx) {
  const abs = realAbs(targetPath);
  if (abs === null) throw new Error("write target must be an absolute path");

  const entry = registryData.workers[workerName];
  if (!entry) throw new Error(`unknown worker '${workerName}'`);
  const scopes = Array.isArray(entry.writeScopes) ? entry.writeScopes : [];
  if (scopes.length === 0) {
    throw new Error(`worker '${workerName}' declares no write scope and may not write`);
  }

  const roots = scopeRootsFor(workerName, ctx);
  if (roots.length === 0) {
    throw new Error(`no write scope of worker '${workerName}' could be anchored for this invocation`);
  }
  const permitted = roots.some((root) => isUnder(abs, root, false));
  if (!permitted) {
    throw new Error(`write target is outside every declared write scope of '${workerName}'`);
  }
  return true;
}

function writeFile(workerName, targetPath, data, ctx) {
  assertWritable(workerName, targetPath, ctx);
  const abs = realAbs(targetPath);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, typeof data === "string" ? redactSentinels(data) : data);
  return abs;
}

// Atomic publish: rename a fully-written `.tmp` file onto its final name.
// A reader of the final path therefore never observes a half-written state file
// — the property the multi-pass finalize chain depends on between passes.
//
// BOTH paths are checked, and against the SAME root rather than merely against
// the same scope set: a rename is a write to the destination and an unlink at the
// source, and `fs.renameSync` across two roots (plans-dir -> family-worktree) is
// not atomic on any platform even when both are individually writable.
function renameWithin(workerName, tmpPath, dstPath, ctx) {
  const absTmp = realAbs(tmpPath);
  const absDst = realAbs(dstPath);
  if (absTmp === null || absDst === null) {
    throw new Error("rename source and destination must both be absolute paths");
  }
  // Reuse the single scope-check path rather than re-resolving roots here: both
  // ends get the identical treatment every other write gets (CPR-SSOT).
  assertWritable(workerName, absTmp, ctx);
  assertWritable(workerName, absDst, ctx);

  const roots = scopeRootsFor(workerName, ctx);
  const shared = roots.some((root) => isUnder(absTmp, root, false) && isUnder(absDst, root, false));
  if (!shared) {
    throw new Error(
      `rename source and destination are not inside the same write scope of '${workerName}'`,
    );
  }
  fs.mkdirSync(path.dirname(absDst), { recursive: true });
  fs.renameSync(absTmp, absDst);
  return absDst;
}

function mkdir(workerName, targetPath, ctx) {
  assertWritable(workerName, targetPath, ctx);
  const abs = realAbs(targetPath);
  fs.mkdirSync(abs, { recursive: true });
  return abs;
}

module.exports = { assertWritable, writeFile, mkdir, renameWithin, scopeRootsFor };
