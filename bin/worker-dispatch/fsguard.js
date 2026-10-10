"use strict";
// bin/worker-dispatch/fsguard.js — write containment. Capability validation proves an
// *input* path is anchored; this module proves an *output* path is one the worker may
// touch. Every scope resolves to a concrete anchor at call time; a worker with an empty
// writeScopes set can never write through here. The guarantee covers writes the
// DISPATCHER performs, not those of a child process it spawns (bash, uv, git).
// Control files never land in PLANS_DIR (docs/architecture/claude-code/state-dirs.md),
// and artifact bytes are redacted here because the artifact route reaches a transcript.

const fs = require("fs");
const path = require("path");

const registryData = require("../../hooks/lib/worker-dispatch-registry");
const { parsePlansEntry, CONTROL_KINDS } = require("../../hooks/lib/plans-artifact-registry");
const { outcomeFileName } = require("../../hooks/lib/worker-outcome-contract");
const { realAbs, isUnder, samePath } = require("./anchor");
const { redactSentinels } = require("./emit");

// scope token -> the anchored roots it expands to for this invocation
const SCOPE_ROOTS = {
  "plans-dir": (ctx) => (ctx.plansDir ? [ctx.plansDir] : []),
  "control-dir": (ctx) => (ctx.controlDir ? [ctx.controlDir] : []),
  "family-worktree": (ctx) => (Array.isArray(ctx.family) ? ctx.family.slice() : []),
  "backup-dir": (ctx) => (ctx.backupDir ? [ctx.backupDir] : []),
  "target-main-root-docs": (ctx) => (ctx.targetMainRoot ? [path.join(ctx.targetMainRoot, "docs")] : []),
  "log-dir": (ctx) => (ctx.logDir ? [ctx.logDir] : []),
};

// scope token -> the exact files it admits. Only the dispatcher's outcome context
// carries outcomeStem; a worker's writeCtx never does, so it anchors nothing (#2544).
const SCOPE_FILES = {
  "control-outcome": (ctx) =>
    (ctx.controlDir && ctx.outcomeStem ? [path.join(ctx.controlDir, outcomeFileName(ctx.outcomeStem))] : []),
};

const own = (table, scope) => Object.prototype.hasOwnProperty.call(table, scope);

function scopesOf(workerName) {
  const entry = registryData.workers[workerName];
  if (!entry) throw new Error(`unknown worker '${workerName}'`);
  const scopes = Array.isArray(entry.writeScopes) ? entry.writeScopes : [];
  for (const scope of scopes) {
    if (!own(SCOPE_ROOTS, scope) && !own(SCOPE_FILES, scope)) {
      throw new Error(`worker '${workerName}' declares an unknown write scope '${scope}'`);
    }
  }
  return scopes;
}

function expand(workerName, ctx, table) {
  const out = [];
  for (const scope of scopesOf(workerName)) {
    if (!own(table, scope)) continue;
    for (const p of table[scope](ctx || {})) {
      if (p) out.push(p);
    }
  }
  return out;
}

const scopeRootsFor = (workerName, ctx) => expand(workerName, ctx, SCOPE_ROOTS);
const scopeFilesFor = (workerName, ctx) => expand(workerName, ctx, SCOPE_FILES);

// A control-file name directly under PLANS_DIR, bare or sid-prefixed, is refused even
// though plans-dir is a declared scope: the artifacts directory holds prose only.
function isControlNameInPlans(abs, ctx) {
  const plansDir = ctx && ctx.plansDir ? ctx.plansDir : null;
  if (plansDir === null || !samePath(path.dirname(abs), plansDir)) return false;
  const base = path.basename(abs);
  if (CONTROL_KINDS.some((c) => c.re.test(base))) return true;
  const parsed = parsePlansEntry(base);
  return parsed !== null && (parsed.verdict === "control" || parsed.verdict === "ambiguous");
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
  const files = scopeFilesFor(workerName, ctx);
  if (roots.length === 0 && files.length === 0) {
    throw new Error(`no write scope of worker '${workerName}' could be anchored for this invocation`);
  }
  const permitted = roots.some((root) => isUnder(abs, root, false))
    || files.some((file) => samePath(abs, realAbs(file)));
  if (!permitted) {
    throw new Error(`write target is outside every declared write scope of '${workerName}'`);
  }
  if (isControlNameInPlans(abs, ctx)) {
    throw new Error("write target is a control file name inside the plans directory; control files live in the session control directory");
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

// Atomic publish: rename a fully-written `.tmp` onto its final name. BOTH ends are
// checked against the SAME root: a rename across two roots is not atomic on any platform.
function renameWithin(workerName, tmpPath, dstPath, ctx) {
  const absTmp = realAbs(tmpPath);
  const absDst = realAbs(dstPath);
  if (absTmp === null || absDst === null) {
    throw new Error("rename source and destination must both be absolute paths");
  }
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

// A directory lands only under a root: a file scope admits one file, never a directory.
function mkdir(workerName, targetPath, ctx) {
  assertWritable(workerName, targetPath, ctx);
  const abs = realAbs(targetPath);
  if (!scopeRootsFor(workerName, ctx).some((root) => isUnder(abs, root, false))) {
    throw new Error(`directory target is outside every directory write scope of '${workerName}'`);
  }
  fs.mkdirSync(abs, { recursive: true });
  return abs;
}

// One create, never an overwrite: `wx` fails on any existing entry, a symlink included.
function createExclusive(workerName, targetPath, data, ctx) {
  assertWritable(workerName, targetPath, ctx);
  const abs = realAbs(targetPath);
  let existing = null;
  try { existing = fs.lstatSync(abs); } catch (e) { if (e.code !== "ENOENT") throw e; }
  if (existing !== null) throw new Error("exclusive create target already exists");
  fs.writeFileSync(abs, typeof data === "string" ? redactSentinels(data) : data, { flag: "wx" });
  return abs;
}

module.exports = { assertWritable, writeFile, mkdir, renameWithin, createExclusive, scopeRootsFor, scopeFilesFor };
