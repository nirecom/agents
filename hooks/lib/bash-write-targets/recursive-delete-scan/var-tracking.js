"use strict";

// Literal-variable tracking for recursive-delete-scan.js: does an `rm` segment
// reference a flag variable built from assignments (`FLAGS=-rf; rm $FLAGS d`)?

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

// Literal values, not a boolean: `A=-; B=rf; rm $A$B d` must reassemble.
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

// These carry assignments alongside option flags, so isPureAssignmentSegment
// (EVERY token an assignment) misses `export FLAGS=-rf`.
const ASSIGNMENT_CARRYING_CMDS = new Set(["export", "declare", "typeset", "readonly", "local"]);

function applyAssignmentCarryingCommand(seg, values) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const assignTokens = argv.filter((t) => typeof t === "string" && ASSIGN_RE.test(t));
  applyAssignments({ cmd0: null, argv: assignTokens }, values);
}

// A global replace reassembles split-variable concatenation (`$A$B` with
// A="-", B="rf" -> "-rf") without special-casing.
const VAR_REF_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(?::?[-=?+]|\/\/?)[\s\S]*?)?\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;

function substituteKnownVars(tok, values) {
  return tok.replace(VAR_REF_RE, (whole, bracedName, bareName) => {
    const name = bracedName || bareName;
    return values.has(name) ? values.get(name) : whole;
  });
}

function referencesRecursiveFlagVar(seg, values) {
  if (values.size === 0) return false;
  // BASENAME-resolved like hasRecursiveRmFlag: an exact compare missed
  // `rm.exe $F d` and the absolute-path spelling (#2210).
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
