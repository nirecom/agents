// Structural readings of a parsed command line for the forge-target-ownership
// guard: which segments control flow is bound to reach, what a segment actually
// runs once assignments and wrappers are peeled, and whether that reading is
// knowable at all. Pure functions over the IR — no guard state.
// Entrypoint-private to confirm-forge-target-ownership.js.
"use strict";

const segmentUtils = require("../lib/bash-write-patterns/segment-utils");
const { commandBasename, ASSIGN_RE } = segmentUtils;

const DYNAMIC_TEXT_RE = /\$\(|`|\$\{|\$[A-Za-z_]/;

function conditionalSeparators(ir) {
  const seps = Array.isArray(ir && ir.separators) ? ir.separators : [];
  return seps.some((s) => typeof s === "string" && (s.indexOf("&&") !== -1 || s.indexOf("||") !== -1));
}

const GAP_SEPARATOR_RE = /&&|\|\||[;|&()\n]/g;

// Reachability is a per-SEGMENT question, not a per-line one. `false && true;
// export GH_REPO=x` gates only what follows the `&&`: the `;` puts the export
// back on the unconditional path, and marking it conditional because the line
// contains an `&&` SOMEWHERE loses a target the shell really did set.
// The separators array cannot be indexed against the segments array (empty
// flushes are dropped, leading/trailing separators are kept), so each segment is
// located in the line text and the gap before it — which can hold nothing but
// separators and whitespace — is what decides. Returns null when a segment
// cannot be located, so the caller keeps the older line-wide reading rather
// than guessing.
function segmentGuarantees(ir, line) {
  const segments = Array.isArray(ir && ir.segments) ? ir.segments : [];
  const text = typeof line === "string" ? line : "";
  const flags = [];
  const enclosing = [];
  let gated = false;
  let cursor = 0;
  for (const seg of segments) {
    const raw = seg && typeof seg.rawText === "string" ? seg.rawText : null;
    const at = raw === null || raw === "" ? -1 : text.indexOf(raw, cursor);
    if (at === -1) return null;
    GAP_SEPARATOR_RE.lastIndex = 0;
    for (const tok of text.slice(cursor, at).match(GAP_SEPARATOR_RE) || []) {
      if (tok === "&&" || tok === "||") gated = true;
      else if (tok === "(") { enclosing.push(gated); gated = false; }
      else if (tok === ")") { gated = enclosing.length > 0 ? enclosing.pop() : false; }
      else gated = false;
    }
    flags.push(!gated && !enclosing.some(Boolean));
    cursor = at + raw.length;
  }
  return flags;
}

// The command this segment actually runs, with inline assignments stripped and
// wrappers peeled by the SHARED peeler (CPR-SSOT) — a private copy here would
// drift from the one every other write-scanning hook trusts. `argvRaw` is
// realigned by length: the peel only ever returns a suffix of the original argv.
function effectiveOf(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : argv;
  let head = seg.cmd0;
  let rest = argv;
  if (typeof head === "string" && ASSIGN_RE.test(head)) {
    const idx = argv.findIndex((a) => typeof a !== "string" || !ASSIGN_RE.test(a));
    if (idx === -1) return { cmd0: null, argv: [], argvRaw: [] };
    head = argv[idx];
    rest = argv.slice(idx + 1);
  }
  const peeled = segmentUtils.peelWrappers(head, rest);
  const effArgv = Array.isArray(peeled.argv) ? peeled.argv : [];
  const consumed = argv.length - effArgv.length;
  const cmd0Raw = typeof seg.cmd0Raw === "string" ? seg.cmd0Raw : seg.cmd0;
  return {
    cmd0: peeled.cmd0,
    argv: effArgv,
    argvRaw: argvRaw.slice(consumed),
    prefixRaw: [cmd0Raw].concat(argvRaw.slice(0, consumed)),
  };
}

// `env -C dir` runs the command somewhere other than tool_input.cwd, so nothing
// the guard resolves from the working directory describes what gh will see. It
// is a LOCATION problem, never an auth one — the two get separate reasons.
function relocatesCwd(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const tokens = [seg.cmd0].concat(argv);
  if (!tokens.some((t) => commandBasename(t) === "env")) return false;
  return argv.some((t) => typeof t === "string" && (t === "-C" || t === "--chdir" || t.indexOf("--chdir=") === 0));
}

// The command word decides everything downstream, so a command word that is
// only known at run time — a variable, a substitution — is not "no gh write
// here", it is a write the guard cannot read.
function headIsDynamic(eff) {
  const prefixRaw = Array.isArray(eff.prefixRaw) ? eff.prefixRaw : [];
  const headRaw = prefixRaw.length > 0 ? prefixRaw[prefixRaw.length - 1] : null;
  for (const word of [eff.cmd0, headRaw]) {
    if (typeof word === "string" && DYNAMIC_TEXT_RE.test(word)) return true;
  }
  return false;
}

module.exports = {
  DYNAMIC_TEXT_RE,
  conditionalSeparators,
  segmentGuarantees,
  effectiveOf,
  relocatesCwd,
  headIsDynamic,
};
