"use strict";
// Per-turn marker files for confirm-plan Stop hook coordination.
// show-plan-link.js (PostToolUse) writes a marker for every final plan artifact, just before
// emitting the breadcrumb. stop-confirm-plan-guard.js (Stop) reads and deletes the session's
// markers, then checks that the turn's response text shows each marked plan's plan-link line.
// The one other remover is confirm-checkpoint's receipt recovery (#2936): it spends only the
// markers a killed Stop left, those created before the next turn opened.
// File naming: <workflowDir>/<sid>.confirm-plan-turn-<rand>.json — the `<sid>.confirm-plan-turn-*`
// prefix lets every consumer discover them.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { getSessionStateDir } = require("../workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function writeTurnMarker(sessionId, payload) {
  if (typeof sessionId !== "string" || !SID_RE.test(sessionId)) {
    throw new Error(`writeTurnMarker: invalid session id: ${sessionId}`);
  }
  const dir = getSessionStateDir(sessionId);
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
  const dir = getSessionStateDir(sessionId);
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
// Safe to call from PreToolUse.
function peekTurnMarkers(sessionId) {
  if (typeof sessionId !== "string" || !SID_RE.test(sessionId)) return [];
  const dir = getSessionStateDir(sessionId);
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

// consumeTurnMarkersBefore(sessionId, iso): unlinks the markers whose created_at is before iso.
// A marker with a missing or unparsable created_at stays for the next Stop; never throws.
function consumeTurnMarkersBefore(sessionId, iso) {
  if (typeof sessionId !== "string" || !SID_RE.test(sessionId)) return;
  const limit = Date.parse(iso);
  if (Number.isNaN(limit)) return;
  let dir;
  let entries;
  try {
    dir = getSessionStateDir(sessionId);
    entries = fs.readdirSync(dir);
  } catch (_) {
    return;
  }
  const prefix = `${sessionId}.confirm-plan-turn-`;
  for (const name of entries) {
    if (!name.startsWith(prefix) || !name.endsWith(".json")) continue;
    const full = path.join(dir, name);
    try {
      const created = Date.parse(JSON.parse(fs.readFileSync(full, "utf8")).created_at);
      if (created < limit) fs.unlinkSync(full);
    } catch (_) { /* unreadable, malformed or not removable: left for the next Stop */ }
  }
}

module.exports = { writeTurnMarker, readAndDeleteTurnMarkers, peekTurnMarkers, consumeTurnMarkersBefore };
