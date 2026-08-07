// hooks/lib/basename-glob-normalize/brace-ansi-expand.js
// Candidate-spelling WIDENERS for ../basename-glob-normalize.js (file-split
// sibling folder, rules/coding/file-split.md).
//
// DIRECTION DISCIPLINE: this file is a NORMALIZER consumed in the DETECTION
// direction — output feeds a denylist match, so more candidates only makes
// the hook block MORE (fail closed), while dropping or rewriting a spelling
// is a live BYPASS. Never remove a candidate; always keep the original
// alongside every derived one. Never reuse this as a permission predicate.
//
// Covers two constructs a glob cannot express, since both CREATE the exact
// protected basename rather than matching an existing file: brace expansion
// (`s1.workflow-of{f..f}` -> s1.workflow-off) and ANSI-C quoting
// (`$'s1.workflow-of\x66'` -> s1.workflow-off). Both were fixture-verified to
// produce the real file when undetected.
"use strict";

// Cap on the number of candidate spellings one token may expand to. A brace
// pattern's expansion product is unbounded (`{1..1000000}`), so without a cap
// an attacker buys unbounded CPU inside a PreToolUse hook; 1024 comfortably
// covers any hand-written path while costing only a few thousand comparisons.
// ABOVE THE CAP THE ANSWER IS "HIT" (fail closed) — an unfinished expansion
// has not been shown to miss the suffix. Named exception (CPR-UNV): a
// legitimate write whose pattern exceeds the cap is blocked; the block
// message names the file, so spelling it without the brace group is the fix.
const MAX_CANDIDATE_SPELLINGS = 1024;
// A brace pattern nested deeper than this is not a spelling anybody types.
const MAX_EXPANSION_ROUNDS = 16;

const OVER_CAP = Symbol("over-cap");

// --------------------------------------------------------------- ANSI-C ($'…')
// Bash decodes these inside $'…' BEFORE the filename reaches the kernel, so the
// hook must decode them too or it inspects a different name than the one the
// write lands on.
const SIMPLE_ANSI_ESCAPES = {
  a: "\x07", b: "\b", e: "\x1b", E: "\x1b", f: "\f",
  n: "\n", r: "\r", t: "\t", v: "\v",
  "\\": "\\", "'": "'", '"': '"', "?": "?",
};

// decodeAnsiCEscapes(body): the CONTENT of a $'…' string with its escapes
// resolved. An escape this decoder does not model keeps its backslash (bash
// does the same), so no candidate character is ever lost.
function decodeAnsiCEscapes(body) {
  if (typeof body !== "string" || body.indexOf("\\") === -1) return body;
  let out = "";
  let i = 0;
  while (i < body.length) {
    const c = body[i];
    if (c !== "\\" || i + 1 >= body.length) { out += c; i += 1; continue; }
    const n = body[i + 1];
    if (Object.prototype.hasOwnProperty.call(SIMPLE_ANSI_ESCAPES, n)) {
      out += SIMPLE_ANSI_ESCAPES[n];
      i += 2;
      continue;
    }
    if (n === "x" || n === "X") {                       // \xHH (1-2 hex digits)
      const m = /^[0-9A-Fa-f]{1,2}/.exec(body.slice(i + 2));
      if (m) { out += String.fromCharCode(parseInt(m[0], 16)); i += 2 + m[0].length; continue; }
    }
    if (n === "u" || n === "U") {                       // \uHHHH / \UHHHHHHHH
      const max = n === "u" ? 4 : 8;
      const m = new RegExp("^[0-9A-Fa-f]{1," + max + "}").exec(body.slice(i + 2));
      if (m) {
        const cp = parseInt(m[0], 16);
        if (cp <= 0x10ffff) { out += String.fromCodePoint(cp); i += 2 + m[0].length; continue; }
      }
    }
    if (n >= "0" && n <= "7") {                         // \NNN (1-3 octal digits)
      const m = /^[0-7]{1,3}/.exec(body.slice(i + 1));
      if (m) { out += String.fromCharCode(parseInt(m[0], 8) & 0xff); i += 1 + m[0].length; continue; }
    }
    if (n === "c" && i + 2 < body.length) {             // \cX (control char)
      const ch = body[i + 2];
      out += String.fromCharCode(ch.toUpperCase().charCodeAt(0) ^ 0x40);
      i += 3;
      continue;
    }
    out += c + n;                                       // unmodelled → keep both
    i += 2;
  }
  return out;
}

// ansiCVariantsOf(text): the ADDITIONAL spellings a $'…' reading of `text`
// yields (widening only — caller keeps `text` too). Decodes both the still-
// wrapped `$'…'` token and any text containing a backslash, since the
// tokenizer strips the wrapper on several routes before this module sees the
// basename, and a surviving `\x66` there means the same thing.
function ansiCVariantsOf(text) {
  if (typeof text !== "string" || text.indexOf("\\") === -1) return [];
  const out = [];
  const push = (v) => { if (typeof v === "string" && v !== "" && v !== text && !out.includes(v)) out.push(v); };
  if (text.startsWith("$'") && text.endsWith("'") && text.length >= 3) {
    push(decodeAnsiCEscapes(text.slice(2, -1)));
  }
  push(decodeAnsiCEscapes(text));
  return out;
}

// ---------------------------------------------------------------- brace groups
// scanGroupAt(s, from): the first `{ … }` pair at/after `from`, with the offsets
// of its top-level commas. Backslash-escaped characters are skipped, matching
// bash (an escaped brace is not a group delimiter).
function scanGroupAt(s, from) {
  for (let i = from; i < s.length; i++) {
    if (s[i] === "\\") { i += 1; continue; }
    if (s[i] !== "{") continue;
    let depth = 1;
    const commas = [];
    for (let j = i + 1; j < s.length; j++) {
      const c = s[j];
      if (c === "\\") { j += 1; continue; }
      if (c === "{") { depth += 1; continue; }
      if (c === "}") {
        depth -= 1;
        if (depth === 0) return { open: i, close: j, commas };
        continue;
      }
      if (c === "," && depth === 1) commas.push(j);
    }
    // Unmatched `{` — it is not a group, but a LATER `{` still can be.
  }
  return null;
}

function padNumber(value, width) {
  if (width <= 0) return String(value);
  const neg = value < 0;
  const digits = String(Math.abs(value));
  return (neg ? "-" : "") + (digits.length >= width ? digits : "0".repeat(width - digits.length) + digits);
}

// rangeAlternatives(content): the `{a..b}` / `{a..b..n}` sequence, numeric or
// single-character, or null when `content` is not a range. OVER_CAP when the
// sequence alone would blow the cap.
function rangeAlternatives(content) {
  const parts = content.split("..");
  if (parts.length < 2 || parts.length > 3) return null;
  const [a, b, incrRaw] = parts;
  let step = 1;
  if (incrRaw !== undefined) {
    if (!/^[+-]?\d+$/.test(incrRaw)) return null;
    step = Math.abs(parseInt(incrRaw, 10));
    if (step === 0) return null;
  }
  const numeric = /^[+-]?\d+$/.test(a) && /^[+-]?\d+$/.test(b);
  const charwise = !numeric && a.length === 1 && b.length === 1;
  if (!numeric && !charwise) return null;
  const start = numeric ? parseInt(a, 10) : a.charCodeAt(0);
  const end = numeric ? parseInt(b, 10) : b.charCodeAt(0);
  if (Math.floor(Math.abs(end - start) / step) + 1 > MAX_CANDIDATE_SPELLINGS) return OVER_CAP;
  const width = numeric && (/^[+-]?0\d/.test(a) || /^[+-]?0\d/.test(b))
    ? Math.max(a.replace(/^[+-]/, "").length, b.replace(/^[+-]/, "").length)
    : 0;
  const render = (v) => (numeric ? padNumber(v, width) : String.fromCharCode(v));
  const out = [];
  if (start <= end) for (let v = start; v <= end; v += step) out.push(render(v));
  else for (let v = start; v >= end; v -= step) out.push(render(v));
  return out;
}

// alternativesOf(s, g): what this group expands to, or null when bash would NOT
// expand it. Bash fidelity detail that matters here: a single element with no
// top-level comma and no `..` (`{f}`, `{abc}`) is NOT a brace expansion — it
// stays literal, braces and all — so reporting alternatives for it would
// FABRICATE a spelling the shell never produces.
function alternativesOf(s, g) {
  const content = s.slice(g.open + 1, g.close);
  if (g.commas.length > 0) {
    const alts = [];
    let prev = g.open + 1;
    for (const idx of g.commas) { alts.push(s.slice(prev, idx)); prev = idx + 1; }
    alts.push(s.slice(prev, g.close));
    return alts;
  }
  return rangeAlternatives(content);
}

function nextExpandableGroup(s) {
  let from = 0;
  while (from < s.length) {
    const g = scanGroupAt(s, from);
    if (!g) return null;
    const alts = alternativesOf(s, g);
    if (alts === OVER_CAP) return OVER_CAP;
    if (alts) return { g, alts };
    from = g.open + 1;      // literal `{…}` — look for the next group past it
  }
  return null;
}

// expandBraces(text): { list, overCap }. `list` always contains at least
// `text` itself; `overCap` true means the caller must fail closed.
function expandBraces(text) {
  if (typeof text !== "string" || text.indexOf("{") === -1) return { list: [text], overCap: false };
  let frontier = [text];
  const done = [];
  for (let round = 0; round < MAX_EXPANSION_ROUNDS; round++) {
    if (frontier.length === 0) break;
    const next = [];
    for (const s of frontier) {
      const found = nextExpandableGroup(s);
      if (found === OVER_CAP) return { list: [text], overCap: true };
      if (!found) { done.push(s); continue; }
      const pre = s.slice(0, found.g.open);
      const post = s.slice(found.g.close + 1);
      for (const alt of found.alts) next.push(pre + alt + post);
      if (next.length + done.length > MAX_CANDIDATE_SPELLINGS) return { list: [text], overCap: true };
    }
    frontier = next;
  }
  if (frontier.length > 0) return { list: [text], overCap: true };   // still unfinished
  if (!done.includes(text)) done.push(text);   // never lose the literal spelling
  return { list: done, overCap: false };
}

// candidateSpellings(basename): every on-disk basename the raw text could
// become, ALWAYS including the raw text itself. `overCap` true means the
// enumeration was abandoned and the caller must fail closed.
function candidateSpellings(basename) {
  if (typeof basename !== "string" || basename === "") return { candidates: [basename], overCap: false };
  const seeds = [basename].concat(ansiCVariantsOf(basename));
  const candidates = [];
  let overCap = false;
  for (const seed of seeds) {
    const expanded = expandBraces(seed);
    if (expanded.overCap) overCap = true;
    for (const c of expanded.list) if (!candidates.includes(c)) candidates.push(c);
    if (candidates.length > MAX_CANDIDATE_SPELLINGS) { overCap = true; break; }
  }
  return { candidates, overCap };
}

module.exports = {
  MAX_CANDIDATE_SPELLINGS,
  decodeAnsiCEscapes,
  ansiCVariantsOf,
  expandBraces,
  candidateSpellings,
};
