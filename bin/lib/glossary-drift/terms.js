"use strict";
// bin/lib/glossary-drift/terms.js — the term index of the drift check: the term records, the
// separator shape of a spelling, and identifierSpellings, the one seam that picks the spellings
// matched as identifiers. The match keys live in hooks/lib/glossary-term.js (shared with the gate).
// Matching rules SSOT: docs/architecture/claude-code/glossary-check.md#matching-rules.

const { normalizeTerm, singular, identWords } = require("../../../hooks/lib/glossary-term");

const ASCII_NORM_RE = /^[a-z0-9]+(?: [a-z0-9]+)*$/;
const ALL_CAPS_WORD_RE = /^[A-Z][A-Z0-9]*$/;

const listOf = (v) => (Array.isArray(v) ? v.map((s) => String(s)).filter((s) => s !== "") : []);

// termRecord(t) -> { term, identifiers, homographs }; a string is a record with no fields.
function termRecord(t) {
  if (t !== null && typeof t === "object") {
    return { term: String(t.term == null ? "" : t.term).trim(), identifiers: listOf(t.identifiers), homographs: listOf(t.homographs) };
  }
  return { term: String(t == null ? "" : t).trim(), identifiers: [], homographs: [] };
}

// mergeRecords(terms) -> Map term -> record; the records of one term pool their fields.
function mergeRecords(terms) {
  const out = new Map();
  for (const t of terms || []) {
    const r = termRecord(t);
    if (r.term === "") continue;
    const prev = out.get(r.term);
    if (!prev) { out.set(r.term, r); continue; }
    prev.identifiers = [...new Set(prev.identifiers.concat(r.identifiers))];
    prev.homographs = [...new Set(prev.homographs.concat(r.homographs))];
  }
  return out;
}

// identifierSpellings(records) -> Map spelling -> { term, declared }: the terms holding `_`
// (declared: false) and the spellings of the Identifier fields (declared: true, owned by the term).
function identifierSpellings(records) {
  const out = new Map();
  const recs = [...mergeRecords(records).values()];
  for (const r of recs) if (r.term.includes("_")) out.set(r.term, { term: r.term, declared: false });
  for (const r of recs) {
    for (const s of r.identifiers) if (!out.has(s)) out.set(s, { term: r.term, declared: true });
  }
  return out;
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
  const id = cand.spelling ?? cand.term;
  if (entry.spellings.has(id)) return;
  entry.spellings.add(id);
  entry.candidates.push(cand);
}

// -> { exact, plain, identFolded, identRaw, declared, maxLen }: each map is key -> { spellings,
// candidates }. A prose candidate is { term, bounds, seps, homographs }; an identifier candidate is
// { term, raw, bounds: { raw, folded }, seps, declared, spelling, homographs }. Terms sharing a key
// are all kept, sorted, for lookup to choose from. terms: strings or term records.
function indexTerms(terms) {
  const records = mergeRecords(terms);
  const exact = new Set(records.keys());
  const plain = new Map();
  const identFolded = new Map();
  const identRaw = new Map();
  const declared = [];
  let maxLen = 0;
  for (const [spelling, owner] of identifierSpellings([...records.values()])) {
    const words = identWords(spelling);
    if (!words.every((w) => /^[a-z0-9]+$/.test(w))) continue;
    const folded = words.map(singular);
    const cand = {
      term: owner.term, raw: words.join(""), bounds: { raw: boundsOf(words), folded: boundsOf(folded) },
      seps: separatorsOf(spelling), declared: owner.declared, spelling, homographs: new Set(records.get(owner.term).homographs),
    };
    addTo(identRaw, cand.raw, cand);
    addTo(identFolded, folded.join(""), cand);
    maxLen = Math.max(maxLen, cand.raw.length);
    if (owner.declared) { exact.add(spelling); declared.push(spelling); }
  }
  for (const r of records.values()) {
    if (r.term.includes("_")) continue;
    const parts = normalizeTerm(r.term).split(" ");
    if (!ASCII_NORM_RE.test(parts.join(" "))) continue;
    addTo(plain, parts.join(""), { term: r.term, bounds: boundsOf(parts), seps: separatorsOf(r.term), homographs: new Set(r.homographs) });
    maxLen = Math.max(maxLen, parts.join("").length);
  }
  for (const map of [plain, identFolded, identRaw]) {
    for (const e of map.values()) e.candidates.sort((a, b) => (a.term < b.term ? -1 : a.term > b.term ? 1 : 0));
  }
  return { exact, plain, identFolded, identRaw, declared, maxLen };
}

// The candidate whose separators differ least from the variant's; ties keep the sorted order.
function closest(candidates, seq) {
  const seps = separatorsOf(seq);
  const dist = (c) => [...c.seps].filter((s) => !seps.has(s)).length + [...seps].filter((s) => !c.seps.has(s)).length;
  return candidates.reduce((best, c) => (dist(c) < dist(best) ? c : best));
}

module.exports = {
  termRecord, separatorsOf, closest, indexTerms, identifierSpellings, isAllCapsSpelling,
};
