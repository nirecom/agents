"use strict";
// Temporary (#2511): deleted with this folder per the deletion-condition in state-root.js
// The deletion-condition check: sessions the legacy root still decides for.
// Only a discriminator file (<stem>.json file or <stem>.control dir) keeps a session
// legacy, so only those count — for every sid shape, since a timestamp-fallback session
// would lose its state just the same once the routing block is gone.
const fs = require("fs");
const os = require("os");
const { assertValidStateSid } = require("../../../workflow-state/state-io/state-root");
const { LEGACY_ROOT } = require("./legacy");

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TIMESTAMP_RE = /^\d{8}-\d{6}$/;

function shapeOf(sid) {
  if (UUID_RE.test(sid)) return "uuid";
  if (TIMESTAMP_RE.test(sid)) return "timestamp";
  return "other";
}

function stemOf(dirent) {
  if (dirent.isFile() && dirent.name.endsWith(".json")) return dirent.name.slice(0, -".json".length);
  if (dirent.isDirectory() && dirent.name.endsWith(".control")) return dirent.name.slice(0, -".control".length);
  return null;
}

function isStateSid(stem) {
  try {
    assertValidStateSid(stem);
    return true;
  } catch (_) {
    return false;
  }
}

// listRemaining(home) -> [{ sid, shape }] sorted by sid; [] when the legacy root is gone.
// Any other read error throws: an unreadable root must never read as "nothing left".
function listRemaining(home) {
  let entries;
  try {
    entries = fs.readdirSync(LEGACY_ROOT(home || os.homedir()), { withFileTypes: true });
  } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
  const sids = new Set();
  for (const d of entries) {
    const stem = stemOf(d);
    if (stem && isStateSid(stem)) sids.add(stem);
  }
  return [...sids].sort().map((sid) => ({ sid, shape: shapeOf(sid) }));
}

module.exports = { listRemaining };
