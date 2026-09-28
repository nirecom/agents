"use strict";
// Small JSON sidecars next to the handoff artifact (#2430): the nudge baseline,
// the flush mark and the risk stamp. Each file has exactly one writer; this
// module only owns the path rule and the tmp + rename write, never the contents.

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { SESSION_ID_VALID_RE } = require("../workflow-state/state-io/core");

// <PLANS_DIR>/<sid>-<suffix>, or null for an invalid sid (path-traversal guard).
function sidecarPath(sid, suffix) {
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return null;
  return path.join(getWorkflowPlansDir(), sid + "-" + suffix);
}

// Parsed object, or null when absent / unreadable / not an object. Never throws.
function readSidecar(sid, suffix) {
  try {
    const p = sidecarPath(sid, suffix);
    if (p === null) return null;
    const v = JSON.parse(fs.readFileSync(p, "utf8"));
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch (_e) {
    return null;
  }
}

// true on success. Never throws; a failed write leaves no tmp file behind.
function writeSidecar(sid, suffix, obj) {
  let p;
  try {
    p = sidecarPath(sid, suffix);
    if (p === null) return false;
  } catch (_e) {
    return false;
  }
  const tmpPath = `${p}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(tmpPath, JSON.stringify(obj), "utf8");
    fs.renameSync(tmpPath, p);
    return true;
  } catch (_e) {
    try {
      fs.unlinkSync(tmpPath);
    } catch (_e2) {
      /* nothing to clean up */
    }
    return false;
  }
}

// Epoch ms from a number, a Date or an ISO string; null when unparseable.
function toMillis(value) {
  if (value === undefined || value === null) return null;
  if (value instanceof Date) return value.getTime();
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  const parsed = Date.parse(String(value));
  return Number.isNaN(parsed) ? null : parsed;
}

module.exports = { sidecarPath, readSidecar, writeSidecar, toMillis };
