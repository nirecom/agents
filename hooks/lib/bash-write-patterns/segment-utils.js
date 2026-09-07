"use strict";

// The interpreter half — which names carry an inline program body and how to
// extract it — lives in ./segment-utils/interpreter-specs.js, and the wrapper
// TABLE plus its option-skipping in ./segment-utils/wrapper-specs.js
// (file-split); this file keeps the peel/scan half and re-exports both, so
// callers keep one import.
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

// Peel any chain of leading command wrappers (env/command/nice/nohup/...) from a
// synthetic {cmd0, argv}. Returns the innermost {cmd0, argv} (argv excludes cmd0)
// plus `ambiguous` (true when peeling was refused mid-chain). On ambiguity the
// ORIGINAL cmd0/argv are returned unchanged so raw detection still sees them.
// Bounded iteration guards against pathological nesting.
function peelWrappers(cmd0, argv) {
  let curCmd = cmd0;
  let curArgv = Array.isArray(argv) ? argv : [];
  for (let depth = 0; depth < 16; depth++) {
    const spec = wrapperSpecFor(curCmd);
    if (!spec) break;
    const idx = skipWrapperOptions(curArgv, spec);
    if (idx === AMBIGUOUS) {
      // Fail-closed: do not hide a potential write behind an unclassifiable
      // option. Return the ORIGINAL (pre-peel) cmd0 so callers fall back to
      // raw-command detection + the wrappedWriteVerbScan safety net.
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

// True when tokens[idx] is genuinely INVOKED as a command by what precedes it:
// the head (after any NAME=VALUE prefix), a `find -exec` argument, or the end
// of a real wrapper chain (`sudo su`, `timeout 5 su`, and the AMBIGUOUS forms
// `env --bogusopt su` / `nice -X su`). A name sitting in argv as DATA
// (`echo su -c "rm -rf x"`) is not — the distinction a head-position-only test
// draws too narrowly (#2210).
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
      // Chain is real, only the unknown option's arity is not: accept idx when
      // every token in between is itself option- or assignment-shaped.
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

// True when tokens[idx] sits in a text producer's argument list, i.e. it is
// DATA (`echo su -c "rm -rf x"`, #2210 round-10). Everything else — a
// transparent-exec head this module does not model (ssh, docker run, kubectl
// exec, npx, make, strace, gdb --args, firejail, poetry run, ...), `find -exec`,
// a wrapper chain, the head itself — stays a possible invocation, so the
// mid-argv nets keep their broad reading there (#2210 round-15 item 2).
function isPrintedDataAt(tokens, idx) {
  const toks = Array.isArray(tokens) ? tokens : [];
  for (let i = 0; i < idx && i < toks.length; i++) {
    if (typeof toks[i] !== "string") continue;
    if (!TEXT_PRODUCERS.has(commandBasename(toks[i]))) continue;
    if (isInvokedAsCommandAt(toks, i)) return true;
  }
  return false;
}

// Same peel as peelWrappers, but stops BEFORE unwrapping a basename in
// `stopBasenames` even though it is itself a registered wrapper (#2210
// round-8). `xargs` is one such entry: recursive-delete-scan.js and rm.js want
// to see straight through to the command it runs, but exotic-exec.js's
// isExoticExecWriteIR needs `xargs` itself — it applies its own, more specific,
// dynamic-argument handling to the command xargs runs rather than treating it
// like an ordinary transparent wrapper.
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

// Same peel as peelWrappers, but threads the RAW (quote-preserving) argv in
// lockstep so a caller that must classify on raw text (rm.js's flag-quoting
// detection, #2210 F1/F2) sees the wrapper's OWN options skipped rather than
// the wrapped command's — a bare peelWrappers(cmd0, argv) result cannot say
// how many RAW tokens to drop. AMBIGUOUS is reported via the same
// `ambiguous: true` contract as peelWrappers — the original raw argv is
// returned unchanged so a fail-closed caller still has full raw text to scan.
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
  // Skip leading NAME=VALUE assignments (inline env-prefix, e.g. `A=1 B=2 tee`).
  if (ASSIGN_RE.test(cmd0)) {
    if (!Array.isArray(argv)) return null;
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return null;
    cmd0 = argv[idx];
    argv = argv.slice(idx + 1);
  }
  // Peel command wrappers (env/command/nice/nohup/...) so the real command surfaces.
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

// Safety net for the fail-closed peel bail (AMBIGUOUS): even when peelWrappers
// refuses to resolve past an unclassifiable option, a wrapped write command may
// still be hiding further along the argv. Scan the RAW argv of a wrapper segment
// and return true when verbTest(token, restTokens) matches. Only applies to
// segments whose cmd0 is a known wrapper (or resolves to one via an env-prefix);
// a non-wrapper segment is already resolved by resolveEffectiveCommand. It fires
// only when the effective command could NOT be cleanly resolved, so it never
// over-fires on ordinary commands.
function scanWrappedVerb(seg, verbTest) {
  if (!seg || seg.cmd0 == null) return false;
  let cmd0 = seg.cmd0;
  let argv = Array.isArray(seg.argv) ? seg.argv : null;
  if (argv === null) return false;
  // Penetrate a leading env-prefix (NAME=VALUE... wrapperName ...).
  if (ASSIGN_RE.test(cmd0)) {
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return false;
    cmd0 = argv[idx];
    argv = argv.slice(idx + 1);
  }
  if (!wrapperSpecFor(cmd0)) return false; // not a wrapper — nothing hidden
  // Only engage the safety net when a clean peel is NOT possible (ambiguous).
  const peeled = peelWrappers(cmd0, argv);
  if (!peeled.ambiguous) return false;
  // Ambiguous: scan raw argv tokens for a wrapped write verb.
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (typeof tok !== "string") continue;
    if (verbTest(tok, argv.slice(i + 1))) return true;
  }
  return false;
}

// Safety net for an interpreter hiding MID-ARGV, where the effective-command
// path never lands on it: an AMBIGUOUS peel returns the wrapper itself
// (`env --bogusopt sh -c '...'`), and a non-wrapper head is never peeled at all
// (`find . -exec sh -c '...'`). scanWrappedVerb cannot cover this class — its
// test sees one TOKEN at a time, never an interpreter's multi-word `-c` STRING.
// Only PRINTED DATA is excluded (isPrintedDataAt), the asymmetry round-10 hit
// with `echo python -c '...'` scanned while `echo su -c '...'` was not. Gating
// on isInvokedAsCommandAt instead narrowed the net to heads this module models
// as wrappers, letting `ssh host bash -c 'rm -rf d'` through (#2210 round-15).
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

// ASSIGN_RE / WRAPPER_SPECS / peelWrappers / isAttachedShortValue are exported
// for #2053: the forge-target-ownership guard peels the same wrapper set this
// module already models, rather than re-deriving it (CPR-SSOT).
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
