"use strict";

// Wrapper script-body extraction for recursive-delete-scan.js: which wrappers
// hand a full command STRING to a shell rather than exec'ing tokens as argv?

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  isPrintedDataAt,
} = require("../../bash-write-patterns/segment-utils");
const { segTokens } = require("./var-tracking");

// `env -S 'rm -rf dir'` word-splits its STRING and execs it, but the wrapper
// peel treats `-S`'s value as an opaque flag argument.
function envSplitStringBodies(seg) {
  if (commandBasename(resolveEffectiveCommand(seg)) !== "env") return [];
  const argv = resolveEffectiveArgv(seg);
  const bodies = [];
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (typeof tok !== "string" || !tok.startsWith("-")) continue;
    const eq = tok.indexOf("=");
    const name = eq === -1 ? tok : tok.slice(0, eq);
    const isSplit = name === "-S" || name === "--split-string";
    if (isSplit && eq !== -1) bodies.push(tok.slice(eq + 1));
    else if (isSplit && argv[i + 1] != null) bodies.push(String(argv[i + 1]));
    else if (!isSplit && tok.startsWith("-S") && tok.length > 2) bodies.push(tok.slice(2));
  }
  return bodies;
}

// Wrappers whose `-c` argument is a command STRING: the peel declares that
// flag AMBIGUOUS, so the payload is otherwise never looked at.
const COMMAND_STRING_WRAPPERS = new Set(["flock", "su", "runuser"]);

// `-c COMMAND` / `--command=COMMAND` values in the argv FOLLOWING the wrapper.
function commandStringFlagValues(toks) {
  const bodies = [];
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    const eq = tok.indexOf("=");
    const name = eq === -1 ? tok : tok.slice(0, eq);
    if (name !== "-c" && name !== "--command") continue;
    if (eq !== -1) bodies.push(tok.slice(eq + 1));
    else if (i + 1 < toks.length) bodies.push(toks[i + 1]);
  }
  return bodies;
}

// A wrapper name arms everywhere EXCEPT printed data (`echo su -c "rm -rf x"`);
// scanWrappedInterpreter shares this test. The stricter isInvokedAsCommandAt
// was tried and dropped `ssh host su -c 'rm -rf d'` (#2210).
function wrapperCommandStringBodies(seg) {
  const toks = segTokens(seg);
  const bodies = [];
  for (let i = 0; i < toks.length; i++) {
    if (!COMMAND_STRING_WRAPPERS.has(commandBasename(toks[i]))) continue;
    if (isPrintedDataAt(toks, i)) continue;
    bodies.push(...commandStringFlagValues(toks.slice(i + 1)));
  }
  return bodies;
}

// `watch` joins ALL its non-option arguments into one string for `sh -c`, so
// requiring zero leftover argv missed `watch echo a "&&" rm -rf d` (#2210).
function watchScriptBody(seg) {
  if (!seg || commandBasename(seg.cmd0) !== "watch") return null;
  const eff = resolveEffectiveCommand(seg);
  if (typeof eff !== "string" || commandBasename(eff) === "watch") return null;
  const argv = resolveEffectiveArgv(seg);
  return [eff, ...argv].join(" ");
}

function wrapperScriptBodies(seg) {
  const bodies = [...envSplitStringBodies(seg), ...wrapperCommandStringBodies(seg)];
  const watched = watchScriptBody(seg);
  if (watched !== null) bodies.push(watched);
  return bodies;
}

module.exports = { wrapperScriptBodies };
