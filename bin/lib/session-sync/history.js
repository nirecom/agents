"use strict";
// ~/.claude/history.jsonl merge (#2658): whole-line union, stable-sorted by numeric timestamp.

const { splitLines, joinLines } = require("./jsonl");

function tsOf(line) {
  try {
    const t = Number(JSON.parse(line).timestamp);
    return Number.isFinite(t) ? t : 0;
  } catch (_) {
    return 0;
  }
}

// mergeHistory(local, remote) -> {text, changed}; changed is false when remote adds no line.
function mergeHistory(local, remote) {
  const localLines = splitLines(local || "");
  const seen = new Set(localLines);
  const all = localLines.slice();
  for (const line of splitLines(remote || "")) {
    if (seen.has(line)) continue;
    seen.add(line);
    all.push(line);
  }
  if (all.length === localLines.length) return { text: local || "", changed: false };
  const sorted = all.map((line, i) => ({ line, i, t: tsOf(line) }))
    .sort((x, y) => (x.t - y.t) || (x.i - y.i))
    .map((e) => e.line);
  return { text: joinLines(sorted), changed: true };
}

module.exports = { mergeHistory };
