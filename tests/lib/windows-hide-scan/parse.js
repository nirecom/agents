"use strict";
// tests/lib/windows-hide-scan/parse.js — the text layer of the #3127 windowsHide scan: masking of
// comments / strings / templates / regex literals (same length, newlines kept), bracket matching
// and top-level comma splitting. Template `${...}` contents are masked too (accepted tradeoff).

const REGEX_PREV = "(,=:[!&|?{};";

// maskDetailed(src) -> { text, unterminatedAt }: unterminatedAt is the start index of a template or
// block comment that never closes (the caller reports the file as unparseable), else null.
function maskDetailed(src) {
  const out = src.split("");
  let unterminatedAt = null;
  const len = src.length;
  const blank = (a, b) => { for (let k = a; k < b && k < len; k++) if (out[k] !== "\n") out[k] = " "; };
  const fail = (i) => { if (unterminatedAt === null) unterminatedAt = i; };

  function str(i) {
    const q = src[i];
    let j = i + 1;
    while (j < len) {
      if (src[j] === "\\") { j += 2; continue; }
      if (src[j] === q) { blank(i + 1, j); return j + 1; }
      if (src[j] === "\n") { blank(i + 1, j); return j; }
      j++;
    }
    blank(i + 1, len);
    return len;
  }

  function tpl(i) {
    let j = i + 1;
    while (j < len) {
      if (src[j] === "\\") { j += 2; continue; }
      if (src[j] === "`") { blank(i + 1, j); return j + 1; }
      if (src[j] === "$" && src[j + 1] === "{") {
        const k = code(j + 2, true);
        if (k >= len) break;
        j = k + 1;
        continue;
      }
      j++;
    }
    fail(i);
    blank(i + 1, len);
    return len;
  }

  // -1 when no closing slash on the line: the `/` was a division after all.
  function regex(i) {
    let j = i + 1, inClass = false;
    while (j < len) {
      const ch = src[j];
      if (ch === "\n") return -1;
      if (ch === "\\") { j += 2; continue; }
      if (inClass) { if (ch === "]") inClass = false; }
      else if (ch === "[") inClass = true;
      else if (ch === "/") {
        blank(i + 1, j);
        j++;
        while (j < len && /[A-Za-z]/.test(src[j])) j++;
        return j;
      }
      j++;
    }
    return -1;
  }

  const regexAllowed = (prev, lineStart, i) =>
    lineStart || REGEX_PREV.includes(prev) || /(?:^|[^\w$])return$/.test(src.slice(Math.max(0, i - 20), i).trimEnd());

  // code(i, stopAtBrace) -> index of the `}` closing a template expression, or len.
  function code(i, stopAtBrace) {
    let depth = 0, prev = "", lineStart = true;
    while (i < len) {
      const c = src[i], d = src[i + 1];
      if (c === "\n") { lineStart = true; i++; continue; }
      if (c === " " || c === "\t" || c === "\r") { i++; continue; }
      if (c === "/" && d === "/") {
        let j = i;
        while (j < len && src[j] !== "\n") j++;
        blank(i, j); i = j; continue;
      }
      if (c === "/" && d === "*") {
        const j = src.indexOf("*/", i + 2);
        if (j < 0) { fail(i); blank(i, len); return len; }
        blank(i, j + 2); i = j + 2; continue;
      }
      if (c === '"' || c === "'") { i = str(i); prev = c; lineStart = false; continue; }
      if (c === "`") { i = tpl(i); prev = c; lineStart = false; continue; }
      if (c === "/" && regexAllowed(prev, lineStart, i)) {
        const j = regex(i);
        if (j > 0) { i = j; prev = "/"; lineStart = false; continue; }
      }
      if (stopAtBrace) {
        if (c === "{") depth++;
        else if (c === "}") { if (depth === 0) return i; depth--; }
      }
      prev = c; lineStart = false; i++;
    }
    return len;
  }

  code(0, false);
  return { text: out.join(""), unterminatedAt };
}

const mask = (src) => maskDetailed(src).text;

// matchClose(masked, openIdx) -> index of the bracket closing masked[openIdx], or masked.length.
function matchClose(masked, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < masked.length; i++) {
    const c = masked[i];
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c) && --depth === 0) return i;
  }
  return masked.length;
}

// Split text at top-level commas (depth over () [] {}), using the masked text for structure.
function splitTop(orig, masked) {
  const parts = []; let depth = 0, start = 0;
  for (let i = 0; i < masked.length; i++) {
    const c = masked[i];
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === "," && depth === 0) { parts.push(orig.slice(start, i).trim()); start = i + 1; }
  }
  const last = orig.slice(start).trim();
  if (last) parts.push(last);
  return parts;
}

// Every call of the given names in src as its top-level argument strings, found by bracket matching.
function spawnCalls(src, names = "spawnSync") {
  const m = mask(src), calls = [];
  const re = new RegExp("\\b(?:" + names + ")\\s*\\(", "g"); let hit;
  while ((hit = re.exec(m))) {
    const close = matchClose(m, re.lastIndex - 1);
    calls.push(splitTop(src.slice(re.lastIndex, close), m.slice(re.lastIndex, close)));
  }
  return calls;
}

// Raw spawn-family calls of bash/gh/git (literal 1st arg, any line layout) whose argument text lacks windowsHide.
function rawWithoutHide(src) {
  return spawnCalls(src, "spawn|spawnSync|execFile|execFileSync")
    .filter((a) => /^["'](?:bash|gh|git)["']$/.test(a[0]) && !/windowsHide/.test(a.join(",")))
    .map((a) => a.join(" , "));
}

const lineOf = (src, idx) => src.slice(0, idx).split("\n").length;

module.exports = { maskDetailed, mask, matchClose, splitTop, spawnCalls, rawWithoutHide, lineOf };
