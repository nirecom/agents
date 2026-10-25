"use strict";
// bin/lib/glossary-drift/terms.js — the term index of the drift check: the match keys, the
// separator shape of a spelling, and identifierSpellings, the one seam that picks the terms
// matched as identifiers. Matching rules SSOT:
// docs/architecture/claude-code/glossary-check.md#matching-rules.

const { normalizeTerm, singular } = require("../../../hooks/lib/glossary-term");

const ASCII_NORM_RE = /^[a-z0-9]+(?: [a-z0-9]+)*$/;
const ALL_CAPS_WORD_RE = /^[A-Z][A-Z0-9]*$/;

// The prose key: the normalized form with the word separators stripped, so a split (`work-flow`)
// or a merge (`glossarydrift`) of a term meets the same key whatever its word count.
const compactKey = (s) => normalizeTerm(s).replace(/ /g, "");
const identWords = (s) => s.toLowerCase().split(/[-_\s]+/).filter((w) => w !== "");
// The raw identifier key folds case and every separator; the folded key also singularizes each word.
const identKey = (s) => s.toLowerCase().replace(/[-_\s]+/g, "");
const identFoldedKey = (s) => identWords(s).map(singular).join("");

// identifierSpellings(terms) -> the spellings matched as identifiers (today: the ones holding `_`).
function identifierSpellings(terms) {
  return new Set((terms || []).filter((t) => t.includes("_")));
}

// isAllCapsSpelling(spelling) -> every word of the spelling is written in capitals (`WF-CODE`).
function isAllCapsSpelling(spelling) {
  return String(spelling).split(/[-\s]+/).every((w) => ALL_CAPS_WORD_RE.test(w));
}

// The separators of a spelling as "offset:char" entries (offset in letters, whitespace -> " ").
function separatorsOf(s) {
  const out = new Set();
  let at = 0;
  for (const ch of s) {
    if (/[-_\s]/.test(ch)) out.add(`${at}:${/\s/.test(ch) ? " " : ch}`);
    else at += 1;
  }
  return out;
}

// The key offsets of the word breaks of a word list.
function boundsOf(words) {
  const out = new Set();
  let at = 0;
  for (const w of words.slice(0, -1)) { at += w.length; out.add(at); }
  return out;
}

function addTo(map, key, cand) {
  if (!map.has(key)) map.set(key, { spellings: new Set(), candidates: [] });
  const entry = map.get(key);
  if (entry.spellings.has(cand.term)) return;
  entry.spellings.add(cand.term);
  entry.candidates.push(cand);
}

// -> { exact, plain, identFolded, identRaw, maxLen }: each map is key -> { spellings, candidates }.
// A prose candidate is { term, bounds, seps }; an identifier candidate is { term, raw, bounds:
// { raw, folded }, seps }. Terms sharing a key are all kept, sorted, for lookup to choose from.
function indexTerms(terms) {
  const exact = new Set();
  for (const t of terms || []) {
    const term = String(t == null ? "" : t).trim();
    if (term !== "") exact.add(term);
  }
  const idents = identifierSpellings([...exact]);
  const plain = new Map();
  const identFolded = new Map();
  const identRaw = new Map();
  let maxLen = 0;
  for (const term of exact) {
    const seps = separatorsOf(term);
    if (idents.has(term)) {
      const words = identWords(term);
      if (!words.every((w) => /^[a-z0-9]+$/.test(w))) continue;
      const folded = words.map(singular);
      const cand = { term, raw: words.join(""), bounds: { raw: boundsOf(words), folded: boundsOf(folded) }, seps };
      addTo(identRaw, cand.raw, cand);
      addTo(identFolded, folded.join(""), cand);
      maxLen = Math.max(maxLen, cand.raw.length);
      continue;
    }
    const parts = normalizeTerm(term).split(" ");
    if (!ASCII_NORM_RE.test(parts.join(" "))) continue;
    addTo(plain, parts.join(""), { term, bounds: boundsOf(parts), seps });
    maxLen = Math.max(maxLen, parts.join("").length);
  }
  for (const map of [plain, identFolded, identRaw]) {
    for (const e of map.values()) e.candidates.sort((a, b) => (a.term < b.term ? -1 : a.term > b.term ? 1 : 0));
  }
  return { exact, plain, identFolded, identRaw, maxLen };
}

// The candidate whose separators differ least from the variant's; ties keep the sorted order.
function closest(candidates, seq) {
  const seps = separatorsOf(seq);
  const dist = (c) => [...c.seps].filter((s) => !seps.has(s)).length + [...seps].filter((s) => !c.seps.has(s)).length;
  return candidates.reduce((best, c) => (dist(c) < dist(best) ? c : best));
}

module.exports = {
  compactKey, identKey, identFoldedKey, separatorsOf, closest, indexTerms, identifierSpellings, isAllCapsSpelling,
};
