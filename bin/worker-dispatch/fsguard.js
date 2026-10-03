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
const { realAbs, isUnder, samePath } = require("./anchor");
const { redactSentinels } = require("./emit");

// scope token -> the anchored roots it expands to for this invocation
const SCOPE_ROOTS = {
  "plans-dir": (ctx) => (ctx.plansDir ? [ctx.plansDir] : []),
  "control-dir": (ctx) => (ctx.controlDir ? [ctx.controlDir] : []),
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
  if (roots.length === 0) {
    throw new Error(`no write scope of worker '${workerName}' could be anchored for this invocation`);
  }
  const permitted = roots.some((root) => isUnder(abs, root, false));
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

function mkdir(workerName, targetPath, ctx) {
  assertWritable(workerName, targetPath, ctx);
  const abs = realAbs(targetPath);
  fs.mkdirSync(abs, { recursive: true });
  return abs;
}

module.exports = { assertWritable, writeFile, mkdir, renameWithin, scopeRootsFor };
