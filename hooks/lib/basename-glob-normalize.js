#!/usr/bin/env node
// Candidate-basename normalization + glob-aware deny-suffix matching.
//
// PreToolUse hooks see tool_input.command / tool_input.file_path BEFORE the real
// shell expands it and before the OS normalizes it, so the text a hook inspects
// can differ from the on-disk basename the write actually lands on:
//   - shell globs (`s1.off-clearance.claimed*`) expand at execution time
//   - Windows silently strips trailing whitespace and dots from a filename
//   - NTFS alternate-data-stream specs (`name::$DATA`, `name:alt`) write the
//     BASE file, not a file literally named `name::$DATA`
// A `$`-anchored denylist regex applied to the raw text misses all three.
//
// TWO exported entry points, deliberately separated (CPR-3):
//   normalizeCandidateBasename()      — pure text normalization, glob metachars
//                                       are left INTACT.
//   candidateBasenameMatchesAnySuffix() — the denylist decision: normalize, then
//                                       test whether the candidate matches (or,
//                                       for a glob, COULD expand to) any of the
//                                       protected suffixes.
//
// #1780 H-3 (security-scanner round 8+): the previous version resolved `?` and
// `[...]` to a literal filler character inside normalizeCandidateBasename().
// That was NOT the "most permissive interpretation" the old header comment
// claimed — it NARROWED the deny match and was a live bypass: `s1.off-clearanc?`
// normalized to `s1.off-clearancX`, which no longer matched the `$`-anchored
// token regex even though bash expands it onto the real token file. Metachar
// handling now lives in the MATCHER, where a metachar can widen the decision
// (fail-closed) instead of collapsing it to one concrete non-matching string.
//
// #1780 H-4: the ADS strip lives here so every call site (marker-gate.js,
// block-off-clearance-write) inherits it from one place (CPR-4).
//
// RESIDUAL LIMITATION (named exception, CPR-8): a glob whose own literal text
// contributes NOTHING to the protected suffix (`*`, `logs/2024*`) is reported as
// a non-match. Such a pattern is a bulk operation, not evidence of targeting a
// protected file, and treating it as a hit would block ordinary commands like
// `rm -rf build/*`.
//
// #1780 N-2 — WHERE THE EXCEPTION IS QUALIFIED: this module is NAME-ONLY; it
// cannot see where a target resolves, so it cannot itself distinguish
// `rm -rf build/*` from `tee <workflowDir>/*`. The qualifier therefore lives in
// the caller that does have that context:
// hooks/block-off-clearance-write/bash-target-context.js fails closed when a
// glob basename's DIRECTORY resolves at/under getWorkflowDir(), regardless of
// literal overlap.
//
// An earlier revision of this comment credited
// hooks/enforce-worktree/bash-write-scope/marker-gate.js with that containment.
// That was FALSE in the deployed configuration: marker-gate.js runs inside
// enforce-worktree.js, which allows unconditionally from a linked worktree —
// the normal working mode — so the exception had no gate behind it at all.
// marker-gate.js remains defence in depth only; do not cite it as a mitigation.
//
// #1780 round-9 HIGH-2 — BRACE EXPANSION and ANSI-C `$'…'` decoding live in the
// sibling module ./basename-glob-normalize/brace-ansi-expand.js. They differ in
// kind from the glob above: a glob can only ever match a file that ALREADY
// exists, while `{f..f}` / `$'…\x66'` CREATE the exact protected basename. Read
// that file's DIRECTION DISCIPLINE header before touching either: this module is
// a NORMALIZER consumed in the DETECTION direction, so every step of it must
// fail WIDE (emit more candidate spellings) and must never drop or rewrite one.
"use strict";

const { candidateSpellings } = require("./basename-glob-normalize/brace-ansi-expand");

const GLOB_METACHAR_RE = /[*?[]/;

// stripAlternateDataStream(name): drop a trailing NTFS stream spec
// (`::$DATA`, `:$DATA`, `:altname`). A write to `x::$DATA` lands on `x`, so the
// stream spec must not shield `x` from a denylist anchored on `x`.
// The Windows drive-letter colon (`C:`) is explicitly NOT a stream separator —
// scanning starts past it so a drive-qualified string is never truncated to a
// bare letter.
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
// `suffix`, matched right-to-left so the unconstrained prefix costs nothing.
// `[...]` is over-approximated as "any single char" (widening — the safe
// direction for a denylist). `literalMatched` implements the named exception
// documented in the header: at least one LITERAL character of the pattern must
// land inside the protected suffix, so `*` / `2024*` (which commit to nothing)
// are not reported as hits while `s1.off-clearanc*` and `s1.off-clearanc?` are.
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
// Fail-closed on error is the caller's job — this function only ever answers the
// match question.
//
// #1780 round-9 HIGH-2: the question is asked of every spelling the raw text can
// BECOME, not just of the raw text. candidateSpellings() enumerates the brace
// and ANSI-C expansions (widening only — the raw text is always in the set), and
// an enumeration it refused to finish (`overCap`) answers "hit": an expansion
// this scanner could not complete has not been shown to miss the suffix, and the
// detection direction resolves that doubt towards blocking.
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
