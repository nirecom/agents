"use strict";
// bin/worker-dispatch/payload.js — payload file location, loading and structural validation.
// The payload is a JSON *file* published by bin/worker-dispatch-payload into
// <workflowDir>/<sid>.control/worker-<w>[-<seq>].json, never inline argv: free text would
// otherwise have to survive the main-worktree guard's UNSAFE_ARG_VALUE_RE reject set.
// Loading is byte-preserving; typing and containment are capability.js's job.

const fs = require("fs");
const path = require("path");

const { absPath, samePath } = require("./anchor");
const { parsePlansEntry } = require("../../hooks/lib/plans-artifact-registry");

const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
const RE_SESSION_ID = /^[A-Za-z0-9_-]+$/;
const RE_CONTROL_PAYLOAD = /^worker-[a-z0-9]+(?:-[a-z0-9]+)*\.json$/;

// A session's control dir may sit under any state root (#2511), so every root is accepted.
function controlForm(abs, stateRoots) {
  if (!Array.isArray(stateRoots) || stateRoots.length === 0) return null;
  const parent = path.dirname(abs);
  const base = path.basename(abs);
  const m = /^(.+)\.control$/.exec(path.basename(parent));
  if (m === null || !stateRoots.some((r) => samePath(path.dirname(parent), r))) return null;
  const sid = m[1];
  if (!RE_SESSION_ID.test(sid)) throw new Error("payload control directory names a malformed session id");
  if (base.endsWith(".draft.json") || !RE_CONTROL_PAYLOAD.test(base)) {
    throw new Error("payload file name must be worker-<name>[-<seq>].json");
  }
  let st = null;
  try {
    st = fs.lstatSync(parent);
  } catch (_e) {
    throw new Error("payload control directory does not exist");
  }
  if (st.isSymbolicLink() || !st.isDirectory()) {
    throw new Error("payload control directory must be a real directory");
  }
  const stem = base.slice(0, -".json".length);
  return { sid, name: base, stem, legacy: false };
}

// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
// deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
// A payload published into PLANS_DIR before the pull is still read; only a <sid>-worker-*.json
// name yields a session (and so a .dispatched marker), any other *.json keeps the old contract.
// Its marker carries the file's mtime: PLANS_DIR is rewritable, so a rewrite is a new publish.
function legacyForm(abs, plansDir) {
  if (!plansDir || !samePath(path.dirname(abs), plansDir)) return null;
  const base = path.basename(abs);
  if (!base.endsWith(".json") || base.endsWith(".draft.json")) return null;
  const entry = parsePlansEntry(base);
  if (!entry || entry.kind !== "worker-payload" || !RE_SESSION_ID.test(entry.sid || "")) {
    return { sid: null, name: base, stem: null, legacy: true };
  }
  let mtime = "0";
  try { mtime = String(Math.trunc(fs.lstatSync(abs).mtimeMs)); } catch (_e) { /* loadPayload reports it */ }
  return { sid: entry.sid, name: entry.name, stem: `${entry.name.replace(/\.json$/, "")}.legacy-${mtime}`, legacy: true };
}
// --- END temporary: plans-dir control files -> workflow control dir migration ---

// Returns { abs, sid, name, stem, legacy }; throws when the path is not a publishable payload.
function locatePayload(file, opts) {
  const abs = absPath(file);
  if (abs === null) throw new Error("payload path must be an absolute path");
  const o = opts || {};
  const found = controlForm(abs, o.stateRoots) || legacyForm(abs, o.plansDir);
  if (found === null) throw new Error("payload file must live in the session control directory");
  return Object.assign({ abs }, found);
}

function loadPayload(file) {
  const abs = absPath(file);
  if (abs === null) throw new Error("payload path must be an absolute path");
  let stat = null;
  try {
    stat = fs.lstatSync(abs);
  } catch (_e) {
    throw new Error("payload file does not exist");
  }
  if (!stat.isFile()) throw new Error("payload path is not a regular file");
  if (stat.size > MAX_PAYLOAD_BYTES) throw new Error("payload file is too large");

  const raw = fs.readFileSync(abs, "utf8");
  try {
    return JSON.parse(raw);
  } catch (_e) {
    throw new Error("payload file is not valid JSON");
  }
}

// Structural gate only: shape of the document and the key set. Value typing is
// capability.js — a key that merely exists has proven nothing about what it may cause.
function validateStructure(payload, entry) {
  const errors = [];
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, errors: ["payload must be a JSON object"] };
  }
  const spec = entry && entry.payloadSpec ? entry.payloadSpec : {};
  for (const key of Object.keys(payload)) {
    if (!Object.prototype.hasOwnProperty.call(spec, key)) {
      errors.push(`unknown field '${key}'`);
    }
  }
  return { ok: errors.length === 0, errors };
}

module.exports = { locatePayload, loadPayload, validateStructure, MAX_PAYLOAD_BYTES };
