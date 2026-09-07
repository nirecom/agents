"use strict";

// Stdin-delivery detection for recursive-delete-scan.js: script text that
// never lands in argv at all — a pwsh pipeline's upstream cmdlet, a shell
// reading its script from a pipe/herestring/process-substitution/`/dev/stdin`
// — and the literal-text producers (`echo`, `printf`) whose stdout becomes
// that script. Split out of the parent when it crossed the 500-line hard limit.

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  INTERPRETER_SPECS,
  PWSH_BODY_SPEC,
} = require("../../bash-write-patterns/segment-utils");
const { interpreterBodiesOf } = require("./interpreter-bodies");
const { segTokens } = require("./var-tracking");

// `pwsh -Command <script>` with the script UNQUOTED: the bash parser cuts it at
// the first `|`, so the body reaching the pwsh judge is only the pipeline's
// first stage (`Get-ChildItem d -Recurse`) and the `Remove-Item` on the far side
// is judged as a bash command with no pwsh upstream — `pwsh -Command
// Get-ChildItem d -Recurse | Remove-Item` approved (#2210 round-6). Rejoin the
// pipeline-adjacent segments into the ONE script pwsh receives. The name set
// is DERIVED from INTERPRETER_SPECS (whose "pwsh"/"powershell" entries both
// point at the shared PWSH_BODY_SPEC object) rather than re-spelled here, so
// the two enumerations cannot drift apart (#2210 round8 N6).
const PWSH_INTERPRETER_BASES = new Set(
  [...INTERPRETER_SPECS].filter(([, spec]) => spec === PWSH_BODY_SPEC).map(([name]) => name)
);

function pwshCommandPipelineScript(segments, index, separators) {
  if (!Array.isArray(separators) || separators.length !== segments.length - 1) return null;
  if (index >= segments.length - 1 || separators[index] !== "|") return null;
  if (!PWSH_INTERPRETER_BASES.has(commandBasename(resolveEffectiveCommand(segments[index])))) return null;
  const bodies = interpreterBodiesOf(segments[index]);
  if (bodies.length === 0 || bodies[0].kind !== "shell") return null;
  const parts = [bodies[0].body];
  for (let j = index; j < segments.length - 1 && separators[j] === "|"; j++) {
    parts.push(segTokens(segments[j + 1]).join(" "));
  }
  return parts.join(" | ");
}

function interpreterSpecOf(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  return (base && INTERPRETER_SPECS.get(base)) || null;
}

// True when this segment's effective command is a shell (bash/sh/zsh/...),
// regardless of how it receives its script — used where a redirect operator
// already proves stdin delivery (the herestring case below) and no further
// "is this really reading stdin" test is needed.
function isShellInterpreter(seg) {
  const spec = interpreterSpecOf(seg);
  return !!spec && spec.kind === "shell";
}

// The stdin-fed LANGUAGE-interpreter sibling of isShellInterpreter: previously
// unrecognized because it gated on spec.kind === "shell" alone, so
// `echo 'import shutil; shutil.rmtree("d")' | python` and
// `echo 'Remove-Item -Recurse d' | pwsh -Command -` were never even offered to
// the "does this read stdin" test below (#2210 security-scanner C26,
// CPR-ORTH — the shell and language cases are symmetric stdin consumers).
// Returns the interpreter's `lang` string (e.g. "python") or null.
function languageInterpreterLang(seg) {
  const spec = interpreterSpecOf(seg);
  return spec && spec.kind === "language" ? spec.lang : null;
}

// An interpreter invoked with no inline body (`-c`/`-Command`/...) and no
// positional script-FILE argument reads its script from stdin — the far end
// of a pipe or a process-substitution argument. A real `bash script.sh` /
// `python script.py` argv fails this (the file is a non-flag positional
// token), correctly excluding it. Applies identically to shell and language
// interpreters (#2210 security-scanner C26).
function readsStdinAsScript(seg) {
  if (!interpreterSpecOf(seg)) return false;
  if (interpreterBodiesOf(seg).length > 0) return false;
  return resolveEffectiveArgv(seg).every((t) => typeof t === "string" && t.startsWith("-"));
}

function shellReadsStdin(seg) {
  return isShellInterpreter(seg) && readsStdinAsScript(seg);
}

// `source /dev/stdin` / `. /dev/stdin` re-reads the CURRENT shell's stdin as a
// script. It is a shell BUILTIN, not an external interpreter process, so it
// carries no INTERPRETER_SPECS entry and needs this separate test.
function sourcesStdin(seg) {
  const eff = resolveEffectiveCommand(seg);
  if (eff !== "source" && eff !== ".") return false;
  const positional = resolveEffectiveArgv(seg).filter((t) => typeof t === "string" && !t.startsWith("-"));
  return positional.length === 1 && positional[0] === "/dev/stdin";
}

function stdinConsumer(seg) {
  return readsStdinAsScript(seg) || sourcesStdin(seg);
}

// Producers whose LITERAL argv text becomes another process's stdin/script
// content (`echo TEXT | bash`, `bash <(echo TEXT)`). The old settings.json
// substring glob denied any of these whenever "rm -rf"-shaped text appeared
// anywhere in the raw command line; scanning only argv-carried script bodies
// dropped that coverage (#2210 N2). Deliberately scoped to echo/printf: an
// OPAQUE producer (`cat file | bash`) was never caught by the old glob either,
// so leaving it unscanned here is not a new regression — see docs/security-policy.md.
const STDIN_TEXT_PRODUCERS = new Set(["echo", "printf"]);

// echo's own leading OPTION tokens (`-e`, `-n`, `-E`, and bash's combined
// forms like `-ne`) are flags, not output text. A naive argv-join folded the
// flag spelling itself into the "output", which can shift or hide a
// recursive-delete SPELLING relative to what echo actually prints. Only a
// LEADING run of dash+[neE] tokens counts — the first token that doesn't fit
// is data, exactly like echo's own argument parsing (#2210 C1).
const ECHO_FLAG_RE = /^-[neE]+$/;

function echoLiteralText(argv) {
  let i = 0;
  while (i < argv.length && typeof argv[i] === "string" && ECHO_FLAG_RE.test(argv[i])) i++;
  return argv.slice(i).join(" ");
}

// printf FORMAT [ARG...] treats FORMAT as a format string, not literal text —
// a naive argv-join emitted the format spelling (`%s`) itself instead of the
// substituted ARG, which can hide a recursive-delete spelling behind the
// substitution entirely. Only the two forms this scanner can resolve exactly
// are modeled: a bare `%s` / `%s\n` format, cycled over every trailing ARG the
// way printf itself repeats a format with too few conversions for its
// argument count. Any other format (another specifier, literal text mixed
// with `%s`, `%%`, ...) is NOT reproducible by simple substitution — resolving
// it exactly would mean emulating printf's whole format grammar — so it is
// reported via printfFormatUnresolvable() instead of guessed at (#2210 C1).
const PRINTF_PLAIN_FORMATS = new Map([["%s", ""], ["%s\\n", "\n"]]);

function printfFormatUnresolvable(argv) {
  const fmt = argv[0];
  return typeof fmt !== "string" || !PRINTF_PLAIN_FORMATS.has(fmt);
}

function printfLiteralText(argv) {
  const sep = PRINTF_PLAIN_FORMATS.get(argv[0]);
  return argv
    .slice(1)
    .map((a) => (typeof a === "string" ? a : ""))
    .join(sep);
}

// Approximates echo/printf's stdout accurately enough to catch a
// recursive-delete SPELLING without emulating either builtin's full
// formatting rules. Returns null when `seg` is not a recognized text
// producer at all — distinct from producerTextUnresolvable() below, which
// covers a recognized producer this function cannot resolve exactly.
function producerLiteralText(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  if (!STDIN_TEXT_PRODUCERS.has(base)) return null;
  const argv = resolveEffectiveArgv(seg);
  if (base === "echo") return echoLiteralText(argv);
  if (printfFormatUnresolvable(argv)) return "";
  return printfLiteralText(argv);
}

// Companion to producerLiteralText: true when `seg` IS a recognized printf
// producer whose literal output cannot be resolved exactly (an opaque
// format string) — never conflate this with producerLiteralText's null,
// which means "not a text producer" and is safe to skip. Callers must fail
// closed on an unresolvable producer the same way interpreterBodiesOf's
// "unresolvable" kind does, rather than falling through to scan
// producerLiteralText's (necessarily incomplete) substitute text.
function producerTextUnresolvable(seg) {
  if (commandBasename(resolveEffectiveCommand(seg)) !== "printf") return false;
  return printfFormatUnresolvable(resolveEffectiveArgv(seg));
}

module.exports = {
  pwshCommandPipelineScript,
  isShellInterpreter,
  languageInterpreterLang,
  shellReadsStdin,
  readsStdinAsScript,
  stdinConsumer,
  producerLiteralText,
  producerTextUnresolvable,
};
