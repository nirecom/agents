"use strict";

// Heredoc opener/body extraction for recursive-delete-scan.js. Split out of
// scan.js (rules/coding/file-split.md Pattern A) when the quote/comment
// anchoring below pushed that file past the 300-line warn threshold.

const { scanSpans, quoteContextAt } = require("../../quote-spans");

// One heredoc opener: `<<WORD` / `<<-'WORD'`. The delimiter class mirrors
// stripHeredocBody's (strip-quoted-args.js) so both routes agree on what a
// heredoc tag may be spelled as.
const HEREDOC_OPENER_G = /<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_.-]*)\1/g;

// A head may not span these — the clause boundary the opener-anchored regex in
// strip-quoted-args.js enforces through its own character class.
const CLAUSE_SEPS = ";|&()";

// Absolute offset of every line start, so a per-line match index can be tested
// against the whole-command span scan.
function lineOffsets(lines) {
  const offsets = new Array(lines.length);
  let at = 0;
  for (let i = 0; i < lines.length; i++) {
    offsets[i] = at;
    at += lines[i].length + 1;
  }
  return offsets;
}

// First `#` that actually opens a comment on this line, or line.length. A `#`
// glued to a word (`a#b`) or sitting inside a quote is not one.
function commentIndex(line, base, unquotedAt) {
  for (let k = 0; k < line.length; k++) {
    if (line[k] !== "#") continue;
    if (k > 0 && line[k - 1] !== " " && line[k - 1] !== "\t") continue;
    if (unquotedAt(base + k)) return k;
  }
  return line.length;
}

// Text between the previous unquoted clause separator and the opener.
function clauseHead(line, base, mi, unquotedAt) {
  for (let k = mi - 1; k >= 0; k--) {
    if (CLAUSE_SEPS.indexOf(line[k]) === -1) continue;
    if (unquotedAt(base + k)) return line.slice(k + 1, mi).trim();
  }
  return line.slice(0, mi).trim();
}

// Terminator lookup, linear overall: openers are visited in increasing line
// order, so a per-delimiter cursor only ever moves forward. `ends.find(j => j >
// i)` rescanned from 0 for every opener, which is quadratic and blew past the
// harness's 5-second timeout — fail-open now that settings.json carries no
// deny-glob backstop (#2210 round-15 C9).
function terminatorAfter(terminatorLines, cursors, delim, i) {
  const ends = terminatorLines.get(delim);
  if (!ends) return undefined;
  let c = cursors.get(delim) || 0;
  while (c < ends.length && ends[c] <= i) c += 1;
  cursors.set(delim, c);
  return c < ends.length ? ends[c] : undefined;
}

function indexTerminators(lines) {
  const terminatorLines = new Map();
  for (let i = 0; i < lines.length; i++) {
    const key = lines[i].trim();
    if (key === "") continue;
    if (!terminatorLines.has(key)) terminatorLines.set(key, []);
    terminatorLines.get(key).push(i);
  }
  return terminatorLines;
}

/**
 * extractHeredocs(rawCmd) — every `{ head, body }` a heredoc opener introduces.
 *
 * Opener recognition is anchored to a real token position: a `<<` merely
 * MENTIONED inside a quoted string (`echo "<<B"`) or after a `#` comment marker
 * is not an opener, so it can no longer shadow the REAL opener on a later line
 * by making the body-line skip below jump over it (#2210 round-15 item 1). When
 * the span scan cannot resolve the text, every `<<` stays a candidate — the
 * fail-closed direction, since extracting more bodies only widens judging.
 */
function extractHeredocs(rawCmd) {
  if (typeof rawCmd !== "string" || !rawCmd.includes("<<")) return [];
  const lines = rawCmd.split("\n");
  const offsets = lineOffsets(lines);
  const sr = scanSpans(rawCmd);
  const spanAware = sr !== null && sr !== undefined && sr.ok !== false;
  const unquotedAt = (abs) => !spanAware || quoteContextAt(sr, abs) === "unquoted";

  const terminatorLines = indexTerminators(lines);
  const cursors = new Map();
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.includes("<<")) continue;
    const base = offsets[i];
    const stop = commentIndex(line, base, unquotedAt);
    let lastEnd = -1;
    const re = new RegExp(HEREDOC_OPENER_G.source, "g");
    for (let m = re.exec(line); m !== null; m = re.exec(line)) {
      if (m.index >= stop) break;
      if (!unquotedAt(base + m.index)) continue;
      const head = clauseHead(line, base, m.index, unquotedAt);
      if (head === "") continue;
      const end = terminatorAfter(terminatorLines, cursors, m[2], i);
      if (end === undefined) continue;
      found.push({ head, body: lines.slice(i + 1, end).join("\n") });
      if (end > lastEnd) lastEnd = end;
    }
    if (lastEnd > i) i = lastEnd;
  }
  return found;
}

module.exports = { extractHeredocs };
