// hooks/block-off-clearance-write/bash-scan/assignment-text.js
// "Which preceding segments set a shell variable, and what text should a later
// segment be judged against?" — the assignment-chain half of ./scan.js
// (file-split, rules/coding/file-split.md Pattern A).
"use strict";

const { resolveEffectiveSegment } = require("../../lib/command-ir");
// H-4 (#1780 round-4): `$ENV:` is the same scope prefix as `$env:` in
// PowerShell — this file's pwsh-assignment recognizers must fold it exactly as
// interpreter-scan.js does, or one scanner sanctions a spelling the other
// treats as unknown (CPR-5).
const { PWSH_ENV_PREFIX } = require("../../lib/case-insensitive-literal");
const { sourceOrderView } = require("../../lib/substitution-spans");

// A segment is "assignment-only" when it is nothing but VAR=val prefixes
// with no real command (resolveEffectiveSegment returns null for exactly
// this shape, among others already excluded by the cmd0 check below).
//
// pwsh sibling (round-6 F-1 verification follow-up): `$env:NAME=value` is
// pwsh's own assignment syntax — the direct sibling of bash `NAME=value` —
// but its cmd0 starts with `$`, so the bash-only regex below never matched
// it. A preceding `$env:A='<token>'; pwsh -Command "...$env:A..."` therefore
// never had its assignment folded into precedingAssignmentChainText's
// gateText, and the following pwsh segment's Tier-1 gate
// (hitsProtectedViaInterpreter) checked only that segment's own text — which
// never spells the token — so the whole invocation fell through as
// "nothing to protect" even though the pwsh body dereferences the token via
// $env:A. Recognized only in its single-token, no-space form (`$env:A=val`,
// matching how FLAG_ALTS/PWSH_ENV already model this shape elsewhere);
// spaced forms (`$env:A = val`) are not modeled and stay fail-closed
// via the bash-assignment branch below returning false (CPR-5: same
// intentionally-narrow-but-symmetric treatment as the bash sibling).
const PWSH_ENV_ASSIGN_ONLY_RE = new RegExp(String.raw`^\$${PWSH_ENV_PREFIX}[A-Za-z_][A-Za-z0-9_]*=\S`);

function isAssignmentOnlySegment(seg) {
  if (!seg || typeof seg.cmd0 !== "string" || seg.cmd0 === "") return false;
  if (PWSH_ENV_ASSIGN_ONLY_RE.test(seg.cmd0) && Array.isArray(seg.argv) && seg.argv.length === 0) return true;
  if (!/^[A-Za-z_][A-Za-z0-9_]*=/.test(seg.cmd0)) return false;
  return resolveEffectiveSegment(seg) === null;
}

function precedingAssignmentChainText(segments, idx) {
  let out = "";
  for (let j = idx - 1; j >= 0; j--) {
    const prev = segments[j];
    if (!isAssignmentOnlySegment(prev)) break;
    out = prev.rawText + "\n" + out;
  }
  return out;
}

// priorAssignmentsText(segments, idx): every assignment-only segment BEFORE
// `idx`, nearest first. Wider than precedingAssignmentChainText on purpose, and
// used only for WRITE-TARGET resolution.
//
// The contiguity requirement above exists to keep unrelated segments out of the
// INTERPRETER gate text, where folding in a distant `cd .../off-clearance-1780/`
// would arm the gate for an unrelated invocation. A write target has no such
// hazard: it is resolved, not merely mentioned. And contiguity is simply wrong
// for shell-variable scope — in `S=<marker>; echo f | tee <wf>/s1$S` the plain
// `echo f` segment sits between the assignment and the use, yet the parent
// shell has already set `S` and expands `$S` before forking the pipeline, so
// the write really does land on the marker (#1780 N-1).
//
// Nearest-first ordering makes the most recent assignment win the single-match
// lookup in ../bash-target-context.js, mirroring shell reassignment semantics.
//
// #1780 round-13 (unset staleness): reassignment was already modelled by that
// nearest-first ordering, but `unset` was not — `S=<marker>; unset S; tee $S`
// kept attributing the marker value to `S` for every later segment, so a write
// the shell resolves to an EMPTY expansion was reported as landing on protected
// state. That is a false BLOCK, i.e. the over-blocking failure mode this hook has
// regressed into before, so honouring `unset` here is a correction in the safe
// direction; it can only withdraw evidence the shell itself has already
// discarded. Scoped deliberately to what can be proven from the text: a bash
// `unset` segment naming the variable. Values injected by a WRAPPER
// (`env -u`, `export` in a non-assignment-only segment) and subshell scoping
// `( … )` are NOT modelled and keep their previous, wider treatment.
const UNSET_FLAG_RE = /^-/;

// unsetVarsOfSegment(seg): the variable names a `unset A B` segment clears, or
// null when the segment is not an unset at all. `unset` is a bash builtin, so
// the name is matched case-SENSITIVELY (unlike the pwsh cmdlet names folded in
// ../bash-target-context.js).
function unsetVarsOfSegment(seg) {
  if (!seg || seg.cmd0 !== "unset" || !Array.isArray(seg.argv)) return null;
  return seg.argv
    .map((a) => String(a).replace(/^["']|["']$/g, ""))
    .filter((a) => a !== "" && !UNSET_FLAG_RE.test(a));
}

// assignedNamesOfSegment(seg): the variable names an assignment-only segment
// sets (`A=1 B=2` sets both). Used only to drop assignments a LATER `unset`
// has already invalidated.
const BASH_ASSIGN_NAME_RE = /^([A-Za-z_][A-Za-z0-9_]*)=/;
const PWSH_ENV_ASSIGN_NAME_RE = new RegExp(String.raw`^\$${PWSH_ENV_PREFIX}([A-Za-z_][A-Za-z0-9_]*)=`);

function assignedNamesOfSegment(seg) {
  const tokens = [seg.cmd0].concat(Array.isArray(seg.argv) ? seg.argv : []);
  const names = [];
  for (const tok of tokens) {
    if (typeof tok !== "string") continue;
    const m = BASH_ASSIGN_NAME_RE.exec(tok) || PWSH_ENV_ASSIGN_NAME_RE.exec(tok);
    if (m) names.push(m[1]);
  }
  return names;
}

function priorAssignmentsText(segments, idx) {
  // Same source-order recovery as commandCwd() — an appended substitution-span
  // segment's array index is not its position in the command text (#1780
  // round-13; see ../../lib/substitution-spans.js).
  const view = sourceOrderView(segments, idx);
  const segs = view.segments;
  const parts = [];
  // Walking BACKWARDS from the use site, every `unset` encountered is LATER in
  // the command than the assignments still to be visited, so its names stay
  // dead for the remainder of the walk.
  const unset = new Set();
  for (let j = view.idx - 1; j >= 0; j--) {
    const prev = segs[j];
    const cleared = unsetVarsOfSegment(prev);
    if (cleared) {
      for (const name of cleared) unset.add(name);
      continue;
    }
    if (!isAssignmentOnlySegment(prev)) continue;
    // A multi-assignment segment is dropped only when EVERY name it sets was
    // unset — dropping it for a partial hit would also discard the surviving
    // sibling's value, which would be a widening in the unsafe direction. The
    // residue (a stale name inside a segment kept for its sibling) keeps its
    // previous, wider treatment.
    const names = unset.size > 0 ? assignedNamesOfSegment(prev) : [];
    // names.length > 0 guard: a segment whose assignment shape this recognizer
    // could not name must never be dropped by the vacuous-truth reading of
    // every() — "unknown" stays "kept" (fail wide).
    if (names.length > 0 && names.every((n) => unset.has(n))) continue;
    parts.push(prev.rawText);
  }
  return parts.join("\n");
}

module.exports = {
  PWSH_ENV_ASSIGN_ONLY_RE,
  isAssignmentOnlySegment,
  precedingAssignmentChainText,
  priorAssignmentsText,
};
