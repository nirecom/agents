"use strict";

// Stdin-delivery detection for recursive-delete-scan.js: script text that never
// lands in argv, and the producers (`echo`, `printf`) whose stdout becomes it.

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  INTERPRETER_SPECS,
  PWSH_BODY_SPEC,
} = require("../../bash-write-patterns/segment-utils");
const { interpreterBodiesOf } = require("./interpreter-bodies");
const { segTokens } = require("./var-tracking");

// `pwsh -Command <script>` UNQUOTED: the bash parser cuts the script at the
// first `|`, so the far-side `Remove-Item` is judged as a bash command with no
// pwsh upstream and was approved (#2210). Rejoin the pipeline-adjacent
// segments into the ONE script pwsh receives. Names are DERIVED from
// INTERPRETER_SPECS so the two enumerations cannot drift apart.
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

// Shell regardless of HOW it receives its script — for callers where a
// redirect operator already proves stdin delivery.
function isShellInterpreter(seg) {
  const spec = interpreterSpecOf(seg);
  return !!spec && spec.kind === "shell";
}

// The LANGUAGE sibling of isShellInterpreter: gating on kind === "shell" alone
// left `echo 'import shutil; shutil.rmtree("d")' | python` unrecognized (#2210).
function languageInterpreterLang(seg) {
  const spec = interpreterSpecOf(seg);
  return spec && spec.kind === "language" ? spec.lang : null;
}

// No inline body and no positional script FILE means the script comes from
// stdin; `bash script.sh` fails the all-flags test and is correctly excluded.
function readsStdinAsScript(seg) {
  if (!interpreterSpecOf(seg)) return false;
  if (interpreterBodiesOf(seg).length > 0) return false;
  return resolveEffectiveArgv(seg).every((t) => typeof t === "string" && t.startsWith("-"));
}

function shellReadsStdin(seg) {
  return isShellInterpreter(seg) && readsStdinAsScript(seg);
}

// `source` re-reads the current shell's stdin as a script, but is a BUILTIN
// with no INTERPRETER_SPECS entry, so it needs this separate test.
function sourcesStdin(seg) {
  const eff = resolveEffectiveCommand(seg);
  if (eff !== "source" && eff !== ".") return false;
  const positional = resolveEffectiveArgv(seg).filter((t) => typeof t === "string" && !t.startsWith("-"));
  return positional.length === 1 && positional[0] === "/dev/stdin";
}

function stdinConsumer(seg) {
  return readsStdinAsScript(seg) || sourcesStdin(seg);
}

// Producers whose LITERAL argv text becomes another process's script
// (`echo TEXT | bash`). Deliberately scoped to echo/printf: an OPAQUE producer
// (`cat file | bash`) is an accepted gap — see docs/security-policy.md.
const STDIN_TEXT_PRODUCERS = new Set(["echo", "printf"]);

// echo's leading `-e`/`-n`/`-E` (and combined `-ne`) are flags, not output: a
// naive argv-join folds them in and can shift the delete spelling. Only a
// LEADING run counts — the first non-matching token is data, as echo itself does.
const ECHO_FLAG_RE = /^-[neE]+$/;

function echoLiteralText(argv) {
  let i = 0;
  while (i < argv.length && typeof argv[i] === "string" && ECHO_FLAG_RE.test(argv[i])) i++;
  return argv.slice(i).join(" ");
}

// printf's FORMAT is not literal text, so an argv-join emits `%s` instead of
// the ARG it hides. Only the two exactly-resolvable formats are modeled,
// cycled over the trailing ARGs as printf repeats a short format; any other
// format needs printf's whole grammar and goes to printfFormatUnresolvable().
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

// Approximates echo/printf's stdout. null means "not a text producer" —
// distinct from producerTextUnresolvable() below.
function producerLiteralText(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  if (!STDIN_TEXT_PRODUCERS.has(base)) return null;
  const argv = resolveEffectiveArgv(seg);
  if (base === "echo") return echoLiteralText(argv);
  if (printfFormatUnresolvable(argv)) return "";
  return printfLiteralText(argv);
}

// A recognized producer whose output cannot be resolved exactly: callers must
// fail CLOSED here, never fall through to producerLiteralText's stand-in text.
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
