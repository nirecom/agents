"use strict";
// bin/lib/glossary-drift/match.js — the variant match over one layer: word windows, their context
// mode (identifier / caps / prose), the term lookup and the prose tolerance. Matching rules SSOT:
// docs/architecture/claude-code/glossary-check.md#matching-rules.

const { singular, compactKey, identKey, identFoldedKey } = require("../../../hooks/lib/glossary-term");
const { closest, indexTerms, isAllCapsSpelling } = require("./terms");
const { BOUNDARY_RE, headingLines, identifierRanges, declaredRanges, isCapsWord } = require("./context");

const SEPARATOR_RE = /^(?:[ \t]+|-)$/;
const WORD_RE = /[A-Za-z0-9_]+/g;
// Sentence start: line head (after a list / heading / quote marker), or after `. ` / `: `;
// emphasis markers in between are transparent (`**Title:** Word`).
const SENTENCE_HEAD_RE = /^\s*(?:(?:[-*+]|\d+[.)])\s+|#{1,6}\s+|>\s*)?[*_]*$|[.!?:][*_]*\s+[*_]*$/;
// camelCase / PascalCase (`workflowPlansDir`) may name the identifier in another language.
const CAMEL_RE = /[a-z][A-Z]/;

const subwordsOf = (text) => text.split("_").filter((s) => s !== "");
// The length of a word with each `_` part singularized: no match key of a window is shorter.
const foldedLength = (text) => subwordsOf(text).reduce((sum, s) => sum + singular(s.toLowerCase()).length, 0);

function wordsOf(line) {
  const words = [];
  let m;
  WORD_RE.lastIndex = 0;
  while ((m = WORD_RE.exec(line)) !== null) words.push({ start: m.index, end: m.index + m[0].length, text: m[0] });
  return words;
}

// The ranges sorted by start with the overlapping ones merged.
function mergedRanges(ranges) {
  const out = [];
  for (const [s, e] of ranges.slice().sort((a, b) => a[0] - b[0])) {
    const last = out[out.length - 1];
    if (last && s <= last[1]) last[1] = Math.max(last[1], e);
    else out.push([s, e]);
  }
  return out;
}

// The words of a line with their marks: ident (inside an identifier chunk or a declared spelling,
// or every word of the identifier layer) and caps (a capital word). Words and ranges advance once.
function markedWords(line, allIdent, declared) {
  const ranges = allIdent ? [] : mergedRanges(identifierRanges(line).concat(declaredRanges(line, declared)));
  let k = 0;
  return wordsOf(line).map((w) => {
    while (k < ranges.length && ranges[k][1] < w.end) k++;
    const inside = k < ranges.length && w.start >= ranges[k][0] && w.end <= ranges[k][1];
    return Object.assign(w, { ident: allIdent || inside, caps: isCapsWord(w.text) });
  });
}

// -> { seq, breaks: { raw, folded }, spaced, caps, mode } — breaks are the key offsets of the
// whitespace separators; caps lists the raw letter ranges of the capital words.
function windowAt(line, words, i, n) {
  const last = words[i + n - 1];
  if (!last) return null;
  const breaks = { raw: [], folded: [] };
  const caps = [];
  let raw = 0;
  let folded = 0;
  for (let k = i; k < i + n; k++) {
    if (k > i) {
      const sep = line.slice(words[k - 1].end, words[k].start);
      if (!SEPARATOR_RE.test(sep)) return null;
      if (sep !== "-") { breaks.raw.push(raw); breaks.folded.push(folded); }
    }
    const letters = words[k].text.replace(/_/g, "").length;
    if (words[k].caps) caps.push([raw, raw + letters]);
    raw += letters;
    folded += foldedLength(words[k].text);
  }
  const before = words[i].start > 0 ? line.charAt(words[i].start - 1) : "";
  const after = line.charAt(last.end);
  if ((before && BOUNDARY_RE.test(before)) || (after && BOUNDARY_RE.test(after))) return null;
  const seq = line.slice(words[i].start, last.end);
  const span = words.slice(i, i + n);
  const mode = seq.includes("_") || span.some((w) => w.ident) ? "identifier" : caps.length > 0 ? "caps" : "prose";
  return { seq, breaks, spaced: breaks.raw.length > 0, caps, mode };
}

// The identifier candidates whose word breaks admit the window's: the folded key first, then the raw key.
function identFits(index, w) {
  if (CAMEL_RE.test(w.seq)) return null;
  for (const [map, keyOf, kind] of [[index.identFolded, identFoldedKey, "folded"], [index.identRaw, identKey, "raw"]]) {
    const entry = map.get(keyOf(w.seq));
    if (!entry) continue;
    const fits = entry.candidates.filter((c) => w.breaks[kind].every((b) => c.bounds[kind].has(b)));
    if (fits.length > 0) return fits;
  }
  return null;
}

function plainFits(index, w) {
  const entry = index.plain.get(compactKey(w.seq));
  return entry ? entry.candidates.filter((c) => w.breaks.raw.every((b) => c.bounds.has(b))) : [];
}

// A capital word of the window matches only where the spelling is in capitals too.
function capsAgree(spelling, w) {
  const letters = spelling.replace(/[-_\s]/g, "");
  return w.caps.every(([s, e]) => /^[A-Z0-9]+$/.test(letters.slice(s, e)));
}

function splitSpelling(s) {
  const parts = s.split(/([-\s]+)/);
  return { words: parts.filter((_, k) => k % 2 === 0), seps: parts.filter((_, k) => k % 2 === 1).map((p) => (p.includes("-") ? "-" : " ")) };
}

const capFirst = (s) => s.charAt(0).toUpperCase() + s.slice(1);

// tolerated(seq, spelling, ctx) -> the prose window is the same word as the spelling.
function tolerated(seq, spelling, { heading, sentenceStart, codeComment }) {
  const a = splitSpelling(seq);
  const b = splitSpelling(spelling);
  if (a.words.length !== b.words.length || a.seps.join("") !== b.seps.join("")) return false;
  if (codeComment && isAllCapsSpelling(spelling) && a.words.every((x, k) => x === b.words[k].toLowerCase())) return true;
  const lastAt = a.words.length - 1;
  return a.words.every((x, k) => {
    const capital = heading || (sentenceStart && k === 0);
    const forms = k === lastAt ? [x, singular(x)] : [x];
    return forms.some((f) => f === b.words[k] || (capital && f === capFirst(b.words[k])));
  });
}

// lookup(index, w, ctx) -> the drifted term, or null. The naming-convention shortcut (same raw key,
// no whitespace) covers only the `_` terms; a declared spelling is excluded only where it is literal.
// A prose window spelled exactly as a candidate's Homographs entry drops that candidate.
function lookup(index, w, ctx) {
  if (w.mode !== "prose") {
    const fits = identFits(index, w);
    if (fits) {
      const same = fits.filter((c) => c.raw === identKey(w.seq));
      if (same.some((c) => !c.declared) && !w.spaced) return null;
      return closest(same.length > 0 ? same : fits, w.seq).term;
    }
    if (w.mode === "identifier") return null;
  }
  const notHomograph = (c) => w.mode !== "prose" || !c.homographs || !c.homographs.has(w.seq);
  const all = plainFits(index, w).filter((c) => w.mode !== "caps" || capsAgree(c.term, w));
  const fits = all.filter(notHomograph);
  if (all.length > 0 && fits.length === 0) return null;
  if (fits.length > 0) return fits.some((c) => tolerated(w.seq, c.term, ctx)) ? null : closest(fits, w.seq).term;
  if (w.mode === "caps") return null;
  const ids = (identFits(index, w) || []).filter(notHomograph);
  return ids.length > 0 ? closest(ids, w.seq).term : null;
}

// findVariants(text, terms, opts) -> [{ term, variant, line, col }] over one layer. opts.layer
// "ident" makes every word an identifier word; opts.commentLines holds the code comment lines;
// opts.index reuses a built term index. Non-ASCII terms match exactly only.
function findVariants(text, terms, opts) {
  const o = opts || {};
  const index = o.index || indexTerms(terms);
  const lines = String(text == null ? "" : text).split("\n");
  const headings = headingLines(lines);
  const out = [];
  lines.forEach((line, idx) => {
    const words = markedWords(line, o.layer === "ident", index.declared);
    const base = { heading: headings.has(idx), codeComment: !!(o.commentLines && o.commentLines.has(idx + 1)) };
    for (let i = 0; i < words.length; i++) {
      const ctx = Object.assign({ sentenceStart: SENTENCE_HEAD_RE.test(line.slice(0, words[i].start)) }, base);
      let folded = 0;
      for (let n = 1; i + n <= words.length; n++) {
        // An underscore-only word counts 1 so a run of them still ends the scan.
        folded += Math.max(1, foldedLength(words[i + n - 1].text));
        if (folded > index.maxLen) break;
        const w = windowAt(line, words, i, n);
        if (w === null || index.exact.has(w.seq)) continue;
        const term = lookup(index, w, ctx);
        if (term) out.push({ term, variant: w.seq, line: idx + 1, col: words[i].start });
      }
    }
  });
  return out;
}

module.exports = { wordsOf, windowAt, lookup, tolerated, findVariants };
