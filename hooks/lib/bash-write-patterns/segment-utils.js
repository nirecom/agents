"use strict";
const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Command wrappers that prefix a real command and transparently exec it. Peeling
// them is a CLASS-level fix (CPR-4/5): every write predicate that resolves a
// segment's effective command (green file-op / pwsh / redirect predicates AND
// isGitWriteIR) uniformly sees through `command git commit`, `env -u X git commit`,
// `nice rm f`, etc. Without peeling, a wrapper hides the write verb and the
// command fast-allows past the main-worktree guard (security regression).
//
// Each entry declares BOTH:
//   valueFlags   — options that consume a FOLLOWING token as their argument
//                  (separated form `-n 5`; attached `-n5` and `--adj=5` are
//                  self-contained so they consume only their own token).
//   booleanFlags — options that take NO argument (skip just the flag).
// eatAssignments (env only): leading NAME=VALUE tokens are consumed.
//
// FAIL-CLOSED (security): if a wrapper is followed by an option that is in
// NEITHER set and is not an attached `=value` form, we CANNOT know whether it
// consumes the next token. Skipping just the flag risks treating that option's
// argument as the wrapped command and HIDING a real write (e.g. `env -Z val git
// commit` → mis-resolves to `val`, isGitWriteIR misses `git commit` = BYPASS).
// So skipWrapperOptions returns AMBIGUOUS and peelWrappers refuses to peel,
// leaving the ORIGINAL cmd0 intact. Detection then relies on the raw command
// (the wrapper name is not a write verb) PLUS the wrappedWriteVerbScan safety
// net below, so `<wrapper> ...unknown... git <writeverb>` is still caught.
const AMBIGUOUS = -2; // distinct from -1 ("no wrapped command remains")

const WRAPPER_SPECS = {
  // env [-i] [-u NAME]... [-C DIR] [-S STRING] [--] [NAME=VALUE]... CMD ...
  env: {
    valueFlags: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
    booleanFlags: new Set(["-i", "--ignore-environment", "-0", "--null", "-v", "--debug"]),
    eatAssignments: true,
  },
  // command [-p] [-v] [-V] CMD ... — bare boolean flags only.
  command: { valueFlags: new Set(), booleanFlags: new Set(["-p", "-v", "-V"]), eatAssignments: false },
  // nice [-n ADJUST] [--adjustment=ADJUST] CMD ...
  nice: { valueFlags: new Set(["-n", "--adjustment"]), booleanFlags: new Set(), eatAssignments: false },
  // nohup CMD ... — no options.
  nohup: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  // stdbuf -i MODE -o MODE -e MODE CMD (separated `-o L` and attached `-oL` both
  // supported: `-oL` is a self-contained attached token, `-o L` consumes `L`).
  stdbuf: {
    valueFlags: new Set(["-i", "--input", "-o", "--output", "-e", "--error"]),
    booleanFlags: new Set(),
    eatAssignments: false,
  },
  // setsid [-w] [-f] CMD ... — boolean flags only.
  setsid: { valueFlags: new Set(), booleanFlags: new Set(["-w", "--wait", "-f", "--fork", "-c", "--ctty"]), eatAssignments: false },
  // ionice [-c N] [-n N] [-p PID] [-t] CMD ... — NOTE: with -p PID there is
  // typically NO wrapped command; -p is value-taking so its PID is consumed and
  // the peel resolves to whatever follows (or -1 when nothing does).
  ionice: {
    valueFlags: new Set(["-c", "--class", "-n", "--classdata", "-p", "--pid"]),
    booleanFlags: new Set(["-t", "--ignore"]),
    eatAssignments: false,
  },
};

// Normalize a command token to its lowercase basename with any trailing `.exe`
// stripped — the shared FORM-normalization used by wrapper / verb basename checks
// (FIX B). `/usr/bin/rm` → `rm`, `stdbuf.exe` → `stdbuf`, `./nice` → `nice`.
function commandBasename(cmd0) {
  if (typeof cmd0 !== "string" || cmd0 === "") return null;
  const base = cmd0.split(/[\\/]/).pop();
  if (!base) return null;
  return base.replace(/\.exe$/i, "").toLowerCase();
}

// Look up a wrapper spec by BASENAME so path-qualified / `.exe` wrapper spellings
// resolve too (FIX B): `/usr/bin/env`, `/bin/nohup`, `stdbuf.exe`, `./nice` all
// map to their WRAPPER_SPECS entry. Strip any directory prefix (POSIX `/` or
// Windows `\`) and a trailing `.exe`, lowercase, then look up. Returns the spec or
// undefined. Mirrors isGitBasename's normalization (git-write-ir.js).
function wrapperSpecFor(cmd0) {
  const norm = commandBasename(cmd0);
  return norm ? WRAPPER_SPECS[norm] : undefined;
}

// True when a token could be an ATTACHED short-option value form, e.g. `-oL`
// (stdbuf), `-n5` (nice): a single-dash flag whose known prefix is value-taking
// but which carries the value glued on. Such a token is self-contained (consumes
// only itself). We treat any single-dash token longer than 2 chars whose 2-char
// prefix is a declared value flag as attached-value (skip 1). This keeps `-oL`
// from being misread as an unknown ambiguous flag.
function isAttachedShortValue(tok, spec) {
  if (tok.length <= 2 || tok[1] === "-") return false; // not `-Xrest` short form
  const prefix = tok.slice(0, 2);
  return spec.valueFlags.has(prefix);
}

// Advance an argv array past one wrapper's own options to the wrapped command.
// Returns the index of the wrapped command token, -1 if none remains, or
// AMBIGUOUS (-2) when an unclassifiable option is encountered (fail-closed).
function skipWrapperOptions(argv, spec) {
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") return AMBIGUOUS; // non-string token — cannot classify
    if (spec.eatAssignments && ASSIGN_RE.test(tok)) { i += 1; continue; }
    if (tok[0] === "-") {
      // `--` explicitly ends option parsing; the next token is the command.
      if (tok === "--") { i += 1; break; }
      const eq = tok.indexOf("=");
      if (eq !== -1) {
        // attached `--flag=value` / `-c=v` form — self-contained, skip 1.
        // (Only classify as known if the flag name is recognized; an unknown
        //  `--x=y` is still self-contained so it is safe to skip just it.)
        i += 1;
        continue;
      }
      const flagName = tok;
      if (spec.valueFlags.has(flagName)) { i += 2; continue; }   // flag + separate value
      if (spec.booleanFlags.has(flagName)) { i += 1; continue; } // known no-arg flag
      if (isAttachedShortValue(tok, spec)) { i += 1; continue; } // e.g. `-oL`, `-n5`
      // Unrecognized option: cannot know if it consumes the next token.
      // Fail-closed — refuse to peel (see AMBIGUOUS rationale above).
      return AMBIGUOUS;
    }
    break; // first non-flag (non-assignment) token = wrapped command
  }
  return i < argv.length ? i : -1;
}

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
// for a bare occurrence of `<verb>` at a token position and return true when the
// verb matches a supplied predicate. Only applies to segments whose cmd0 is a
// known wrapper (or resolves to one via an env-prefix); a non-wrapper segment is
// already fully resolved by resolveEffectiveCommand.
//
// verbTest(token, restTokens) → boolean. restTokens are the tokens after `token`.
// This is intentionally conservative: it fires only inside wrapper segments and
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

module.exports = { resolveEffectiveCommand, resolveEffectiveArgv, scanWrappedVerb, commandBasename };
