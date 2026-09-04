#!/usr/bin/env node
// Candidate-basename normalization + glob-aware deny-suffix matching.
//
// PreToolUse hooks see tool_input text before the shell expands it, so a
// `$`-anchored regex on raw text misses shell globs, Windows trailing
// whitespace/dot stripping, and NTFS `name::$DATA` specs writing the BASE file.
// Two entry points (CPR-SC): normalizeCandidateBasename() normalizes text with
// glob metachars INTACT; candidateBasenameMatchesAnySuffix() then decides — for
// a glob, whether it COULD expand to a protected suffix, so a metachar widens
// the decision. A glob contributing NO literal text to the suffix is a
// non-match. Brace/ANSI-C expansion: ./basename-glob-normalize/brace-ansi-expand.js.
"use strict";

const { candidateSpellings } = require("./basename-glob-normalize/brace-ansi-expand");

const GLOB_METACHAR_RE = /[*?[]/;

// stripAlternateDataStream(name): drop a trailing NTFS stream spec
// (`::$DATA`, `:$DATA`, `:altname`) — a write to `x::$DATA` lands on `x`, so
// it must not shield `x` from a denylist anchored on `x`. The drive-letter
// colon (`C:`) is NOT a stream separator; scanning starts past it.
function stripAlternateDataStream(name) {
  const start = /^[A-Za-z]:/.test(name) ? 2 : 0;
  const idx = name.indexOf(":", start);
  return idx === -1 ? name : name.slice(0, idx);
}

// The tail the FILESYSTEM discards from a component (Windows drops trailing
// spaces and dots), exported as an unanchored character class so every reading
// of "the same basename" is derived from this one spelling (CPR-SSOT). The
// mention gates in ../protected-basenames.js embed it: a gate that stopped at
// the raw tail would disown `<sid>.off-clearance.`, which the classifier here
// still calls a token and which the OS creates as the real token (#1821).
const STRIPPABLE_TAIL_CHARS = "[ \\t.]";
const STRIPPABLE_TAIL_RE = new RegExp(STRIPPABLE_TAIL_CHARS + "+$");

// normalizeCandidateBasename(basename): quote strip → ADS strip → trailing
// whitespace/dot strip. Glob metachars are preserved for the matcher below.
function normalizeCandidateBasename(basename) {
  if (typeof basename !== "string") return basename;
  const unquoted = basename.replace(/^["']+|["']+$/g, "");
  return stripAlternateDataStream(unquoted).replace(STRIPPABLE_TAIL_RE, "");
}

function hasGlobMetachar(text) {
  return typeof text === "string" && GLOB_METACHAR_RE.test(text);
}

// parseGlobAtoms(pattern): one atom per glob unit — a literal char, `any`
// (`?` or a `[...]` class, both exactly one char), or `star` (`*`, zero or
// more). A `[` with no closing `]` is not a class and stays literal.
function parseGlobAtoms(pattern) {
  const atoms = [];
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "*") { atoms.push({ t: "star" }); continue; }
    if (c === "?") { atoms.push({ t: "any" }); continue; }
    if (c === "[") {
      const close = pattern.indexOf("]", i + 1);
      if (close !== -1) { atoms.push({ t: "any" }); i = close; continue; }
    }
    atoms.push({ t: "lit", c: c.toLowerCase() });
  }
  return atoms;
}

// globCanEndWith(atoms, suffix): true iff some expansion of the glob ENDS WITH
// `suffix`, matched right-to-left. `[...]` is over-approximated as "any single
// char" (widening). `literalMatched` implements the header's named exception:
// at least one LITERAL char must land inside the suffix, so `*`/`2024*` (which
// commit to nothing) are not hits while `s1.off-clearanc*` is.
function globCanEndWith(atoms, suffix) {
  const s = suffix.toLowerCase();
  const rev = atoms.slice().reverse();
  const visited = new Set();

  function walk(ai, si, literalMatched) {
    if (si < 0) return literalMatched;      // whole suffix consumed by the pattern tail
    if (ai >= rev.length) return false;     // pattern ran out before the suffix did
    const key = ai + ":" + si + ":" + (literalMatched ? 1 : 0);
    if (visited.has(key)) return false;     // ai strictly increases → no cycles; a
    visited.add(key);                       // revisit can only be a known-false state
    const a = rev[ai];
    if (a.t === "star") {
      for (let k = 0; k <= si + 1; k++) {   // star absorbs k of the remaining suffix chars
        if (walk(ai + 1, si - k, literalMatched)) return true;
      }
      return false;
    }
    if (a.t === "any") return walk(ai + 1, si - 1, literalMatched);
    if (a.c !== s[si]) return false;
    return walk(ai + 1, si - 1, true);
  }

  return walk(0, s.length - 1, false);
}

// oneSpellingMatches(spelling, suffixes): the decision for ONE candidate
// spelling. Non-glob candidates take a plain case-insensitive endsWith
// (identical to the `$`-anchored regex the callers used before); glob candidates
// take the could-expand-to matcher above.
// `stemAllowed(stem)` (#2108) is consulted ONLY on the non-glob branch: there the
// stem is knowable, so a suffix hit whose stem cannot confer clearance is a false
// positive. A glob's post-expansion stem is unprovable, so the glob branch keeps
// matching on the suffix alone (named exception).
function oneSpellingMatches(spelling, suffixes, stemAllowed) {
  const norm = normalizeCandidateBasename(spelling);
  if (typeof norm !== "string" || norm === "") return false;
  if (!GLOB_METACHAR_RE.test(norm)) {
    const lower = norm.toLowerCase();
    const hit = suffixes.find((suffix) => lower.endsWith(String(suffix).toLowerCase()));
    if (hit === undefined) return false;
    if (typeof stemAllowed !== "function") return true;
    return stemAllowed(norm.slice(0, norm.length - String(hit).length));
  }
  const atoms = parseGlobAtoms(norm);
  return suffixes.some((suffix) => globCanEndWith(atoms, String(suffix)));
}

// candidateBasenameMatchesAnySuffix(basename, suffixes): the denylist decision.
// Asked of every spelling the raw text can BECOME (candidateSpellings()
// enumerates brace/ANSI-C expansions, widening only), not just the raw text.
// An enumeration that gave up (`overCap`) answers "hit": an incomplete
// expansion has not been shown to miss the suffix, so detection direction
// resolves the doubt toward blocking. Fail-closed on error is the caller's job.
function candidateBasenameMatchesAnySuffix(basename, suffixes, opts) {
  if (typeof basename !== "string" || basename === "" || !Array.isArray(suffixes)) return false;
  const { candidates, overCap } = candidateSpellings(basename);
  if (overCap) return true;
  const stemAllowed = opts && opts.stemAllowed;
  return candidates.some((c) => oneSpellingMatches(c, suffixes, stemAllowed));
}

module.exports = {
  STRIPPABLE_TAIL_CHARS,
  normalizeCandidateBasename,
  candidateBasenameMatchesAnySuffix,
  hasGlobMetachar,
};
