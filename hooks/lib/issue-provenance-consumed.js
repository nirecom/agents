"use strict";
// The single-use consumption record shared by all three provenance observation
// layers (token / transcript re-scan / workflow inactivity).
//
// One user turn may authorize ONE issue creation. The turn is identified by the
// fingerprint "<lineIndex>:<sha256(rawLine)>" of the newest user entry in the
// transcript, so consuming through any layer blocks re-issuance through every
// other layer for that same entry.
//
// FAIL-CLOSED throughout: a record that cannot be read counts as "already
// consumed", and a record that cannot be written means the consumption cannot be
// guaranteed — the caller must then degrade to mid-workflow.

const fs = require("fs");
const { provenancePaths } = require("./issue-provenance-keys");

const MAX_ENTRIES = 20;

function recordPath(key) {
  return provenancePaths(key).consumed;
}

function readList(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (e) {
    // Missing record = nothing consumed yet. Any OTHER read failure (EISDIR,
    // EACCES, ...) is an unobservable record, which fails closed.
    return e && e.code === "ENOENT" ? [] : null;
  }
  try {
    const data = JSON.parse(raw);
    const list = Array.isArray(data) ? data : data && data.consumed;
    return Array.isArray(list) ? list.filter((x) => typeof x === "string") : null;
  } catch (e) {
    return null;
  }
}

/**
 * @returns {boolean} true when this fingerprint must not be issued again.
 *   Also true when the record is unreadable (fail-closed).
 */
function isConsumed(key, fingerprint) {
  if (typeof fingerprint !== "string" || !fingerprint) return true;
  let file;
  try {
    file = recordPath(key);
  } catch (e) {
    return true;
  }
  const list = readList(file);
  if (list === null) return true;
  return list.includes(fingerprint);
}

/**
 * Append a fingerprint, FIFO-capped at MAX_ENTRIES.
 * @returns {boolean} true only when the record is durably on disk.
 */
function recordConsumed(key, fingerprint) {
  if (typeof fingerprint !== "string" || !fingerprint) return false;
  let file;
  try {
    file = recordPath(key);
  } catch (e) {
    return false;
  }
  const existing = readList(file);
  // An unreadable record must NOT be silently replaced by a fresh one: that would
  // erase every fingerprint already spent and re-arm each of them. isConsumed()
  // already fails closed on the same condition (CPR-5) — so does this.
  if (existing === null) return false;
  const list = existing.slice();
  if (!list.includes(fingerprint)) list.push(fingerprint);
  const capped = list.slice(-MAX_ENTRIES);
  const tmp = file + ".tmp";
  try {
    fs.writeFileSync(tmp, JSON.stringify({ consumed: capped }) + "\n", { mode: 0o600 });
    fs.renameSync(tmp, file);
    return true;
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) {}
    return false;
  }
}

module.exports = { isConsumed, recordConsumed, MAX_ENTRIES };
