"use strict";
// Per-turn marker files for confirm-plan Stop hook coordination.
//
// show-plan-link.js (PostToolUse) writes a marker after emitting the
// breadcrumb when CONFIRM_<STEP>=on. stop-confirm-plan-guard.js (Stop) reads
// and deletes any markers for the current session, then scans the last
// assistant message for forbidden path representations.
//
// File naming: <workflowDir>/<sid>.confirm-plan-turn-<rand>.json
// The glob is namespaced under `<sid>.confirm-plan-turn-*` so future readers
// can discover all consumers via that prefix.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { getWorkflowDir } = require("./workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function writeTurnMarker(sessionId, payload) {
  if (typeof sessionId !== "string" || !SID_RE.test(sessionId)) {
    throw new Error(`writeTurnMarker: invalid session id: ${sessionId}`);
  }
  const dir = getWorkflowDir();
  try { fs.mkdirSync(dir, { recursive: true }); } catch (_) { /* fail-open */ }
  const rand = crypto.randomBytes(4).toString("hex");
  const filename = `${sessionId}.confirm-plan-turn-${rand}.json`;
  const filePath = path.join(dir, filename);
  const body = Object.assign({}, payload || {});
  if (!body.created_at) body.created_at = new Date().toISOString();
  fs.writeFileSync(filePath, JSON.stringify(body), "utf8");
  return filePath;
}

function readAndDeleteTurnMarkers(sessionId) {
  if (typeof sessionId !== "string" || !SID_RE.test(sessionId)) return [];
  const dir = getWorkflowDir();
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
  const prefix = `${sessionId}.confirm-plan-turn-`;
  const results = [];
  for (const name of entries) {
    if (!name.startsWith(prefix) || !name.endsWith(".json")) continue;
    const full = path.join(dir, name);
    let raw;
    try {
      raw = fs.readFileSync(full, "utf8");
    } catch (_) {
      continue;
    }
    try {
      fs.unlinkSync(full);
    } catch (_) {
      // Skip on unlink failure to avoid emitting a marker we cannot consume
      // exactly once.
      continue;
    }
    try {
      results.push(JSON.parse(raw));
    } catch (_) {
      // Skip malformed marker payloads silently.
      continue;
    }
  }
  return results;
}

// Non-destructive read: same scan as readAndDeleteTurnMarkers, no unlink.
// Safe to call from PreToolUse (Stop hook's read-and-delete remains the sole
// consumer that clears markers).
function peekTurnMarkers(sessionId) {
  if (typeof sessionId !== "string" || !SID_RE.test(sessionId)) return [];
  const dir = getWorkflowDir();
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
  const prefix = `${sessionId}.confirm-plan-turn-`;
  const results = [];
  for (const name of entries) {
    if (!name.startsWith(prefix) || !name.endsWith(".json")) continue;
    const full = path.join(dir, name);
    let raw;
    try {
      raw = fs.readFileSync(full, "utf8");
    } catch (_) {
      continue;
    }
    try {
      results.push(JSON.parse(raw));
    } catch (_) {
      continue;
    }
  }
  return results;
}

module.exports = { writeTurnMarker, readAndDeleteTurnMarkers, peekTurnMarkers };
