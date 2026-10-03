"use strict";
// Temporary (#2434): deleted with this folder per the deletion-condition in control-dir.js.
// Which PLANS_DIR entries move: registered MIGRATABLE_KINDS only, regular files only.
const fs = require("fs");
const path = require("path");
const { MIGRATABLE_KINDS, parsePlansEntry } = require("../../plans-artifact-registry");

const MIGRATABLE = new Set(MIGRATABLE_KINDS.map((k) => k.kind));
const NEVER_MOVE_RE = /(?:\.lock|\.tmp)$|\.migrating\.|^\.sg-|^\.prev-/;

function classify(dirent) {
  if (!dirent.isFile() || NEVER_MOVE_RE.test(dirent.name)) return null;
  const parsed = parsePlansEntry(dirent.name);
  if (!parsed || parsed.verdict !== "control" || !MIGRATABLE.has(parsed.kind)) return null;
  return parsed;
}

function readEntries(plansDir) {
  try {
    return fs.readdirSync(plansDir, { withFileTypes: true });
  } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
}

// One sid only: an exact remainder match keeps <uuid>-b1-* out of <uuid>'s batch.
function listSessionEntries(sid, plansDir) {
  const prefix = `${sid}-`;
  const out = [];
  for (const d of readEntries(plansDir)) {
    if (!d.name.startsWith(prefix)) continue;
    const parsed = classify(d);
    if (parsed && parsed.sid === sid) out.push({ name: parsed.name, src: path.join(plansDir, d.name), kind: parsed.kind });
  }
  return out;
}

function groupAllSessions(entries, plansDir) {
  const groups = new Map();
  for (const d of entries) {
    const parsed = classify(d);
    if (!parsed) continue;
    if (!groups.has(parsed.sid)) groups.set(parsed.sid, []);
    groups.get(parsed.sid).push({ name: parsed.name, src: path.join(plansDir, d.name), kind: parsed.kind });
  }
  return groups;
}

module.exports = { MIGRATABLE, NEVER_MOVE_RE, readEntries, listSessionEntries, groupAllSessions };
