"use strict";

// Literal-variable tracking for recursive-delete-scan.js: does an `rm`
// segment reference a tracked flag variable built from an assignment
// (`FLAGS=-rf; rm $FLAGS d`) or several concatenated ones (`A=-; B=rf;
// rm $A$B d`, #2210 round8 item 7)? Split out of the parent when it crossed
// the 500-line hard limit.

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  ASSIGN_RE,
} = require("../../bash-write-patterns/segment-utils");
const { isRecursiveRmFlagToken } = require("../rm");

function segTokens(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  return [seg.cmd0, ...argv].filter((t) => typeof t === "string" && t !== "");
}

// A bare `NAME=VALUE [NAME=VALUE...]` segment — an assignment with no command.
function isPureAssignmentSegment(seg) {
  const toks = segTokens(seg);
  return toks.length > 0 && toks.every((t) => ASSIGN_RE.test(t));
}

// Only a fully-literal RHS (no `$`/backtick/`(`) is trackable — anything else
// is dynamic and the name is dropped rather than guessed at.
function literalAssignmentValue(rhs) {
  if (typeof rhs !== "string") return null;
  let v = rhs;
  if ((v.startsWith("'") && v.endsWith("'") && v.length >= 2) ||
      (v.startsWith('"') && v.endsWith('"') && v.length >= 2)) {
    v = v.slice(1, -1);
  }
  if (v.includes("$") || v.includes("`") || v.includes("(")) return null;
  return v;
}

// Track literal VALUES (not just a recursive/non-recursive boolean) so a
// later reference can be reconstructed even when the flag is built from
// several variables concatenated together (`A=-; B=rf; rm $A$B dir`, #2210
// round8 item 7). A later `unset` or a non-literal reassignment drops the
// name again, so a reassignment to a safe value is not treated as still
// dangerous. Contract: detail.md Step 4 step 2-0 / 0'.
function applyAssignments(seg, values) {
  for (const tok of segTokens(seg)) {
    const eq = tok.indexOf("=");
    if (eq === -1) continue;
    const name = tok.slice(0, eq);
    const lit = literalAssignmentValue(tok.slice(eq + 1));
    if (lit === null) values.delete(name);
    else values.set(name, lit);
  }
}

function applyUnset(seg, values) {
  for (const tok of resolveEffectiveArgv(seg)) values.delete(tok);
}

// `export`/`declare`/`typeset`/`readonly`/`local` carry NAME=VALUE assignments
// alongside their own option flags, so a plain isPureAssignmentSegment test
// (every token is an assignment) misses `export FLAGS=-rf` (#2210 N5). Filter
// to just the argv tokens shaped like an assignment before reusing applyAssignments.
const ASSIGNMENT_CARRYING_CMDS = new Set(["export", "declare", "typeset", "readonly", "local"]);

function applyAssignmentCarryingCommand(seg, values) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const assignTokens = argv.filter((t) => typeof t === "string" && ASSIGN_RE.test(t));
  applyAssignments({ cmd0: null, argv: assignTokens }, values);
}

// Replace every `$NAME` / `${NAME}` / `${NAME<op>...}` reference to a tracked
// variable with its literal value, leaving anything unresolved untouched.
// A global replace naturally reassembles split-variable concatenation
// (`$A$B` with A="-", B="rf" -> "-rf") without any special-casing.
const VAR_REF_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(?::?[-=?+]|\/\/?)[\s\S]*?)?\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;

function substituteKnownVars(tok, values) {
  return tok.replace(VAR_REF_RE, (whole, bracedName, bareName) => {
    const name = bracedName || bareName;
    return values.has(name) ? values.get(name) : whole;
  });
}

// True when an `rm` segment passes a tracked recursive-flag variable as an
// argument (`rm $FLAGS x` after `FLAGS=-rf`, or a split-variable build like
// `rm $A$B x` after `A=-; B=rf`) — the single-hop bypass of Step 4 a'.
function referencesRecursiveFlagVar(seg, values) {
  if (values.size === 0) return false;
  // BASENAME-resolved, matching hasRecursiveRmFlag's own normalization
  // (#2210 F5) — an exact-string compare here missed `/bin/rm $F d` and
  // `rm.exe $F d` even though the sibling judge in rm.js resolves both.
  if (commandBasename(resolveEffectiveCommand(seg)) !== "rm") return false;
  for (const tok of resolveEffectiveArgv(seg)) {
    if (typeof tok !== "string" || !tok.includes("$")) continue;
    const substituted = substituteKnownVars(tok, values);
    if (substituted !== tok && isRecursiveRmFlagToken(substituted) === true) return true;
  }
  return false;
}

module.exports = {
  segTokens,
  isPureAssignmentSegment,
  applyAssignments,
  applyUnset,
  ASSIGNMENT_CARRYING_CMDS,
  applyAssignmentCarryingCommand,
  referencesRecursiveFlagVar,
};
