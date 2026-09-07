"use strict";

// Wrapper script-body extraction for recursive-delete-scan.js: which wrappers
// (`env -S`, `flock -c`, `su -c`, `watch '...'`) hand a full command STRING to
// a shell rather than exec'ing tokens as argv? Split out of the parent when it
// crossed the 500-line hard limit.

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  isPrintedDataAt,
} = require("../../bash-write-patterns/segment-utils");
const { segTokens } = require("./var-tracking");

// `env -S 'rm -rf dir'` word-splits its STRING and execs it, but the wrapper peel
// treats `-S`'s value as an opaque flag argument, so it is collected here and
// scanned as command text (#2210 round-4 C8).
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

// Wrappers whose `-c` argument is a full command STRING handed to a shell. The
// peel declares that flag AMBIGUOUS (it is not a token chain), so the payload
// would otherwise never be looked at (#2210 round-4 C1/C12).
const COMMAND_STRING_WRAPPERS = new Set(["flock", "su", "runuser"]);

// The `-c COMMAND` / `--command=COMMAND` strings in the argv that FOLLOWS a
// command-string wrapper's own name.
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

// A wrapper name arms below everywhere EXCEPT printed data (`echo su -c "rm -rf
// x"`, #2210 C2). segment-utils.js's scanWrappedInterpreter applies the same
// isPrintedDataAt test, so the two mid-argv nets share one reading (CPR-SSOT).
// Requiring isInvokedAsCommandAt instead narrowed both to heads modelled as
// wrappers, dropping `ssh host su -c 'rm -rf d'` (#2210 round-15 item 2).
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

// `watch 'rm -rf dir'` re-invokes a shell on its single string payload, so the
// peel lands on a SCRIPT BODY where a command token is expected (#2210 C6).
// `watch` joins ALL of its non-option arguments into one string and hands
// that to `sh -c`, so a multi-word payload (`watch echo a "&&" rm -rf d`) was
// missed by requiring zero leftover argv — only the single-word case was
// caught (#2210 security-scanner C6).
function watchScriptBody(seg) {
  if (!seg || commandBasename(seg.cmd0) !== "watch") return null;
  const eff = resolveEffectiveCommand(seg);
  if (typeof eff !== "string" || commandBasename(eff) === "watch") return null;
  const argv = resolveEffectiveArgv(seg);
  return [eff, ...argv].join(" ");
}

// Every script body a wrapper hands to a shell rather than exec'ing as argv.
function wrapperScriptBodies(seg) {
  const bodies = [...envSplitStringBodies(seg), ...wrapperCommandStringBodies(seg)];
  const watched = watchScriptBody(seg);
  if (watched !== null) bodies.push(watched);
  return bodies;
}

module.exports = { wrapperScriptBodies };
