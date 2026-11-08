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

// winner(a, b) -> the line kept for a same-uuid conflict: the lexicographically greater string,
// so both machines pick the identical line whichever side is local.
function winner(a, b) {
  return a > b ? a : b;
}

function isUuidKey(k) {
  return k.startsWith("u:");
}

// group(lines) -> Map key -> [lines in order], insertion-ordered by first occurrence.
function group(lines) {
  const m = new Map();
  for (const line of lines) {
    const k = keyOf(line);
    if (m.has(k)) m.get(k).push(line);
    else m.set(k, [line]);
  }
  return m;
}

// keptLine -> the one line a uuid keeps: the first line of the preferred side when it holds the
// uuid, else the winner over every line of both sides, so union(L,R) and union(R,L) agree.
function keptLine(lg, rg, prefer) {
  if (prefer === "local" && lg) return lg[0];
  if (prefer === "remote" && rg) return rg[0];
  return (lg || []).concat(rg || []).reduce(winner);
}

function countMismatch(lMap, rMap) {
  let n = 0;
  for (const [k, lg] of lMap) {
    const rg = rMap.get(k);
    if (isUuidKey(k) && rg && new Set(lg.concat(rg)).size > 1) n += 1;
  }
  return n;
}

// mergeLocal -> {merged, replacedLocal, lost}: local order; each uuid sits at its first local
// position. lost holds the local lines the output text no longer has; with rCap (the remote-superset
// output, which is the remote lines) a non-uuid line beyond its remote count is lost too.
function mergeLocal(localLines, kept, rCap) {
  const merged = [];
  const placed = new Set();
  const seen = new Map();
  const lost = [];
  let replacedLocal = 0;
  for (const line of localLines) {
    const k = keyOf(line);
    if (!isUuidKey(k)) {
      merged.push(line);
      seen.set(k, (seen.get(k) || 0) + 1);
      if (rCap && seen.get(k) > rCap.get(k).length) lost.push(line);
    } else if (placed.has(k)) {
      replacedLocal += 1;
      if (kept.get(k) !== line) lost.push(line);
    } else {
      placed.add(k);
      merged.push(kept.get(k));
      if (kept.get(k) !== line) {
        replacedLocal += 1;
        lost.push(line);
      }
    }
  }
  return { merged, replacedLocal, lost };
}

// isRemoteSuperset -> true when the result is exactly what the remote holds: every local key is
// in remote, and each remote uuid holds a single line that is also the kept line.
function isRemoteSuperset(lMap, rMap, kept) {
  for (const k of lMap.keys()) if (!rMap.has(k)) return false;
  for (const [k, rg] of rMap) {
    if (isUuidKey(k) && (rg.length > 1 || kept.get(k) !== rg[0])) return false;
  }
  return true;
}

// union(local, remote) -> {text, appendText, deferred, remoteSuperset, uuidMismatch, replacedLocal,
// droppedMarkerLines, lostLocal, lostRemote}. Each uuid keeps exactly one line (keptLine). appendText
// holds the remote-only lines; replacedLocal counts local lines replaced in place or dropped as
// same-uuid duplicates, which the caller must apply as a full rewrite. lostLocal lists, in local order,
// the local lines absent from text, and lostRemote the remote same-uuid lines absent from it, so a
// caller can keep them elsewhere whichever machine holds the winning line.
// opts.prefer "local" | "remote" keeps that side's first line on every same-uuid conflict (the side
// holding the newer edit); opts.preferLocal is the older spelling of prefer "local".
function union(local, remote, opts = {}) {
  const prefer = opts.prefer || (opts.preferLocal ? "local" : null);
  const stats = { droppedMarkerLines: 0 };
  const base = {
    deferred: false, remoteSuperset: false, uuidMismatch: 0, replacedLocal: 0, droppedMarkerLines: 0, appendText: "",
    lostLocal: [], lostRemote: [],
  };
  if (local && !local.endsWith("\n")) return Object.assign(base, { text: local, deferred: true });
  const localLines = clean(local, stats);
  const remoteLines = clean(remote, stats);
  const lMap = group(localLines);
  const rMap = group(remoteLines);
  const kept = new Map();
  for (const k of new Set([...lMap.keys(), ...rMap.keys()])) {
    if (isUuidKey(k)) kept.set(k, keptLine(lMap.get(k), rMap.get(k), prefer));
  }
  const remoteSuperset = isRemoteSuperset(lMap, rMap, kept);
  const { merged, replacedLocal, lost } = mergeLocal(localLines, kept, remoteSuperset ? rMap : null);
  const remoteOnly = [];
  for (const [k, rg] of rMap) {
    if (!lMap.has(k)) remoteOnly.push(isUuidKey(k) ? kept.get(k) : rg[0]);
  }
  const text = remoteSuperset ? joinLines(remoteLines) : joinLines(merged.concat(remoteOnly));
  return Object.assign(base, {
    text: remoteSuperset && stats.droppedMarkerLines === 0 ? remote : text,
    appendText: joinLines(remoteOnly),
    remoteSuperset,
    uuidMismatch: countMismatch(lMap, rMap),
    replacedLocal,
    droppedMarkerLines: stats.droppedMarkerLines,
    lostLocal: lost,
    lostRemote: remoteLines.filter((line) => isUuidKey(keyOf(line)) && kept.get(keyOf(line)) !== line),
  });
}

module.exports = { union, splitLines, joinLines, isMarker };
