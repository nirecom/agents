"use strict";
// Transcript entry union (#2658): uuid-keyed lines, local order first, remote-only lines appended.

const MARKER = /^(<{7} |={7}|>{7} )/;

function splitLines(text) {
  if (!text) return [];
  const body = text.endsWith("\n") ? text.slice(0, -1) : text;
  return body === "" ? [] : body.split("\n");
}

function joinLines(lines) {
  return lines.length === 0 ? "" : lines.join("\n") + "\n";
}

function keyOf(line) {
  try {
    const o = JSON.parse(line);
    if (o && typeof o.uuid === "string") return `u:${o.uuid}`;
  } catch (_) { /* not JSON: keyed by the whole line */ }
  return `l:${line}`;
}

function isMarker(line) {
  if (!MARKER.test(line)) return false;
  try {
    JSON.parse(line);
    return false;
  } catch (_) {
    return true;
  }
}

function clean(text, stats) {
  const out = [];
  for (const line of splitLines(text)) {
    if (isMarker(line)) stats.droppedMarkerLines += 1;
    else out.push(line);
  }
  return out;
}

// union(local, remote) -> {text, appendText, deferred, remoteSuperset, uuidMismatch, droppedMarkerLines}
// appendText holds the remote-only lines, the only part ever appended to the working tree.
function union(local, remote) {
  const stats = { droppedMarkerLines: 0 };
  const base = { deferred: false, remoteSuperset: false, uuidMismatch: 0, droppedMarkerLines: 0, appendText: "" };
  if (local && !local.endsWith("\n")) return Object.assign(base, { text: local, deferred: true });
  const localLines = clean(local, stats);
  const remoteLines = clean(remote, stats);
  const localByKey = new Map();
  for (const line of localLines) {
    const k = keyOf(line);
    if (!localByKey.has(k)) localByKey.set(k, line);
  }
  const remoteKeys = new Set();
  const remoteOnly = [];
  let uuidMismatch = 0;
  for (const line of remoteLines) {
    const k = keyOf(line);
    if (remoteKeys.has(k)) continue;
    remoteKeys.add(k);
    if (!localByKey.has(k)) remoteOnly.push(line);
    else if (localByKey.get(k) !== line) uuidMismatch += 1;
  }
  const remoteSuperset = uuidMismatch === 0 && [...localByKey.keys()].every((k) => remoteKeys.has(k));
  const text = remoteSuperset ? joinLines(remoteLines) : joinLines(localLines.concat(remoteOnly));
  return Object.assign(base, {
    text: remoteSuperset && stats.droppedMarkerLines === 0 ? remote : text,
    appendText: joinLines(remoteOnly),
    remoteSuperset,
    uuidMismatch,
    droppedMarkerLines: stats.droppedMarkerLines,
  });
}

module.exports = { union, splitLines, joinLines, isMarker };
