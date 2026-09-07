"use strict";

// Wrapper peel / mid-argv scan half; re-exports the interpreter and wrapper
// spec tables so callers keep one import.
const {
  UNRESOLVABLE_RE,
  INTERPRETER_SPECS,
  PWSH_BODY_SPEC,
  interpreterInlineBodies,
  interpreterFoundBodies,
  pwshInterpreterBodies,
  decodeEncodedCommand,
} = require("./segment-utils/interpreter-specs");
const {
  ASSIGN_RE,
  AMBIGUOUS,
  WRAPPER_SPECS,
  commandBasename,
  wrapperSpecFor,
  isAttachedShortValue,
  skipWrapperOptions,
} = require("./segment-utils/wrapper-specs");

// Peel leading command wrappers (env/nice/nohup/...) down to the real command.
// On ambiguity the ORIGINAL cmd0/argv come back so raw detection still sees them.
function peelWrappers(cmd0, argv) {
  let curCmd = cmd0;
  let curArgv = Array.isArray(argv) ? argv : [];
  for (let depth = 0; depth < 16; depth++) {
    const spec = wrapperSpecFor(curCmd);
    if (!spec) break;
    const idx = skipWrapperOptions(curArgv, spec);
    if (idx === AMBIGUOUS) {
      // Fail-closed: callers fall back to raw detection + scanWrappedVerb.
      return { cmd0, argv: Array.isArray(argv) ? argv : [], ambiguous: true };
    }
    if (idx === -1) break; // wrapper with no wrapped command — leave as-is
    const next = curArgv[idx];
    if (typeof next !== "string" || next.length === 0) break;
    curCmd = next;
    curArgv = curArgv.slice(idx + 1);
  }
  return { cmd0: curCmd, argv: curArgv, ambiguous: false };
}

// Flags whose VALUE is a command line the outer program runs itself.
const EXEC_ARG_FLAGS = new Set(["-exec", "-execdir", "-ok", "-okdir"]);

// True when tokens[idx] is genuinely INVOKED: head, `find -exec` argument, or
// end of a wrapper chain. A name sitting in argv as DATA is not (#2210).
function isInvokedAsCommandAt(tokens, idx) {
  const toks = Array.isArray(tokens) ? tokens : [];
  if (idx <= 0) return idx === 0;
  if (EXEC_ARG_FLAGS.has(toks[idx - 1])) return true;
  let cur = 0;
  while (cur < idx && typeof toks[cur] === "string" && ASSIGN_RE.test(toks[cur])) cur += 1;
  if (cur === idx) return true;
  for (let depth = 0; depth < 16 && cur < idx; depth++) {
    const spec = wrapperSpecFor(toks[cur]);
    if (!spec) return false;
    const off = skipWrapperOptions(toks.slice(cur + 1), spec);
    if (off === AMBIGUOUS) {
      // Chain is real, only the unknown option's arity is not.
      const between = toks.slice(cur + 1, idx);
      return between.every((t) => typeof t === "string" && (t.startsWith("-") || ASSIGN_RE.test(t)));
    }
    if (off < 0) return false;
    const next = cur + 1 + off;
    if (next >= idx) return next === idx;
    cur = next;
  }
  return false;
}

// Commands whose arguments are TEXT BEING PRINTED, never a program being run.
const TEXT_PRODUCERS = new Set(["echo", "printf"]);

// True when tokens[idx] is DATA in a text producer's argv (`echo su -c "rm -rf x"`).
// Everything else stays a possible invocation: heads this module does not model
// (ssh, docker run, npx, ...) must keep the mid-argv nets broad (#2210).
function isPrintedDataAt(tokens, idx) {
  const toks = Array.isArray(tokens) ? tokens : [];
  for (let i = 0; i < idx && i < toks.length; i++) {
    if (typeof toks[i] !== "string") continue;
    if (!TEXT_PRODUCERS.has(commandBasename(toks[i]))) continue;
    if (isInvokedAsCommandAt(toks, i)) return true;
  }
  return false;
}

// peelWrappers, stopping before a `stopBasenames` entry. exotic-exec.js needs
// `xargs` itself (its own dynamic-argument handling); rm.js wants it peeled.
function peelWrappersUntil(cmd0, argv, stopBasenames) {
  let curCmd = cmd0;
  let curArgv = Array.isArray(argv) ? argv : [];
  for (let depth = 0; depth < 16; depth++) {
    if (stopBasenames.has(commandBasename(curCmd))) break;
    const spec = wrapperSpecFor(curCmd);
    if (!spec) break;
    const idx = skipWrapperOptions(curArgv, spec);
    if (idx === AMBIGUOUS) {
      return { cmd0, argv: Array.isArray(argv) ? argv : [], ambiguous: true };
    }
    if (idx === -1) break;
    const next = curArgv[idx];
    if (typeof next !== "string" || next.length === 0) break;
    curCmd = next;
    curArgv = curArgv.slice(idx + 1);
  }
  return { cmd0: curCmd, argv: curArgv, ambiguous: false };
}

// peelWrappers threading the RAW (quote-preserving) argv in lockstep: a plain
// peelWrappers result cannot say how many RAW tokens to drop, which rm.js's
// flag-quoting detection needs (#2210).
function peelWrappersRaw(cmd0, cmd0Raw, argv, argvRaw) {
  let curCmd = cmd0;
  let curCmdRaw = typeof cmd0Raw === "string" ? cmd0Raw : cmd0;
  let curArgv = Array.isArray(argv) ? argv : [];
  let curArgvRaw =
    Array.isArray(argvRaw) && argvRaw.length === curArgv.length ? argvRaw : curArgv.slice();
  for (let depth = 0; depth < 16; depth++) {
    const spec = wrapperSpecFor(curCmd);
    if (!spec) break;
    const idx = skipWrapperOptions(curArgv, spec);
    if (idx === AMBIGUOUS) {
      return {
        cmd0,
        cmd0Raw: typeof cmd0Raw === "string" ? cmd0Raw : cmd0,
        argv: Array.isArray(argv) ? argv : [],
        argvRaw: Array.isArray(argvRaw) ? argvRaw : Array.isArray(argv) ? argv.slice() : [],
        ambiguous: true,
      };
    }
    if (idx === -1) break;
    const next = curArgv[idx];
    if (typeof next !== "string" || next.length === 0) break;
    curCmd = next;
    curCmdRaw = curArgvRaw[idx];
    curArgv = curArgv.slice(idx + 1);
    curArgvRaw = curArgvRaw.slice(idx + 1);
  }
  return { cmd0: curCmd, cmd0Raw: curCmdRaw, argv: curArgv, argvRaw: curArgvRaw, ambiguous: false };
}

function resolveEffectiveCommand(seg) {
  if (!seg || seg.cmd0 == null) return null;
  let cmd0 = seg.cmd0;
  let argv = seg.argv;
  if (ASSIGN_RE.test(cmd0)) {
    if (!Array.isArray(argv)) return null;
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return null;
    cmd0 = argv[idx];
    argv = argv.slice(idx + 1);
  }
  if (wrapperSpecFor(cmd0)) {
    if (!Array.isArray(argv)) return cmd0;
    return peelWrappers(cmd0, argv).cmd0;
  }
  return cmd0;
}

function resolveEffectiveArgv(seg) {
  if (!seg || !Array.isArray(seg.argv)) return [];
  if (seg.cmd0 == null) return [];
  let cmd0 = seg.cmd0;
  let argv = seg.argv;
  if (ASSIGN_RE.test(cmd0)) {
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return [];
    cmd0 = argv[idx];
    argv = argv.slice(idx + 1);
  }
  if (wrapperSpecFor(cmd0)) {
    return peelWrappers(cmd0, argv).argv.slice();
  }
  return argv.slice();
}

// Safety net for the fail-closed peel bail: a wrapped write command may still be
// hiding further along a wrapper segment's argv. Fires only on AMBIGUOUS, so it
// never over-fires on commands resolveEffectiveCommand already resolves.
function scanWrappedVerb(seg, verbTest) {
  if (!seg || seg.cmd0 == null) return false;
  let cmd0 = seg.cmd0;
  let argv = Array.isArray(seg.argv) ? seg.argv : null;
  if (argv === null) return false;
  if (ASSIGN_RE.test(cmd0)) {
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return false;
    cmd0 = argv[idx];
    argv = argv.slice(idx + 1);
  }
  if (!wrapperSpecFor(cmd0)) return false; // not a wrapper — nothing hidden
  const peeled = peelWrappers(cmd0, argv);
  if (!peeled.ambiguous) return false;
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (typeof tok !== "string") continue;
    if (verbTest(tok, argv.slice(i + 1))) return true;
  }
  return false;
}

// Safety net for an interpreter hiding MID-ARGV (`find . -exec sh -c '...'`),
// which scanWrappedVerb cannot cover: its test sees one TOKEN at a time, never
// an interpreter's multi-word `-c` STRING. Excluding anything beyond printed
// data — e.g. gating on isInvokedAsCommandAt — let `ssh host bash -c 'rm -rf d'`
// through (#2210).
function scanWrappedInterpreter(argv) {
  const toks = Array.isArray(argv) ? argv : [];
  const found = [];
  for (let i = 0; i < toks.length; i++) {
    const spec = INTERPRETER_SPECS.get(commandBasename(toks[i]));
    if (!spec) continue;
    if (isPrintedDataAt(toks, i)) continue;
    found.push(...interpreterFoundBodies(spec, toks.slice(i + 1)));
  }
  return found;
}

// ASSIGN_RE / WRAPPER_SPECS / peelWrappers / isAttachedShortValue are exported so
// the #2053 ownership guard reuses this wrapper set instead of re-deriving it.
module.exports = {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  scanWrappedVerb,
  scanWrappedInterpreter,
  interpreterInlineBodies,
  interpreterFoundBodies,
  pwshInterpreterBodies,
  decodeEncodedCommand,
  UNRESOLVABLE_RE,
  INTERPRETER_SPECS,
  PWSH_BODY_SPEC,
  commandBasename,
  isInvokedAsCommandAt,
  isPrintedDataAt,
  ASSIGN_RE,
  WRAPPER_SPECS,
  peelWrappers,
  peelWrappersUntil,
  peelWrappersRaw,
  isAttachedShortValue,
};
