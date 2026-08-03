// tests/enforce-protected-marker-write/round6-identity-probe.js
// Unit probe for the round-6 stdin-routing SSOT, run as a FILE (never `node -e`):
// the modules under test live under a directory whose own name is a protected
// string, so a `-e` body naming them would be blocked by the very hook this
// suite tests. argv[1] = repo root.
//
// Emits `key=value` lines; the bash side asserts on them. Two things are proved
// here that a hook-level verdict cannot isolate:
//
//  1. interpreterKindOfWord() is the single point of failure for the whole
//     round-6 fix (every route asks it "who receives this program text?"), so it
//     is asserted directly and exhaustively over the SSOT arrays rather than
//     sampled through payloads. Case, directory prefix and `.exe` must all be
//     tolerated - Windows resolves `NODE.EXE` and `C:\...\python3.exe` to the
//     same program a POSIX host spells `node` (CPR-8).
//  2. stdinProgramInterpreterKind() must return null EXACTLY when argv PROVABLY
//     carries the program — round-7 rule: proof is a body-carrying
//     inline-program flag (INLINE_PROGRAM_FLAG_RE), never argv shape. That is
//     what keeps `cat <marker> | python3 -c 'print(1)'` (stdin = DATA) out of
//     the fail-closed opaque path, while `node --title x <<< '<program>'` — one
//     shifted token, byte-identical body — no longer clears itself.
"use strict";

const path = require("path");

const root = process.argv[2];
const hooks = path.join(root, "hooks");
const scanDir = path.join(hooks, "block-" + "clearance" + "-token" + "-write");
const iscan = require(path.join(scanDir, "interpreter-scan.js"));
const nested = require(path.join(scanDir, "nested-bodies.js"));
const { parse } = require(path.join(hooks, "lib", "command-ir.js"));

const out = [];
const emit = (k, v) => out.push(k + "=" + String(v));

// --- 1. interpreterKindOfWord: case / path / .exe tolerance ----------------
const kindCases = [
  ["node", "language"],
  ["NODE", "language"],
  ["Node", "language"],
  ["node.exe", "language"],
  ["NODE.EXE", "language"],
  ["/usr/bin/node", "language"],
  ["/usr/local/bin/nodejs", "language"],
  ["C:\\Program Files\\nodejs\\node.exe", "language"],
  ["C:\\Python311\\python3.exe", "language"],
  ["python3", "language"],
  ["PYTHON3.EXE", "language"],
  ["pwsh", "language"],
  ["powershell.exe", "language"],
  ["bash", "shell"],
  ["/bin/bash", "shell"],
  ["BASH.EXE", "shell"],
  ["busybox", "shell"],
  ["C:\\msys64\\usr\\bin\\sh.exe", "shell"],
  ["cat", "null"],
  ["nodex", "null"],
  ["mynode", "null"],
  ["node.exe.bak", "null"],
  ["", "null"],
];
let kindOk = true;
const kindBad = [];
for (const [word, want] of kindCases) {
  const got = String(iscan.interpreterKindOfWord(word));
  if (got !== want) { kindOk = false; kindBad.push(word + ":" + got); }
}
emit("kind_ok", kindOk);
emit("kind_bad", kindBad.join(",") || "-");
emit("kind_nonstring", [null, undefined, 42, {}, []].every((v) => iscan.interpreterKindOfWord(v) === null));

// Exhaustive over the SSOT arrays: a name added to LANGUAGE_INTERPRETER_NAMES
// but not to the Set behind interpreterKindOfWord would be silently unrouted.
const everyName = (names, want) =>
  names.length > 0 && names.every((n) =>
    iscan.interpreterKindOfWord(n) === want &&
    iscan.interpreterKindOfWord(n.toUpperCase()) === want &&
    iscan.interpreterKindOfWord("/usr/bin/" + n) === want &&
    iscan.interpreterKindOfWord(n + ".exe") === want);
emit("ssot_language", everyName(iscan.LANGUAGE_INTERPRETER_NAMES, "language"));
emit("ssot_shell", everyName(iscan.SHELL_INTERPRETER_NAMES, "shell"));
emit("ssot_disjoint", !iscan.LANGUAGE_INTERPRETER_NAMES.some((n) => iscan.SHELL_INTERPRETER_NAMES.includes(n)));
emit("ssot_lang_has_node", iscan.LANGUAGE_INTERPRETER_NAMES.includes("node"));
emit("ssot_shell_has_bash", iscan.SHELL_INTERPRETER_NAMES.includes("bash"));

// --- 1b. INLINE_PROGRAM_FLAG_RE: the ONLY accepted proof (round 7) ----------
// Accepting one flag too many re-opens the bypass wholesale, so both directions
// are pinned: the family members that must count as proof, and the four
// look-alikes that must NOT (`-E`/`-p`/`-P`/`--print` are inline-program flags
// in one language and ordinary options in another).
const IPF = iscan.INLINE_PROGRAM_FLAG_RE;
emit("ipf_exported", IPF instanceof RegExp);
const ipfCases = [
  ["-c", true], ["-e", true], ["--eval", true], ["--eval=code", true],
  ["-uc", true], ["-ec", true], ["-Command", true], ["--Command", true],
  ["-EncodedCommand", true],
  ["-E", false], ["-p", false], ["-P", false], ["--print", false],
  ["--title", false], ["-X", false], ["-I", false], ["-u", false],
  ["script.js", false], ["", false],
];
let ipfOk = true;
const ipfBad = [];
for (const [word, want] of ipfCases) {
  const got = IPF instanceof RegExp ? IPF.test(word) : null;
  if (got !== want) { ipfOk = false; ipfBad.push(word + ":" + got); }
}
emit("ipf_ok", ipfOk);
emit("ipf_bad", ipfBad.join(" ") || "-");

// --- 2. stdinProgramInterpreterKind: only when argv PROVES the program ------
const seg0 = (cmd) => {
  const ir = parse(cmd);
  return ir && Array.isArray(ir.segments) && ir.segments.length > 0 ? ir.segments[0] : null;
};
const stdinKind = (cmd) => String(nested.stdinProgramInterpreterKind(seg0(cmd)));
// Round 7: "null" means PROVEN to read data, and the only proof is a
// body-carrying inline-program flag. A flag VALUE (`--title x`) and a bare file
// operand (`script.js`) are no longer proof — that shape-based walk was the
// fail-open bypass — so both now report the interpreter kind (over-block).
const kindOfCmdCases = [
  ["node", "language"],
  ["node -", "language"],
  ["node -u", "language"],
  ["NODE.EXE", "language"],
  ["bash", "shell"],
  ["node --title x", "language"],          // flag VALUE is not a program
  ["python3 -X importtime", "language"],
  ["perl -I lib", "language"],
  ["node -e", "language"],                 // bodyless flag proves nothing
  ["node script.js", "language"],          // bare operand: unproven -> over-block
  ["python3 script.py", "language"],
  ["node -e 'x'", "null"],                 // flag WITH body: proven
  ["node --eval=console.log(1)", "null"],  // attached long form: proven
  ["python3 -uc 'print(1)'", "null"],
  ["pwsh -Command 'Write-Output 1'", "null"],
  ["sh -c 'x'", "null"],
  ["cat", "null"],
  ["grep foo", "null"],
];
let cmdKindOk = true;
const cmdKindBad = [];
for (const [cmd, want] of kindOfCmdCases) {
  const got = stdinKind(cmd);
  if (got !== want) { cmdKindOk = false; cmdKindBad.push(cmd + ":" + got); }
}
emit("stdin_kind_ok", cmdKindOk);
emit("stdin_kind_bad", cmdKindBad.join(" | ") || "-");
emit("stdin_kind_null_seg", nested.stdinProgramInterpreterKind(null) === null);

// --- 3. stdinProgramRoutes: which bucket each delivery syntax lands in ------
const routes = (cmd) => {
  const ir = parse(cmd);
  return nested.stdinProgramRoutes(cmd, (ir && ir.segments) || []);
};
const shape = (cmd) => {
  const r = routes(cmd);
  return r.bodies.length + "/" + r.fileTargets.length + "/" + r.opaqueTexts.length;
};
emit("route_herestring_lang", shape("node <<< 'CODE'"));      // body only
emit("route_herestring_shell", shape("sh <<< 'CODE'"));       // shell: no language body
emit("route_stdin_file", shape("node < prog.js"));            // file target
emit("route_pipe", shape("printf x | node"));                 // opaque upstream
emit("route_pipe_chain", shape("cat a | tr -d x | node"));    // WHOLE pipeline opaque
emit("route_plain", shape("node -e 'x'"));                    // nothing
emit("route_cat_file", shape("cat < prog.js"));               // not an interpreter
emit("route_heredoc", shape("node <<EOF\nCODE\nEOF\n"));
emit("route_heredoc_shell", shape("cat <<EOF\nCODE\nEOF\n"));
emit("route_heredoc_unterminated", shape("node <<EOF\nCODE\n"));
// The heredoc body must arrive quote-stripped and verbatim, or the read-only
// shapes in interpreter-scan.js (all anchored) can never match it.
emit("heredoc_body", routes("node <<EOF\nconsole.log(1)\nEOF\n").bodies.map((b) => b.body).join("|"));
emit("herestring_body", routes("node <<< \"console.log(1)\"").bodies.map((b) => b.body).join("|"));

process.stdout.write(out.join("\n") + "\n");
