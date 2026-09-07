"use strict";

// Which command names transparently exec another command, which of their own
// options consume a following token, and how far to skip to reach the wrapped
// command. Split out of segment-utils.js when the wrapper table pushed it past
// the 500-line hard limit (rules/coding/file-split.md); the parent keeps the
// peel/scan half and re-exports this one, so WRAPPER_SPECS still has a single
// owner (CPR-SSOT) shared by every peel variant and the #2053 ownership guard.

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Command wrappers that prefix a real command and transparently exec it. Peeling
// them is a CLASS-level fix (CPR-E2C/CPR-ORTH): every write predicate uniformly
// sees through `command git commit`, `env -u X git commit`, `nice rm f`. Each
// entry declares valueFlags (consume a FOLLOWING token; attached `-n5`/`--adj=5`
// are self-contained), booleanFlags (no argument), ambiguousFlags (force a
// fail-closed refusal), and eatAssignments (env: leading NAME=VALUE tokens are
// consumed). FAIL-CLOSED: an option in NEITHER set
// and not an attached `=value` form is unclassifiable, so skipWrapperOptions
// returns AMBIGUOUS and peelWrappers refuses to peel — see the AMBIGUOUS notes
// on skipWrapperOptions/peelWrappers and the scanWrappedVerb safety net there.
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
  // sudo [-u USER] [-E] [--] [NAME=VALUE]... CMD ... — a transparent exec
  // wrapper like env/nice, so the guards must see the wrapped verb (#2210).
  sudo: {
    valueFlags: new Set([
      "-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from",
      "-h", "--host", "-r", "--role", "-t", "--type", "-U", "--other-user",
      "-T", "--command-timeout", "-D", "--chdir", "-R", "--chroot",
    ]),
    booleanFlags: new Set([
      "-b", "--background", "-E", "--preserve-env", "-H", "--set-home",
      "-i", "--login", "-k", "--reset-timestamp", "-n", "--non-interactive",
      "-P", "--preserve-groups", "-S", "--stdin", "-s", "--shell",
      "-A", "--askpass", "-v", "--validate", "-l", "--list",
      "-e", "--edit", "-K", "--remove-timestamp", "-N", "--no-update",
    ]),
    eatAssignments: true,
  },
  // timeout [-k DUR] [-s SIG] [--preserve-status] [--foreground] DURATION CMD ...
  // DURATION is a mandatory positional before CMD — see `positionalCount` (#2210 F2).
  timeout: {
    valueFlags: new Set(["-k", "--kill-after", "-s", "--signal"]),
    booleanFlags: new Set(["--preserve-status", "--foreground", "-v", "--verbose"]),
    eatAssignments: false,
    positionalCount: 1,
  },
  // flock [-s|-x] [-n] [-w SEC] [-o] FILE CMD ... — `-c` takes a full command
  // STRING, not a token chain, so it is declared AMBIGUOUS: without that the
  // flag loop breaks on FILE before ever seeing `-c` and mis-peels `-c` itself
  // as the wrapped command (#2210 round-4 C1).
  flock: {
    valueFlags: new Set(["-w", "--timeout"]),
    booleanFlags: new Set(["-s", "--shared", "-x", "--exclusive", "-n", "--nonblock", "-o", "--close"]),
    ambiguousFlags: new Set(["-c", "--command"]),
    eatAssignments: false,
    positionalCount: 1,
  },
  // xargs [options] CMD ARGS... — the trailing tokens ARE the command it runs,
  // so `echo dir | xargs rm -rf` must peel like nice/stdbuf (#2210 round-4 C5).
  // `-I`/`-i`/`-L`/`-l` are modeled value-taking (their common separated form);
  // an attached `-i{}`/`-L2` still resolves via isAttachedShortValue.
  xargs: {
    valueFlags: new Set([
      "-a", "--arg-file", "-d", "--delimiter", "-E", "-e", "--eof",
      "-I", "-i", "--replace", "-L", "--max-lines", "-l", "-n", "--max-args",
      "-P", "--max-procs", "-s", "--max-chars",
    ]),
    booleanFlags: new Set([
      "-0", "--null", "-p", "--interactive", "-r", "--no-run-if-empty",
      "-t", "--verbose", "-x", "--exit",
    ]),
    eatAssignments: false,
  },
  // parallel [options] CMD ARGS... — GNU parallel's flag grammar is too large to
  // model safely, so NO flag is declared known: any option makes the peel
  // AMBIGUOUS (fail-closed) while the bare `parallel rm -rf {}` form resolves.
  parallel: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  // su [-l] [-s SHELL] [-u USER] CMD ... — privilege wrapper, same class as
  // sudo/doas (#2210 round-4 C12). `-c` carries a command STRING (flock's
  // hazard), so it is AMBIGUOUS rather than an ordinary value flag.
  su: {
    valueFlags: new Set(["-s", "--shell", "-u", "--user", "-g", "--group"]),
    booleanFlags: new Set(["-l", "--login", "-p", "-m", "--preserve-environment"]),
    ambiguousFlags: new Set(["-c", "--command"]),
    eatAssignments: false,
  },
  runuser: {
    valueFlags: new Set(["-s", "--shell", "-u", "--user", "-g", "--group"]),
    booleanFlags: new Set(["-l", "--login", "-p", "-m", "--preserve-environment"]),
    ambiguousFlags: new Set(["-c", "--command"]),
    eatAssignments: false,
  },
  // chroot NEWROOT CMD ... — NEWROOT is a mandatory positional, like flock's FILE.
  chroot: {
    valueFlags: new Set(["--userspec", "--groups"]),
    booleanFlags: new Set(["--skip-chdir"]),
    eatAssignments: false,
    positionalCount: 1,
  },
  // nsenter [options] CMD ... — namespace flags with an OPTIONAL [FILE] argument
  // are modeled boolean; an attached form still fails closed via the unknown-flag
  // AMBIGUOUS path.
  nsenter: {
    valueFlags: new Set(["-t", "--target", "-S", "--setuid", "-G", "--setgid", "-w", "--wd", "-r", "--root"]),
    booleanFlags: new Set([
      "-m", "--mount", "-u", "--uts", "-i", "--ipc", "-n", "--net",
      "-p", "--pid", "-C", "--cgroup", "-U", "--user", "-a", "--all", "-F", "--no-fork",
    ]),
    eatAssignments: false,
  },
  // systemd-run [options] CMD ... — modeled conservatively: only the most common
  // flags are declared, so anything else fails closed rather than mis-peeling.
  "systemd-run": {
    valueFlags: new Set(["-p", "--property", "-M", "--machine", "-H", "--host", "-u", "--unit", "--slice"]),
    booleanFlags: new Set(["--user", "--system", "--scope", "-t", "--pty", "-q", "--quiet", "-d", "--details"]),
    eatAssignments: false,
  },
  // proxychains / torify CMD ARGS... — no options of their own in common usage.
  proxychains: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  torify: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  // doas [-u USER] CMD ... — OpenBSD/doas-port sudo-alike, boolean-only besides -u.
  doas: {
    valueFlags: new Set(["-u"]),
    booleanFlags: new Set(["-n"]),
    eatAssignments: false,
  },
  // unbuffer [-p] CMD ... — expect's stdio-buffering shim, boolean flags only.
  unbuffer: { valueFlags: new Set(), booleanFlags: new Set(["-p"]), eatAssignments: false },
  // busybox APPLET ... — APPLET *is* the wrapped command itself (no flags of its
  // own precede it), so no `positionalCount` is needed: the default "first
  // non-flag token is the wrapped command" behavior already lands on APPLET.
  busybox: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  // watch [-n SEC] [-d] [-t] [-b] [-e] [-g] [-c] [-x] CMD ... — CMD follows options
  // directly, no mandatory positional.
  watch: {
    valueFlags: new Set(["-n", "--interval"]),
    booleanFlags: new Set([
      "-d", "--differences", "-t", "--no-title", "-b", "--beep",
      "-e", "--errexit", "-g", "--chgexit", "-c", "--color", "-x", "--exec",
    ]),
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
      // Declared-ambiguous option (a `-c COMMAND` string this peel cannot model
      // as a token chain): refuse to peel instead of guessing (#2210 C1/C12).
      if (spec.ambiguousFlags && spec.ambiguousFlags.has(eq === -1 ? tok : tok.slice(0, eq))) {
        return AMBIGUOUS;
      }
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
  // Mandatory positional(s) before the wrapped command (`timeout DURATION cmd`,
  // `flock FILE cmd`, `busybox APPLET ...`) — consumed unconditionally, #2210 F2.
  if (spec.positionalCount) i += spec.positionalCount;
  // An ambiguous option can also sit AFTER that positional (`flock FILE -c CMD`),
  // where the flag loop above broke on FILE before ever reaching it (#2210 C1).
  if (spec.ambiguousFlags && i < argv.length && typeof argv[i] === "string" &&
      spec.ambiguousFlags.has(argv[i].split("=")[0])) {
    return AMBIGUOUS;
  }
  return i < argv.length ? i : -1;
}

module.exports = {
  ASSIGN_RE,
  AMBIGUOUS,
  WRAPPER_SPECS,
  commandBasename,
  wrapperSpecFor,
  isAttachedShortValue,
  skipWrapperOptions,
};
