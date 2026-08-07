#!/usr/bin/env node
// Candidate-basename normalization + glob-aware deny-suffix matching.
//
// PreToolUse hooks see tool_input text before the shell expands it and the OS
// normalizes it, so a `$`-anchored regex on raw text misses: shell globs that
// expand at execution time, Windows stripping trailing whitespace/dots, and
// NTFS alt-data-stream specs (`name::$DATA`) that write the BASE file.
//
// Two entry points (CPR-SC): normalizeCandidateBasename() does pure text
// normalization, glob metachars left INTACT; candidateBasenameMatchesAnySuffix()
// normalizes then decides — for a glob, whether it COULD expand to a protected
// suffix. Metachar handling lives in the matcher so a metachar WIDENS the
// decision (fail-closed) rather than collapsing to one non-matching string.
//
// Named exception (CPR-UNV): a glob whose literal text contributes NOTHING to
// the suffix (`*`, `logs/2024*`) is a non-match — else `rm -rf build/*` would
// block. This module is name-only; the caller (bash-target-context.js)
// additionally fails closed when a glob's directory resolves under the
// workflow dir.
//
// Brace/ANSI-C `$'...'` expansion lives in the sibling
// ./basename-glob-normalize/brace-ansi-expand.js — read its DIRECTION
// DISCIPLINE header before touching either module.
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

// normalizeCandidateBasename(basename): quote strip → ADS strip → trailing
// whitespace/dot strip. Glob metachars are preserved for the matcher below.
function normalizeCandidateBasename(basename) {
  if (typeof basename !== "string") return basename;
  const unquoted = basename.replace(/^["']+|["']+$/g, "");
  return stripAlternateDataStream(unquoted).replace(/[ \t.]+$/, "");
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
function oneSpellingMatches(spelling, suffixes) {
  const norm = normalizeCandidateBasename(spelling);
  if (typeof norm !== "string" || norm === "") return false;
  if (!GLOB_METACHAR_RE.test(norm)) {
    const lower = norm.toLowerCase();
    return suffixes.some((suffix) => lower.endsWith(String(suffix).toLowerCase()));
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
function candidateBasenameMatchesAnySuffix(basename, suffixes) {
  if (typeof basename !== "string" || basename === "" || !Array.isArray(suffixes)) return false;
  const { candidates, overCap } = candidateSpellings(basename);
  if (overCap) return true;
  return candidates.some((c) => oneSpellingMatches(c, suffixes));
}

module.exports = {
  normalizeCandidateBasename,
  candidateBasenameMatchesAnySuffix,
  hasGlobMetachar,
};
