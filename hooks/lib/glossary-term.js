"use strict";
// hooks/lib/glossary-term.js — the one term normalization of the glossary checks (#2529):
// drift detection, grant matching and the concern-ledger grant all compare normalizeTerm values.
// Its source is one of the RULE_MODULES of the glossary-check fingerprint.

// A singular ending in -us / -sis / -ss keeps its s (status, analysis, process); -uses and -yses
// return to it. Other irregular plurals (-ves, -oes, indices) and -us plurals (menus) are out of scope.
function singular(word) {
  if (/ies$/.test(word) && word.length > 3) return word.slice(0, -3) + "y";
  if (/yses$/.test(word)) return word.slice(0, -2) + "is";
  if (/(s|x|z|ch|sh)es$/.test(word)) return word.replace(/es$/, "");
  if (/s$/.test(word) && !/(ss|us|sis)$/.test(word) && word.length > 1) return word.slice(0, -1);
  return word;
}

// An acronym plural (GPUs, APIs) drops its s before lowercasing hides the acronym.
const ACRONYM_PLURAL_RE = /(^|[-\s])([A-Z][A-Z0-9]+)s$/;

// normalizeTerm(s) -> lowercase, hyphen / whitespace runs folded to one space, the last ASCII
// word singularized; non-ASCII characters are kept as they are.
function normalizeTerm(s) {
  const raw = String(s == null ? "" : s).trim();
  const folded = raw.toLowerCase().replace(/[-\s]+/g, " ").trim();
  if (ACRONYM_PLURAL_RE.test(raw)) return folded.slice(0, -1);
  const m = /(^|\s)([a-z]+)$/.exec(folded);
  if (!m) return folded;
  return folded.slice(0, folded.length - m[2].length) + singular(m[2]);
}

// A term is printed inside the double-quoted, shell-copyable GLOSSARY_ACCEPTED echo command, so
// any character the shell expands or splits there (CWE-78) is refused at every inflow.
const UNSAFE_TERM_CHAR_RE = /[$`"\\()<>;|&=\u0000-\u001f\u007f]/g;

// unsafeTermChars(term) -> the distinct forbidden characters of term in first-appearance order.
function unsafeTermChars(term) {
  return [...new Set(String(term == null ? "" : term).match(UNSAFE_TERM_CHAR_RE) || [])];
}

// describeTermChars(chars) -> a readable list: printable characters quoted, controls as U+XXXX.
function describeTermChars(chars) {
  return chars.map((c) => {
    const cp = c.charCodeAt(0);
    return cp < 0x20 || cp === 0x7f ? "U+" + cp.toString(16).toUpperCase().padStart(4, "0") : "'" + c + "'";
  }).join(", ");
}

module.exports = { normalizeTerm, unsafeTermChars, describeTermChars };
