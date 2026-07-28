"use strict";
// hooks/lib/quote-spans/query.js
// Span-aware predicates over a scanSpans() result (#1569).
//
// Every function accepts EITHER a raw string OR an already-computed ScanResult,
// so a caller that runs several predicates over one command pays for one scan.
//
// Single error contract — when the scan is ok:false the answer goes to the
// danger side, because "we could not parse this" must never read as "this is
// clean":
//   testOutsideQuotes  -> true      findOutsideQuotes -> 0
//   hasUnclosedQuoteSpan -> true (for its kind set)
//   splitOutsideQuotes / spanAwareNewlineSplit -> { ok:false, parts|lines:[str] }
// `onAmbiguous:"safe"` opts a caller out of the predicate half of that rule; the
// split family is fail-closed unconditionally (its callers slice on the result).

const { scanSpans, EXPANDING_KINDS } = require("./scan");

const DEFAULT_QUOTE_KINDS = ["dq", "sq", "ansic"];
const DEFAULT_CONTEXTS = new Set(["unquoted"]);

function resolveScan(input) {
  if (input !== null && typeof input === "object" && Array.isArray(input.spans)) return input;
  return scanSpans(input);
}

function normalizeOpts(opts) {
  const o = opts || {};
  let contexts = o.contexts;
  if (Array.isArray(contexts)) contexts = new Set(contexts);
  return {
    contexts: contexts instanceof Set ? contexts : DEFAULT_CONTEXTS,
    includeCmdSubstBody: o.includeCmdSubstBody !== false,
    onAmbiguous: o.onAmbiguous === "safe" ? "safe" : "danger",
  };
}

// Innermost span covering `i`. Children always follow their parent in the flat
// span array and siblings are disjoint, so the last match is the innermost one.
function spanAtIn(sr, i) {
  let found = null;
  for (const s of sr.spans) {
    if (i >= s.start && i < s.end) found = s;
  }
  return found;
}

function quoteContextIn(sr, i) {
  const s = spanAtIn(sr, i);
  if (s === null) return "unquoted";
  return DEFAULT_QUOTE_KINDS.indexOf(s.kind) === -1 ? "unquoted" : s.kind;
}

// True when `i` sits inside any command-substitution-like frame body.
function insideExpandingBody(sr, i) {
  let s = spanAtIn(sr, i);
  while (s) {
    if (EXPANDING_KINDS.indexOf(s.kind) !== -1) return true;
    s = s.parent === null || s.parent === undefined ? null : sr.spans[s.parent];
  }
  return false;
}

function positionEligible(sr, i, o) {
  if (!o.contexts.has(quoteContextIn(sr, i))) return false;
  if (!o.includeCmdSubstBody && insideExpandingBody(sr, i)) return false;
  return true;
}

// All match positions of `pattern` in `str`, as [index, length] pairs.
// A caller-supplied RegExp is cloned (with `g` added) so its lastIndex is never
// mutated and a stateful /g object cannot change the answer between calls.
function matchesOf(str, pattern) {
  const out = [];
  if (pattern instanceof RegExp) {
    const flags = pattern.flags.indexOf("g") === -1 ? pattern.flags + "g" : pattern.flags;
    const re = new RegExp(pattern.source, flags);
    let m = re.exec(str);
    while (m !== null) {
      out.push([m.index, m[0].length]);
      if (m[0].length === 0) re.lastIndex += 1;
      m = re.exec(str);
    }
    return out;
  }
  const needle = String(pattern);
  if (needle.length === 0) return out;
  let from = 0;
  for (;;) {
    const i = str.indexOf(needle, from);
    if (i === -1) return out;
    out.push([i, needle.length]);
    from = i + needle.length;
  }
}

function spanAt(input, i) {
  return spanAtIn(resolveScan(input), i);
}

function quoteContextAt(input, i) {
  return quoteContextIn(resolveScan(input), i);
}

function findOutsideQuotes(input, pattern, opts) {
  const sr = resolveScan(input);
  const o = normalizeOpts(opts);
  if (!sr.ok) return o.onAmbiguous === "safe" ? -1 : 0;
  for (const [i] of matchesOf(sr.str, pattern)) {
    if (positionEligible(sr, i, o)) return i;
  }
  return -1;
}

function testOutsideQuotes(input, pattern, opts) {
  const sr = resolveScan(input);
  const o = normalizeOpts(opts);
  if (!sr.ok) return o.onAmbiguous !== "safe";
  return findOutsideQuotes(sr, pattern, opts) !== -1;
}

/**
 * True when the scan left a span of one of `kinds` open at EOF.
 * Default kinds are the three QUOTE kinds only — an unclosed `$(` is a
 * different (and far more common) condition than an unclosed quote, and
 * reporting it here would make every substitution-bearing command "unclosed".
 */
function hasUnclosedQuoteSpan(input, kinds) {
  const sr = resolveScan(input);
  if (sr.ok) return false;
  const want = Array.isArray(kinds) ? kinds : DEFAULT_QUOTE_KINDS;
  const failKinds = Array.isArray(sr.failKinds) ? sr.failKinds : [];
  if (failKinds.indexOf("*") !== -1) return true;
  return failKinds.some((k) => want.indexOf(k) !== -1);
}

function splitOutsideQuotes(input, pattern, opts) {
  const sr = resolveScan(input);
  const o = normalizeOpts(opts);
  if (!sr.ok) return { ok: false, parts: [sr.str] };
  const parts = [];
  let last = 0;
  for (const [i, len] of matchesOf(sr.str, pattern)) {
    if (i < last) continue;
    if (!positionEligible(sr, i, o)) continue;
    parts.push(sr.str.slice(last, i));
    last = i + len;
  }
  parts.push(sr.str.slice(last));
  return { ok: true, parts };
}

/**
 * Split on newlines that are NOT inside a span, then trim each line and drop
 * the empty ones — the shape the multi-line write detectors consume.
 */
function spanAwareNewlineSplit(input, opts) {
  const sr = resolveScan(input);
  if (!sr.ok) return { ok: false, lines: [sr.str] };
  const r = splitOutsideQuotes(sr, /[\r\n]/, opts);
  return { ok: true, lines: r.parts.map((l) => l.trim()).filter(Boolean) };
}

module.exports = {
  spanAt,
  quoteContextAt,
  findOutsideQuotes,
  testOutsideQuotes,
  hasUnclosedQuoteSpan,
  splitOutsideQuotes,
  spanAwareNewlineSplit,
  DEFAULT_QUOTE_KINDS,
};
