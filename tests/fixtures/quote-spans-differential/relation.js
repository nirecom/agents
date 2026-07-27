"use strict";
// tests/fixtures/quote-spans-differential/relation.js
// Machine-checked old-vs-new relation for the #1569 differential runner.
//
// The allowlist may not be a rubber stamp. Every allowlisted diff has to declare
// WHICH relation it claims to hold, and this module proves that relation from
// the two outputs instead of spot-checking a hard-coded token list:
//
//   class: unchanged   — the scan is ok:false, so the transform must return the
//                        INPUT byte-for-byte. Exact pin, nothing to argue about.
//   class: expose-more — the new output must expose a SUPERSET of the old one:
//                        every word atom of the old output must survive with at
//                        least the same multiplicity, and no metacharacter the
//                        old output exposed may disappear. This is the security
//                        direction: hiding `rm -rf x` from the write detector
//                        fails even when allowlisted.
//   class: blank-more  — the new output blanks MORE than the old one (the old
//                        regex leaked text out of a quote span). Two obligations:
//                        the new output may not INVENT any word atom the old
//                        output did not have, and every atom it drops must be
//                        one that occurs in the input ONLY inside a quote span.
//                        A new implementation that swallowed unquoted command
//                        text would fail the second obligation.
//
// Word atoms, not raw whitespace tokens: blanking rewrites the punctuation
// around a word (`printf '` vs `$(printf '')`), so comparing raw tokens would
// report differences that are pure quote-artifact. Atoms are the identifier /
// path / flag runs — exactly the text a write-pattern regex reads — and the
// metacharacter check below covers the punctuation side separately.

// Metacharacters whose DISAPPEARANCE from the new output is a security
// regression (the write detector keys on them).
const METACHARS = [
  ">", ">>", "|", ";", "&&", "&", "$(", "`", "<(", ">(", "\n",
];

const ATOM_RE = /[A-Za-z0-9_./-]+/g;

// Multiset of word atoms.
function atoms(s) {
  const m = new Map();
  for (const a of String(s).match(ATOM_RE) || []) m.set(a, (m.get(a) || 0) + 1);
  return m;
}

// Atoms of `a` that `b` does not carry with at least the same multiplicity.
function atomsMissing(a, b) {
  const A = atoms(a);
  const B = atoms(b);
  const lost = [];
  for (const [k, n] of A) if ((B.get(k) || 0) < n) lost.push(k);
  return lost;
}

function metacharsMissing(oldOut, newOut) {
  return METACHARS.filter((t) => oldOut.indexOf(t) !== -1 && newOut.indexOf(t) === -1);
}

// The input's word atoms that do NOT sit wholly inside a dq/sq/ansic span —
// i.e. the live command text a write detector would read. An atom that straddles
// a span boundary counts as unquoted (conservative).
//
// Position-aware ON PURPOSE: an earlier substring scan (`input.indexOf(atom)`)
// reported the dropped atom "s" as unquoted because it matched inside the word
// "i(ss)ue", which turned a legitimate blank-more drop into a false leak
// report. Atom identity has to be compared atom-to-atom, not char-to-char.
function unquotedAtomsOf(input, spansApi) {
  if (!spansApi || typeof spansApi.scanSpans !== "function") return null; // undecidable
  const scan = spansApi.scanSpans(input);
  if (!scan || !Array.isArray(scan.spans)) return null;
  const quoted = scan.spans.filter((s) => s.kind === "dq" || s.kind === "sq" || s.kind === "ansic");
  const live = new Set();
  const re = new RegExp(ATOM_RE.source, "g");
  let m;
  while ((m = re.exec(input)) !== null) {
    const i = m.index;
    const j = i + m[0].length;
    if (!quoted.some((s) => i >= s.start && j <= s.end)) live.add(m[0]);
  }
  return live;
}

// True when `atom` never occurs as a live (unquoted) word atom of `input`.
// Used by class: blank-more to prove a dropped atom was quoted text the old
// implementation leaked, never live command text the new one swallowed.
function onlyInsideQuotes(atom, input, spansApi) {
  const live = unquotedAtomsOf(input, spansApi);
  if (live === null) return null;
  return !live.has(atom);
}

// Returns "" when the declared relation holds, else the reason it does not.
// `entry` = { direction, cls, expose, reason }.
function checkRelation(entry, input, oldOut, newOut, spansApi) {
  if (entry.direction !== "direction: stricter") {
    return "allowlist entry must be annotated `direction: stricter`, got " + JSON.stringify(entry.direction);
  }
  if (!entry.cls) return "allowlist entry is missing its `class:` field";
  if (!entry.expose) return "allowlist entry is missing its `expose:` field";

  if (entry.cls === "unchanged") {
    if (newOut !== input) {
      return "class: unchanged requires the new output to be the input byte-for-byte, got " + JSON.stringify(newOut);
    }
  } else if (entry.cls === "expose-more") {
    const lost = atomsMissing(oldOut, newOut);
    if (lost.length) return "class: expose-more but the new output DROPS word atoms " + JSON.stringify(lost);
    const meta = metacharsMissing(oldOut, newOut);
    if (meta.length) return "class: expose-more but the new output HIDES metacharacters " + JSON.stringify(meta);
  } else if (entry.cls === "blank-more") {
    const invented = atomsMissing(newOut, oldOut);
    if (invented.length) return "class: blank-more but the new output INVENTS word atoms " + JSON.stringify(invented);
    for (const a of atomsMissing(oldOut, newOut)) {
      const inside = onlyInsideQuotes(a, input, spansApi);
      if (inside === null) return "class: blank-more could not be verified — the span API is unavailable";
      if (inside === false) {
        return "class: blank-more dropped word atom " + JSON.stringify(a) +
               " that occurs OUTSIDE a quote span in the input (live command text, not a leak)";
      }
    }
  } else {
    return "unknown class " + JSON.stringify(entry.cls);
  }

  // Every class additionally has to keep the literal the allowlist row promises
  // stays visible. `expose: -` opts out only when the row's own class already
  // pins the whole output (class: unchanged).
  if (entry.expose !== "-" && newOut.indexOf(entry.expose) === -1) {
    return "the new output does not expose the promised literal " + JSON.stringify(entry.expose);
  }
  if (entry.expose === "-" && entry.cls !== "unchanged") {
    return "`expose: -` is only allowed for class: unchanged rows";
  }
  return "";
}

module.exports = {
  atoms, atomsMissing, metacharsMissing, unquotedAtomsOf, onlyInsideQuotes,
  checkRelation, METACHARS,
};
