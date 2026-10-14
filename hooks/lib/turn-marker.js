"use strict";
// Per-turn marker files for confirm-plan Stop hook coordination.
//
// show-plan-link.js (PostToolUse) writes a marker for every final plan
// artifact, just before emitting the breadcrumb. stop-confirm-plan-guard.js (Stop) reads
// and deletes any markers for the current session, then checks that the turn's response
// text shows each marked plan's plan-link line (URL, else the local path).
//
// File naming: <workflowDir>/<sid>.confirm-plan-turn-<rand>.json
// The glob is namespaced under `<sid>.confirm-plan-turn-*` so future readers
// can discover all consumers via that prefix.

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
// Safe to call from PreToolUse (Stop hook's read-and-delete remains the sole
// consumer that clears markers).
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

// #2650 continuation mark: the Stop hook's one-shot handoff to confirm-checkpoint.
const CONTINUE_STAGES = ["intent", "outline", "detail"];
const validSid = (sid) => typeof sid === "string" && SID_RE.test(sid);
const continuationMarkPath = (sid, stage) =>
  path.join(getSessionStateDir(sid), `${sid}.confirm-plan-continue-${stage}.json`);

function writeContinuationMark(sessionId, stage, fields) {
  if (!validSid(sessionId) || !CONTINUE_STAGES.includes(stage)) return false;
  const f = fields || {};
  const file = continuationMarkPath(sessionId, stage);
  const tmp = `${file}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  const body = {
    session_id: sessionId, stage, anchorUuid: f.anchorUuid, absPath: f.absPath,
    link: f.link, artifactSha: f.artifactSha, created_at: new Date().toISOString(),
  };
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(body), "utf8");
    fs.renameSync(tmp, file);
    return true;
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* tmp never written */ }
    return false;
  }
}

function removeMarkFile(file) {
  try { fs.unlinkSync(file); } catch (_) { /* absent, or not a regular file: leave it */ }
}

function takeContinuationMark(sessionId, stage) {
  if (!validSid(sessionId) || !CONTINUE_STAGES.includes(stage)) return { ok: false, reason: "absent" };
  const file = continuationMarkPath(sessionId, stage);
  if (!fs.existsSync(file)) return { ok: false, reason: "absent" };
  let raw = null;
  try { raw = fs.readFileSync(file, "utf8"); } catch (_) { raw = null; }
  removeMarkFile(file);
  if (raw === null) return { ok: false, reason: "unreadable" };
  let mark;
  try { mark = JSON.parse(raw); } catch (_) { return { ok: false, reason: "malformed" }; }
  const required = ["anchorUuid", "absPath", "link", "artifactSha"];
  if (!mark || typeof mark !== "object" || !required.every((k) => typeof mark[k] === "string")) {
    return { ok: false, reason: "malformed" };
  }
  return { ok: true, mark };
}

function clearContinuationMarks(sessionId) {
  if (!validSid(sessionId)) return;
  for (const stage of CONTINUE_STAGES) removeMarkFile(continuationMarkPath(sessionId, stage));
}

module.exports = {
  writeTurnMarker, readAndDeleteTurnMarkers, peekTurnMarkers,
  writeContinuationMark, takeContinuationMark, clearContinuationMarks,
};
