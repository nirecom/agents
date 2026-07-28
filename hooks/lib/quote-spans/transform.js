"use strict";
// hooks/lib/quote-spans/transform.js
// Span-aware rewrites over a scanSpans() result (#1569).
//
//   blankQuoteSpans      — collapse quoted literals so write-pattern regexes see
//                          only live command text (backs stripQuotedArgs)
//   unwrapCmdSubstInDq   — same, restricted to DQ spans, with the substitutions
//                          they contain unwrapped into command position
//                          (backs stripDqPreservingCmdSubst)
//   foldNewlinesInSpans  — replace newlines inside the named span kinds with a
//                          space, so line-based scanning does not mistake a
//                          quoted newline for a command separator
//
// All three share the transform error contract: on an ok:false scan they return
// { ok:false, out } with `out` byte-identical to the input. Blanking a guessed
// span boundary is exactly how an injected payload escapes into command
// position, so an unparseable input is left alone and the caller fails closed.

const { scanSpans, EXPANDING_KINDS } = require("./scan");

// Wrapper characters of a substitution. Replacing them with spaces puts the
// inner tokens at the (?:^|[\s;|&])<word> command-position anchor that the
// write-pattern regexes use, instead of hiding them behind `$(`.
const WRAPPER_RE = /\$\(|\)|`/g;

const DEFAULT_FOLD_KINDS = ["dq", "sq", "ansic"];

function childIndex(spans) {
  const roots = [];
  const kids = spans.map(() => []);
  spans.forEach((s, i) => {
    if (s.parent === null || s.parent === undefined) roots.push(i);
    else kids[s.parent].push(i);
  });
  return { roots, kids };
}

// Raw text of span `idx` with every descendant sq / ANSI-C span blanked. Used
// for the substitution regions lifted out of a DQ span: the literal quoting
// inside them is not command text either.
function blankInnerQuotes(str, spans, kids, idx) {
  const s = spans[idx];
  if (s.kind === "sq") return "''";
  if (s.kind === "ansic") return "$''";
  let out = str.slice(s.start, s.innerStart);
  let cur = s.innerStart;
  for (const c of kids[idx]) {
    out += str.slice(cur, spans[c].start);
    out += blankInnerQuotes(str, spans, kids, c);
    cur = spans[c].end;
  }
  out += str.slice(cur, s.innerEnd);
  return out + str.slice(s.innerEnd, s.end);
}

// The substitutions a DQ span carries, lifted out and unwrapped.
function liftedSubstitutions(str, spans, kids, idx, blankQuotes) {
  let out = "";
  for (const c of kids[idx]) {
    if (EXPANDING_KINDS.indexOf(spans[c].kind) === -1) continue;
    const raw = blankQuotes
      ? blankInnerQuotes(str, spans, kids, c)
      : str.slice(spans[c].start, spans[c].end);
    out += " " + raw.replace(WRAPPER_RE, " ") + " ";
  }
  return out;
}

// `blankQuotes` selects the two published behaviours: true collapses sq/ANSI-C
// spans as well as DQ ones (blankQuoteSpans), false touches DQ spans only
// (unwrapCmdSubstInDq).
function renderSpan(str, spans, kids, idx, blankQuotes) {
  const s = spans[idx];
  if (s.kind === "dq") {
    return '""' + liftedSubstitutions(str, spans, kids, idx, blankQuotes);
  }
  if (blankQuotes && s.kind === "sq") return "''";
  if (blankQuotes && s.kind === "ansic") return "$''";
  if (s.kind === "sq" || s.kind === "ansic") return str.slice(s.start, s.end);
  // Expanding frame: keep the delimiters, recurse into the body.
  return str.slice(s.start, s.innerStart) +
    renderList(str, spans, kids, kids[idx], s.innerStart, s.innerEnd, blankQuotes) +
    str.slice(s.innerEnd, s.end);
}

function renderList(str, spans, kids, list, from, to, blankQuotes) {
  let out = "";
  let cur = from;
  for (const idx of list) {
    out += str.slice(cur, spans[idx].start);
    out += renderSpan(str, spans, kids, idx, blankQuotes);
    cur = spans[idx].end;
  }
  return out + str.slice(cur, to);
}

function renderAll(str, blankQuotes) {
  const sr = scanSpans(str);
  if (!sr.ok) return { ok: false, out: sr.str };
  const { roots, kids } = childIndex(sr.spans);
  return {
    ok: true,
    out: renderList(sr.str, sr.spans, kids, roots, 0, sr.str.length, blankQuotes),
  };
}

/** Collapse dq/sq/ANSI-C literals, lifting DQ-borne substitutions into view. */
function blankQuoteSpans(str) {
  return renderAll(str, true);
}

/** Collapse DQ literals only; sq / ANSI-C spans pass through verbatim. */
function unwrapCmdSubstInDq(str) {
  return renderAll(str, false);
}

/**
 * Replace \r / \n with a space wherever the newline is enclosed by a span of
 * one of `kinds` — at ANY depth, so a newline inside a `$()` nested in a DQ
 * span folds for kinds ["dq"] as well.
 */
function foldNewlinesInSpans(str, kinds) {
  const sr = scanSpans(str);
  if (!sr.ok) return { ok: false, out: sr.str };
  const want = Array.isArray(kinds) ? kinds : DEFAULT_FOLD_KINDS;
  const s = sr.str;
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    out += (ch === "\r" || ch === "\n") && enclosedBy(sr, i, want) ? " " : ch;
  }
  return { ok: true, out };
}

function enclosedBy(sr, i, want) {
  for (const s of sr.spans) {
    if (i >= s.start && i < s.end && want.indexOf(s.kind) !== -1) return true;
  }
  return false;
}

module.exports = {
  blankQuoteSpans,
  unwrapCmdSubstInDq,
  foldNewlinesInSpans,
};
