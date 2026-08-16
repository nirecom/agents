"use strict";
// SSOT for the NEXT_STEP_PAUSE marker — v2: scope + expiry + audit (#1624).
//
// A pause silences the workflow guards, so v1's "a file exists" contract had
// three gaps: it applied session-wide, it never expired, and it recorded
// nothing about who paused or why. See rules/stop-guard-exemptions.md.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { getWorkflowDir, VALID_STEPS } = require("../workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;
const SID_MAX_LEN = 128;
const MARKER_SUFFIX = ".next-step-paused";
const PAUSE_MARKER_VERSION = 2;

// Same 4 hours as the step-in-flight window: both answer "how long may one
// stretch of delegated work keep the guards quiet?".
const PAUSE_TTL_MS = 4 * 60 * 60 * 1000;
const SESSION_WIDE = "any";
const FOR_TAG_RE = /^\s*\[for=([A-Za-z0-9_]*)\]/;

// The session id becomes a filename, so it is validated before any path is
// built — never sanitized into something else. Rejection returns false and
// writes nothing at all, including no audit entry (#1624 F1).
function isSafeSid(sid) {
  return typeof sid === "string" && sid.length > 0 && sid.length <= SID_MAX_LEN && SID_RE.test(sid);
}

function markerPathFor(sid) {
  return path.join(getWorkflowDir(), sid + MARKER_SUFFIX);
}

// parseForStep(reason): the `[for=<step>]` prefix, or `any`. Every unreadable
// form WIDENS to session-wide — narrowing on a typo would silently un-pause the
// session the author meant to pause.
function parseForStep(reason) {
  if (typeof reason !== "string") return SESSION_WIDE;
  const m = FOR_TAG_RE.exec(reason);
  if (!m) return SESSION_WIDE;
  const tag = m[1];
  if (tag === SESSION_WIDE) return SESSION_WIDE;
  if (VALID_STEPS.indexOf(tag) === -1) return SESSION_WIDE;
  return tag;
}

function writeAtomic(targetPath, text) {
  const tmpPath = targetPath + "." + process.pid + ".tmp";
  try {
    // flag "wx" (O_CREAT|O_EXCL): symlink at predictable tmp path fails with EEXIST
    try {
      fs.writeFileSync(tmpPath, text, { encoding: "utf8", flag: "wx", mode: 0o600 });
    } catch (e) {
      if (e && e.code === "EEXIST") {
        fs.unlinkSync(tmpPath);
        fs.writeFileSync(tmpPath, text, { encoding: "utf8", flag: "wx", mode: 0o600 });
      } else { throw e; }
    }
    fs.renameSync(tmpPath, targetPath);
    return true;
  } catch (_e) {
    try { fs.unlinkSync(tmpPath); } catch (_u) {}
    return false;
  }
}

// The session-history half of the audit trail. The marker answers "what is
// suppressing me right now"; the resume deletes it, so the findings log is the
// only record that survives. Fail-open — a pause is never blocked by it.
function recordPauseAudit(sid, audit) {
  try {
    const { appendFinding } = require("./supervisor-state-writer");
    appendFinding(sid, {
      categories: ["workflow"],
      severity: "notice",
      detail:
        "NEXT_STEP_PAUSE set (marker: next-step-paused, for_step=" + audit.for_step +
        ", expires in " + Math.round(PAUSE_TTL_MS / 60000) + "min): " + audit.reason,
      reporter: "next-step-pause",
    });
  } catch (_e) {}
}

// writePauseMarker(sid, opts): write the v2 marker. Returns the marker object,
// or false when the session id is rejected or the write fails.
function writePauseMarker(sid, opts) {
  try {
    if (!isSafeSid(sid)) return false;
    const reason = opts && typeof opts.reason === "string" ? opts.reason : "";
    const sentinel =
      opts && typeof opts.sentinel === "string" && opts.sentinel
        ? opts.sentinel
        : "WORKFLOW_NEXT_STEP_PAUSE";
    const forStep = parseForStep(reason);
    const setAt = new Date();
    const audit = {
      sentinel,
      session_id: sid,
      set_at: setAt.toISOString(),
      for_step: forStep,
      reason,
      host: os.hostname ? String(os.hostname()) : "",
    };
    const marker = {
      version: PAUSE_MARKER_VERSION,
      reason,
      for_step: forStep,
      set_at: audit.set_at,
      expires_at: new Date(setAt.getTime() + PAUSE_TTL_MS).toISOString(),
      audit,
    };
    const target = markerPathFor(sid);
    try { fs.mkdirSync(path.dirname(target), { recursive: true }); } catch (_e) {}
    if (!writeAtomic(target, JSON.stringify(marker, null, 2) + "\n")) return false;
    recordPauseAudit(sid, audit);
    return marker;
  } catch (_e) {
    return false;
  }
}

// readPauseMarker(sid): the parsed marker, or null. Total — a malformed file
// reads as null and is left on disk untouched (it is the only evidence).
function readPauseMarker(sid) {
  try {
    if (!isSafeSid(sid)) return null;
    const parsed = JSON.parse(fs.readFileSync(markerPathFor(sid), "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed;
  } catch (_e) {
    return null;
  }
}

// isPauseActive(sid, currentStep): fail-CLOSED. A marker that cannot prove it is
// unexpired, or whose scope does not cover `currentStep`, is not active.
function isPauseActive(sid, currentStep) {
  try {
    const marker = readPauseMarker(sid);
    if (!marker) return false;
    if (typeof marker.expires_at !== "string" || !marker.expires_at) return false;
    const expiresAt = Date.parse(marker.expires_at);
    if (Number.isNaN(expiresAt)) return false;
    if (Date.now() >= expiresAt) return false;
    const scope =
      typeof marker.for_step === "string" && marker.for_step ? marker.for_step : SESSION_WIDE;
    if (scope === SESSION_WIDE) return true;
    return typeof currentStep === "string" && currentStep === scope;
  } catch (_e) {
    return false;
  }
}

// removePauseMarker(sid): delete the marker and any half-written tmp. An
// already-absent marker is a clean no-op. Returns true unless the id is unsafe.
function removePauseMarker(sid) {
  if (!isSafeSid(sid)) return false;
  try {
    const target = markerPathFor(sid);
    try { fs.unlinkSync(target); } catch (e) { if (!e || e.code !== "ENOENT") throw e; }
    try { fs.unlinkSync(target + ".tmp"); } catch (_e) {}
    return true;
  } catch (_e) {
    return false;
  }
}

module.exports = {
  PAUSE_MARKER_VERSION,
  PAUSE_TTL_MS,
  SESSION_WIDE,
  MARKER_SUFFIX,
  isSafeSid,
  markerPathFor,
  parseForStep,
  writePauseMarker,
  readPauseMarker,
  isPauseActive,
  removePauseMarker,
};
