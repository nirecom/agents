"use strict";
// hooks/lib/command-ir/separator-links.js — positional linkage for ir.separators.
//
// `separators` is recorded UNCONDITIONALLY at every split point, including leading
// and trailing ones, so `segments[i + 1]` index arithmetic is wrong: `& git status`
// and `git pull &` both yield one segment and one separator. Each link therefore
// names its own left/right segment index (null when that side is empty) and whether
// the operator was backslash-escaped, which is what lets a consumer tell a real
// separator from `find ... \;`. Mirrors command-parser.js splitSegmentsWithSeparators
// character for character so indices line up with ir.separators.

const { substitutionSpanEnds, spanEndAt } = require("../substitution-spans");

// True when cmd[i] is preceded by an ODD number of backslashes (i.e. escaped).
function isEscapedAt(cmd, i) {
  let n = 0;
  let k = i - 1;
  while (k >= 0 && cmd[k] === "\\") { n++; k--; }
  return n % 2 === 1;
}

/**
 * Walk `cmd` the way the segment splitter does and return one link per separator.
 *
 * @returns {Array<{index:number, sep:string, leftSegment:number|null,
 *                  rightSegment:number|null, escaped:boolean}>}
 */
function linkSeparators(cmd, opts) {
  const links = [];
  if (typeof cmd !== "string" || cmd === "") return links;
  const preserve = !!(opts && opts.preserveSubstitutionSpans);
  const spanEnds = preserve ? substitutionSpanEnds(cmd) : null;

  let cur = "";
  let segCount = 0;
  const awaitingRight = [];
  const flush = () => {
    if (cur.trim()) {
      const idx = segCount++;
      while (awaitingRight.length) links[awaitingRight.pop()].rightSegment = idx;
      cur = "";
      return idx;
    }
    cur = "";
    return null;
  };
  const record = (sep, at) => {
    const left = flush();
    links.push({ index: links.length, sep, leftSegment: left, rightSegment: null, escaped: isEscapedAt(cmd, at) });
    awaitingRight.push(links.length - 1);
  };

  let i = 0;
  const n = cmd.length;
  while (i < n) {
    const ch = cmd[i];
    if (preserve) {
      const spanEnd = spanEndAt(cmd, i, spanEnds);
      if (spanEnd > i) { cur += cmd.slice(i, spanEnd); i = spanEnd; continue; }
    }
    if (ch === '"') {
      cur += ch; i++;
      while (i < n && cmd[i] !== '"') {
        if (cmd[i] === "\\" && i + 1 < n) { cur += cmd[i] + cmd[i + 1]; i += 2; }
        else { cur += cmd[i]; i++; }
      }
      if (i < n) { cur += cmd[i]; i++; }
    } else if (ch === "'") {
      cur += ch; i++;
      while (i < n && cmd[i] !== "'") { cur += cmd[i]; i++; }
      if (i < n) { cur += cmd[i]; i++; }
    } else if (ch === "$" && cmd[i + 1] === "'") {
      cur += "$'"; i += 2;
      while (i < n && cmd[i] !== "'") {
        if (cmd[i] === "\\" && i + 1 < n) { cur += cmd[i] + cmd[i + 1]; i += 2; }
        else { cur += cmd[i]; i++; }
      }
      if (i < n) { cur += cmd[i]; i++; }
    } else if ((ch === "&" && cmd[i + 1] === "&") || (ch === "|" && cmd[i + 1] === "|")) {
      // Bash only recognizes `&&` / `||` as ONE two-character operator when BOTH
      // characters are live (unescaped). `\&&` escapes just the first character,
      // leaving it a literal word char followed by a REAL single-char `&`
      // (background) operator — not a fully-escaped no-op compound token. Fold
      // the escaped first character straight into the current word (no split,
      // no link — same as any other literal char) and let the loop re-evaluate
      // the second character on its own next iteration, which will correctly
      // record it as a live, unescaped single-char separator.
      if (isEscapedAt(cmd, i)) { cur += ch; i += 1; }
      else { record(ch === "&" ? "&&" : "||", i); i += 2; }
    } else if (ch === ";" || ch === "|" || ch === "&" || ch === "(" || ch === ")") {
      record(ch, i); i += 1;
    } else if (/\d/.test(ch)) {
      let j = i;
      while (j < n && /\d/.test(cmd[j])) j++;
      if (cmd[j] === ">" && (cmd[j + 1] === "&" || cmd[j + 1] === "|")) {
        cur += cmd.slice(i, j + 2); i = j + 2;
      } else { cur += ch; i++; }
    } else if (ch === ">" && (cmd[i + 1] === "&" || cmd[i + 1] === "|")) {
      cur += cmd.slice(i, i + 2); i += 2;
    } else {
      cur += ch; i++;
    }
  }
  flush();
  return links;
}

module.exports = { linkSeparators };
