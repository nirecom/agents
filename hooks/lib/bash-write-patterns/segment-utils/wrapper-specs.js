"use strict";

// Which command names transparently exec another command, which of their own
// options consume a following token, and how far to skip to reach the wrapped one.

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Wrappers that prefix a real command and transparently exec it, so every write
// predicate sees through `env -u X git commit`, `nice rm f`. An option in
// NEITHER valueFlags nor booleanFlags, and not an attached `=value`, is
// unclassifiable: skipWrapperOptions returns AMBIGUOUS and the peel is refused.
const AMBIGUOUS = -2; // distinct from -1 ("no wrapped command remains")

const WRAPPER_SPECS = {
  env: {
    valueFlags: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
    booleanFlags: new Set(["-i", "--ignore-environment", "-0", "--null", "-v", "--debug"]),
    eatAssignments: true,
  },
  command: { valueFlags: new Set(), booleanFlags: new Set(["-p", "-v", "-V"]), eatAssignments: false },
  nice: { valueFlags: new Set(["-n", "--adjustment"]), booleanFlags: new Set(), eatAssignments: false },
  nohup: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  stdbuf: {
    valueFlags: new Set(["-i", "--input", "-o", "--output", "-e", "--error"]),
    booleanFlags: new Set(),
    eatAssignments: false,
  },
  setsid: { valueFlags: new Set(), booleanFlags: new Set(["-w", "--wait", "-f", "--fork", "-c", "--ctty"]), eatAssignments: false },
  // With `-p PID` there is typically no wrapped command; -p consumes the PID so
  // the peel resolves to whatever follows, or -1 when nothing does.
  ionice: {
    valueFlags: new Set(["-c", "--class", "-n", "--classdata", "-p", "--pid"]),
    booleanFlags: new Set(["-t", "--ignore"]),
    eatAssignments: false,
  },
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
  // DURATION is a mandatory positional before CMD (#2210).
  timeout: {
    valueFlags: new Set(["-k", "--kill-after", "-s", "--signal"]),
    booleanFlags: new Set(["--preserve-status", "--foreground", "-v", "--verbose"]),
    eatAssignments: false,
    positionalCount: 1,
  },
  // `-c` takes a command STRING, not a token chain: without AMBIGUOUS the flag
  // loop breaks on FILE and mis-peels `-c` itself as the command (#2210).
  flock: {
    valueFlags: new Set(["-w", "--timeout"]),
    booleanFlags: new Set(["-s", "--shared", "-x", "--exclusive", "-n", "--nonblock", "-o", "--close"]),
    ambiguousFlags: new Set(["-c", "--command"]),
    eatAssignments: false,
    positionalCount: 1,
  },
  // Trailing tokens ARE the command, so `echo dir | xargs rm -rf` must peel
  // (#2210). `-I`/`-L` are modeled separated; attached `-i{}` resolves via
  // isAttachedShortValue.
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
  // GNU parallel's flag grammar is too large to model, so no flag is declared:
  // any option is AMBIGUOUS while bare `parallel rm -rf {}` still resolves.
  parallel: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  // `-c` carries a command STRING (flock's hazard), so it is AMBIGUOUS rather
  // than an ordinary value flag (#2210).
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
  // NEWROOT is a mandatory positional, like flock's FILE.
  chroot: {
    valueFlags: new Set(["--userspec", "--groups"]),
    booleanFlags: new Set(["--skip-chdir"]),
    eatAssignments: false,
    positionalCount: 1,
  },
  // Namespace flags with an OPTIONAL [FILE] argument are modeled boolean; an
  // attached form still fails closed via the unknown-flag AMBIGUOUS path.
  nsenter: {
    valueFlags: new Set(["-t", "--target", "-S", "--setuid", "-G", "--setgid", "-w", "--wd", "-r", "--root"]),
    booleanFlags: new Set([
      "-m", "--mount", "-u", "--uts", "-i", "--ipc", "-n", "--net",
      "-p", "--pid", "-C", "--cgroup", "-U", "--user", "-a", "--all", "-F", "--no-fork",
    ]),
    eatAssignments: false,
  },
  // Only the most common flags are declared; anything else fails closed.
  "systemd-run": {
    valueFlags: new Set(["-p", "--property", "-M", "--machine", "-H", "--host", "-u", "--unit", "--slice"]),
    booleanFlags: new Set(["--user", "--system", "--scope", "-t", "--pty", "-q", "--quiet", "-d", "--details"]),
    eatAssignments: false,
  },
  proxychains: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  torify: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  doas: {
    valueFlags: new Set(["-u"]),
    booleanFlags: new Set(["-n"]),
    eatAssignments: false,
  },
  unbuffer: { valueFlags: new Set(), booleanFlags: new Set(["-p"]), eatAssignments: false },
  // busybox needs no positionalCount: its APPLET *is* the wrapped command, so
  // the default "first non-flag token" already lands on it.
  busybox: { valueFlags: new Set(), booleanFlags: new Set(), eatAssignments: false },
  watch: {
    valueFlags: new Set(["-n", "--interval"]),
    booleanFlags: new Set([
      "-d", "--differences", "-t", "--no-title", "-b", "--beep",
      "-e", "--errexit", "-g", "--chgexit", "-c", "--color", "-x", "--exec",
    ]),
    eatAssignments: false,
  },
};

// `/usr/bin/rm` → `rm`, `stdbuf.exe` → `stdbuf`, `./nice` → `nice`.
function commandBasename(cmd0) {
  if (typeof cmd0 !== "string" || cmd0 === "") return null;
  const base = cmd0.split(/[\\/]/).pop();
  if (!base) return null;
  return base.replace(/\.exe$/i, "").toLowerCase();
}

// Look up by BASENAME so `/usr/bin/env`, `stdbuf.exe`, `./nice` resolve too.
function wrapperSpecFor(cmd0) {
  const norm = commandBasename(cmd0);
  return norm ? WRAPPER_SPECS[norm] : undefined;
}

// An ATTACHED short-option value (`-oL`, `-n5`) is self-contained; without this
// it would be misread as an unknown, hence AMBIGUOUS, flag.
function isAttachedShortValue(tok, spec) {
  if (tok.length <= 2 || tok[1] === "-") return false; // not `-Xrest` short form
  const prefix = tok.slice(0, 2);
  return spec.valueFlags.has(prefix);
}

// Index of the wrapped command token, -1 if none remains, or AMBIGUOUS.
function skipWrapperOptions(argv, spec) {
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") return AMBIGUOUS; // non-string token — cannot classify
    if (spec.eatAssignments && ASSIGN_RE.test(tok)) { i += 1; continue; }
    if (tok[0] === "-") {
      if (tok === "--") { i += 1; break; }
      const eq = tok.indexOf("=");
      if (spec.ambiguousFlags && spec.ambiguousFlags.has(eq === -1 ? tok : tok.slice(0, eq))) {
        return AMBIGUOUS;
      }
      if (eq !== -1) {
        // Attached `--flag=value` is self-contained even when unrecognized.
        i += 1;
        continue;
      }
      const flagName = tok;
      if (spec.valueFlags.has(flagName)) { i += 2; continue; }   // flag + separate value
      if (spec.booleanFlags.has(flagName)) { i += 1; continue; } // known no-arg flag
      if (isAttachedShortValue(tok, spec)) { i += 1; continue; } // e.g. `-oL`, `-n5`
      return AMBIGUOUS; // unknown arity — cannot know if it consumes the next token
    }
    break; // first non-flag (non-assignment) token = wrapped command
  }
  // Mandatory positional(s) before the wrapped command (`timeout DURATION cmd`).
  if (spec.positionalCount) i += spec.positionalCount;
  // An ambiguous option can sit AFTER that positional (`flock FILE -c CMD`),
  // where the loop above broke on FILE before reaching it (#2210).
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
