"use strict";
// hooks/workflow-state/dispatch-settlement.js
// The one definition of dispatch order for workers that record an outcome (#2544).
// Order is the .dispatched marker mtime, ties broken by sequence; an unsequenced stem is seq "0".
// Every answer comes from which files exist in the session control dir, read as it
// stands: no command text, no state, and no legacy plans-dir payloads.
const fs = require("fs");
const path = require("path");
const { WORKER_NAMES, recordsOutcome } = require("../lib/worker-dispatch-registry");
const { outcomeFileName, ingestedMarkerName, payloadDigest } = require("../lib/worker-outcome-contract");
const { getSessionControlDir, assertRealControlDir } = require("./state-io/control-dir");

const DISPATCHED_SUFFIX = ".dispatched";

// Decimal strings, never Number: a 16-digit sequence exceeds the safe integer range.
function compareSeq(a, b) {
  const left = String(a);
  const right = String(b);
  if (left.length !== right.length) return left.length < right.length ? -1 : 1;
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

// { worker, seq } for a stem of an outcome-recording worker; null for anything else
// (another worker, a legacy-suffixed stem, a non-digit tail).
function parseStem(stem) {
  if (typeof stem !== "string") return null;
  for (const worker of WORKER_NAMES.filter(recordsOutcome)) {
    const base = `worker-${worker}`;
    if (stem === base) return { worker, seq: "0" };
    if (stem.startsWith(`${base}-`) && /^[0-9]+$/.test(stem.slice(base.length + 1))) {
      return { worker, seq: stem.slice(base.length + 1).replace(/^0+(?=[0-9])/, "") };
    }
  }
  return null;
}

function markerMtime(dir, name) {
  try {
    return fs.statSync(path.join(dir, name)).mtimeMs;
  } catch (_) {
    return 0;
  }
}

function latestIn(names, worker, dir) {
  let best = null;
  for (const name of names) {
    if (!name.endsWith(DISPATCHED_SUFFIX)) continue;
    const stem = name.slice(0, -DISPATCHED_SUFFIX.length);
    const parsed = parseStem(stem);
    if (parsed === null || parsed.worker !== worker) continue;
    const mtime = markerMtime(dir, name);
    const newer = best === null
      || mtime > best.mtime
      || (mtime === best.mtime && compareSeq(parsed.seq, best.seq) > 0);
    if (newer) best = { stem, seq: parsed.seq, mtime };
  }
  return best;
}

function latestDispatch({ sessionId, worker } = {}) {
  let dir;
  let names;
  try {
    dir = getSessionControlDir(sessionId);
    if (!assertRealControlDir(dir)) return null;
    names = fs.readdirSync(dir);
  } catch (_) {
    return null;
  }
  return latestIn(names, worker, dir);
}

const reasonOf = (what, e) => `${what}: ${e && e.message ? e.message : "unknown error"}`;

// The latest dispatch of each recording worker that has no .ingested beside it.
// A scan failure is reported with a reason so callers treat it as unsettled.
function listUnsettled({ sessionId } = {}) {
  let dir;
  let names;
  try {
    dir = getSessionControlDir(sessionId);
    if (!assertRealControlDir(dir)) return { unsettled: [] };
    names = fs.readdirSync(dir);
  } catch (e) {
    return { unsettled: [], reason: reasonOf("control dir scan failed", e) };
  }
  const present = new Set(names);
  const unsettled = [];
  for (const worker of WORKER_NAMES.filter(recordsOutcome)) {
    const latest = latestIn(names, worker, dir);
    if (latest !== null && !present.has(ingestedMarkerName(latest.stem))) {
      unsettled.push({ worker, stem: latest.stem, seq: latest.seq });
    }
  }
  return { unsettled };
}

// Whether the outcome a state entry was recorded from still stands as recorded:
// "match" (same bytes, ingested), "missing" (no outcome file) or "mismatch".
function outcomeSourceStatus({ sessionId, source } = {}) {
  if (source === null || typeof source !== "object" || typeof source.stem !== "string") return "missing";
  if (parseStem(source.stem) === null) return "mismatch";
  let dir;
  try {
    dir = getSessionControlDir(sessionId);
    if (!assertRealControlDir(dir)) return "missing";
  } catch (_) {
    return "mismatch";
  }
  let bytes;
  try {
    const p = path.join(dir, outcomeFileName(source.stem));
    if (!fs.lstatSync(p).isFile()) return "mismatch";
    bytes = fs.readFileSync(p);
  } catch (e) {
    return e && e.code === "ENOENT" ? "missing" : "mismatch";
  }
  if (payloadDigest(bytes) !== source.outcome_sha256) return "mismatch";
  return fs.existsSync(path.join(dir, ingestedMarkerName(source.stem))) ? "match" : "mismatch";
}

module.exports = { compareSeq, parseStem, latestDispatch, listUnsettled, outcomeSourceStatus };
