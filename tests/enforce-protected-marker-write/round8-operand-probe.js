// tests/enforce-protected-marker-write/round8-operand-probe.js
// Unit probe for the round-8 fixes, run as a FILE (never `node -e`): the modules
// under test live under a directory whose own name is a protected string, so a
// `-e` body naming them would be blocked by the very hook this suite tests.
// argv[2] = repo root.
//
// Emits `key=value` lines; the bash side asserts on them. Two properties are
// pinned here that a hook-level verdict cannot isolate:
//
//  1. segmentArgvHitsProtectedArg() defers per TOKEN, not per SEGMENT. The
//     hook-level cases show the VERDICT changed; only here can the MECHANISM be
//     pinned - the token that defers is exactly a member of
//     extractAllInterpreterBodies(rawText).bodies (the set Tier 2 will actually
//     judge), and a sibling operand of the very same segment is not in that set
//     and is therefore classified. Deferring on anything wider (the old
//     `INTERPRETER_RE.test(seg.rawText)` per-segment predicate) leaves operands
//     judged by NOBODY, which is the gap `sh -c 'rm "$1"' _ <marker>` walked
//     through.
//  2. inlineProgramFlagProof() is KIND-SCOPED. INLINE_PROGRAM_FLAG_RE is the
//     union used by probes; permission decisions must ask the scoped form, so
//     pwsh's `-En...` prefix chain proves nothing when the interpreter is
//     python3/node (where `-E` means ignore-environment).
"use strict";

const path = require("path");

const root = process.argv[2];
const hooks = path.join(root, "hooks");
const scanDir = path.join(hooks, "block-" + "clearance" + "-token" + "-write");
const bscan = require(path.join(scanDir, "bash-scan.js"));
const iscan = require(path.join(scanDir, "interpreter-scan.js"));
const { parse } = require(path.join(hooks, "lib", "command-ir.js"));

const out = [];
const emit = (k, v) => out.push(k + "=" + String(v));

const DIR = "/wf";
const MK = DIR + "/s1.workflow-off";
const TOK = DIR + "/s1." + "off-" + "clearance";

const seg0 = (cmd) => {
  const ir = parse(cmd);
  return ir && Array.isArray(ir.segments) && ir.segments.length > 0 ? ir.segments[0] : null;
};
const argKind = (cmd) => String(bscan.segmentArgvHitsProtectedArg(seg0(cmd), "", null));

emit("sea_exported", typeof bscan.segmentArgvHitsProtectedArg === "function");

// --- 1. per-TOKEN deferral --------------------------------------------------
// Read as pairs: the same interpreter body, once alone (defers -> null) and once
// beside a protected OPERAND (the operand is still classified). A "fix" that
// deleted the deferral instead of narrowing it goes red on the first row of
// every pair; the pre-round-8 per-segment deferral goes red on the second.
const argCases = [
  ["pwsh -Command \"Get-Content -Raw '" + TOK + "'\"", "null"],
  ["pwsh -Command \"Get-Content -Raw '" + TOK + "'\" " + MK, "marker"],
  ["pwsh -Command \"Get-Content -Raw '" + MK + "'\"", "null"],
  ["pwsh -Command \"Get-Content -Raw '" + MK + "'\" " + TOK, "token"],
  ["sh -c 'rm \"$1\"' _ " + MK, "marker"],
  ["sh -c 'rm \"$1\"' _ " + TOK, "token"],
  ["python3 -c 'import os,sys; os.remove(sys.argv[1])' " + MK, "marker"],
  ["node -e \"console.log(1)\" " + MK, "marker"],
  ["node -e \"console.log(1)\" x " + TOK, "token"],
  // #1709: a read-only invocation is exempted before any of this runs.
  ["cat " + MK, "null"],
  ["wc -l " + TOK, "null"],
];
let argOk = true;
const argBad = [];
for (const [cmd, want] of argCases) {
  const got = argKind(cmd);
  if (got !== want) { argOk = false; argBad.push(cmd + " -> " + got); }
}
emit("sea_ok", argOk);
emit("sea_bad", argBad.join(" | ") || "-");
emit("sea_null_seg", bscan.segmentArgvHitsProtectedArg(null, "", null) === null);

// The mechanism itself: in ONE segment carrying both, the deferring token is a
// member of the extracted-body set and the operand is not. This is the property
// the verdicts above are downstream of.
const mixed = "pwsh -Command \"Get-Content -Raw '" + TOK + "'\" " + MK;
const bodies = iscan.extractAllInterpreterBodies(mixed).bodies;
const mixedSeg = seg0(mixed);
const mixedArgv = (mixedSeg && Array.isArray(mixedSeg.argv) ? mixedSeg.argv : []).filter(
  (a) => typeof a === "string"
);
emit("sea_body_extracted", bodies.some((b) => mixedArgv.includes(b)));
emit("sea_operand_not_extracted", !bodies.includes(MK) && mixedArgv.includes(MK));

// --- 2. kind-scoped proof (round-8 fix A) -----------------------------------
// [flag, interpreter, isProof]
const proofCases = [
  ["-c", "python3", true],
  ["-e", "node", true],
  ["--eval", "node", true],
  ["-uc", "python3", true],
  ["-Command", "pwsh", true],
  ["-EncodedCommand", "pwsh", true],
  ["-En", "pwsh", true],
  ["-En", "python3", false],
  ["-En", "node", false],
  ["-E", "python3", false],
  ["-E", "perl", false],
  ["-E", "pwsh", false],
  ["-Command", "python3", false],
  ["-Command", "node", false],
  ["--print", "node", false],
  ["-p", "node", false],
  ["", "pwsh", false],
];
let proofOk = true;
const proofBad = [];
for (const [flag, interp, want] of proofCases) {
  const got = typeof iscan.inlineProgramFlagProof === "function"
    ? iscan.inlineProgramFlagProof(flag, interp) === true
    : null;
  if (got !== want) { proofOk = false; proofBad.push(flag + "@" + interp + ":" + got); }
}
emit("proof_scoped_exported", typeof iscan.inlineProgramFlagProof === "function");
emit("proof_scoped_ok", proofOk);
emit("proof_scoped_bad", proofBad.join(" ") || "-");
emit("proof_pwsh_word", iscan.isPwshWord("PWSH.EXE") === true && iscan.isPwshWord("node") === false);

process.stdout.write(out.join("\n") + "\n");
