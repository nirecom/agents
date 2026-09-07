"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/wrapper-bodies.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Interpreter wrappers (bash -c / pwsh -Command / ...), the exhaustive
// WRAPPER_SPECS bare-invocation sweep, and the STRING-BODY branches
// (wrapperCommandStringBodies / envSplitStringBodies) in both short- and
// long-flag spellings. See ./harness.js for the shared runTable() runner.

const { runTable } = require("./harness");

// --- Interpreter wrappers (C2) ---
runTable("wrapper", [
  { label: "bash -c 'rm -rf x'", cmd: "bash -c 'rm -rf x'", want: true },
  { label: "sh -c 'rm -r x'", cmd: "sh -c 'rm -r x'", want: true },
  { label: "bash -lc 'rm -rf x' (combined short flags)", cmd: "bash -lc 'rm -rf x'", want: true },
  { label: 'pwsh -Command "Remove-Item -Recurse x"', cmd: 'pwsh -Command "Remove-Item -Recurse x"', want: true },
  // C7: interpreter names beyond bash/sh/pwsh.
  { label: "zsh -c 'rm -rf x'", cmd: "zsh -c 'rm -rf x'", want: true },
  { label: "dash -c 'rm -r x'", cmd: "dash -c 'rm -r x'", want: true },
  { label: "ksh -c 'rm -rf x'", cmd: "ksh -c 'rm -rf x'", want: true },
  { label: 'powershell -Command "Remove-Item -Recurse x" (full name)', cmd: 'powershell -Command "Remove-Item -Recurse x"', want: true },
  // Scope guard (CPR-ORTH): the wrapper route must catch RECURSIVE DELETE only,
  // not every write — this hook is not a general write gate.
  { label: "bash -c 'echo hi > out.txt' (non-recursive write)", cmd: "bash -c 'echo hi > out.txt'", want: false },
  { label: "bash -c 'ls -la' (read-only)", cmd: "bash -c 'ls -la'", want: false },
  // node is deliberately NOT an interpreter wrapper: the sanctioned cleanup path
  // (hooks/cleanup-orphan-dir.js) must stay approvable.
  { label: "node hooks/cleanup-orphan-dir.js (sanctioned path)", cmd: "node hooks/cleanup-orphan-dir.js --force-if-not-registered /tmp/x", want: false },
  // Interpreter-wrapper fail-closed branch (detail.md Step 4 2b): when the
  // inline script BODY contains $/`/(, it is statically unresolvable and the
  // whole call folds to true — even when the body performs no delete at all.
  // This is the conservative, over-blocking half of the branch; the case
  // above ("bash -c 'ls -la'", no $/`/() proves the harmless-body half does
  // NOT trip the same fail-closed path.
  { label: "bash -c \"echo $(date)\" (unresolvable body, no delete at all, fail-closed)", cmd: 'bash -c "echo $(date)"', want: true },
]);

// --- Exhaustive WRAPPER_SPECS coverage (round9 C9): every transparent-wrapper
// entry in segment-utils.js's WRAPPER_SPECS gets its own block/allow pair, so a
// future change to that table cannot silently alter a write-classifier's
// coverage without a failing test pointing at exactly which wrapper regressed
// (CPR-ORTH: sudo/xargs/timeout already have pairs in cases-posix.sh from the
// C1 fix — this table covers the REST of the ~22-entry WRAPPER_SPECS list).
// Bare (no-flag) wrapper invocation is enough to prove the peel reaches the
// wrapped command; flock/chroot/systemd-run need their own mandatory
// positional (lockfile / newroot / unit) before the wrapped command.
runTable("wrapper-specs-exhaustive (round9 C9)", [
  { label: "env rm -rf x", cmd: "env rm -rf x", want: true },
  { label: "env echo hi (harmless)", cmd: "env echo hi", want: false },
  { label: "command rm -rf x", cmd: "command rm -rf x", want: true },
  { label: "command echo hi (harmless)", cmd: "command echo hi", want: false },
  { label: "nice rm -rf x", cmd: "nice rm -rf x", want: true },
  { label: "nice echo hi (harmless)", cmd: "nice echo hi", want: false },
  { label: "nohup rm -rf x", cmd: "nohup rm -rf x", want: true },
  { label: "nohup echo hi (harmless)", cmd: "nohup echo hi", want: false },
  { label: "stdbuf rm -rf x", cmd: "stdbuf rm -rf x", want: true },
  { label: "stdbuf echo hi (harmless)", cmd: "stdbuf echo hi", want: false },
  { label: "setsid rm -rf x", cmd: "setsid rm -rf x", want: true },
  { label: "setsid echo hi (harmless)", cmd: "setsid echo hi", want: false },
  { label: "ionice rm -rf x", cmd: "ionice rm -rf x", want: true },
  { label: "ionice echo hi (harmless)", cmd: "ionice echo hi", want: false },
  { label: "flock /tmp/lock rm -rf x (mandatory lockfile positional)", cmd: "flock /tmp/lock rm -rf x", want: true },
  { label: "flock /tmp/lock echo hi (harmless)", cmd: "flock /tmp/lock echo hi", want: false },
  { label: "parallel rm -rf x", cmd: "parallel rm -rf x", want: true },
  { label: "parallel echo hi (harmless)", cmd: "parallel echo hi", want: false },
  { label: "su rm -rf x", cmd: "su rm -rf x", want: true },
  { label: "su echo hi (harmless)", cmd: "su echo hi", want: false },
  { label: "runuser rm -rf x", cmd: "runuser rm -rf x", want: true },
  { label: "runuser echo hi (harmless)", cmd: "runuser echo hi", want: false },
  { label: "chroot /newroot rm -rf x (mandatory newroot positional)", cmd: "chroot /newroot rm -rf x", want: true },
  { label: "chroot /newroot echo hi (harmless)", cmd: "chroot /newroot echo hi", want: false },
  { label: "nsenter rm -rf x", cmd: "nsenter rm -rf x", want: true },
  { label: "nsenter echo hi (harmless)", cmd: "nsenter echo hi", want: false },
  { label: "systemd-run rm -rf x", cmd: "systemd-run rm -rf x", want: true },
  { label: "systemd-run echo hi (harmless)", cmd: "systemd-run echo hi", want: false },
  { label: "proxychains rm -rf x", cmd: "proxychains rm -rf x", want: true },
  { label: "proxychains echo hi (harmless)", cmd: "proxychains echo hi", want: false },
  { label: "torify rm -rf x", cmd: "torify rm -rf x", want: true },
  { label: "torify echo hi (harmless)", cmd: "torify echo hi", want: false },
  { label: "doas rm -rf x", cmd: "doas rm -rf x", want: true },
  { label: "doas echo hi (harmless)", cmd: "doas echo hi", want: false },
  { label: "unbuffer rm -rf x", cmd: "unbuffer rm -rf x", want: true },
  { label: "unbuffer echo hi (harmless)", cmd: "unbuffer echo hi", want: false },
  { label: "busybox rm -rf x", cmd: "busybox rm -rf x", want: true },
  { label: "busybox echo hi (harmless)", cmd: "busybox echo hi", want: false },
  { label: "watch rm -rf x", cmd: "watch rm -rf x", want: true },
  { label: "watch echo hi (harmless)", cmd: "watch echo hi", want: false },
]);

// --- wrapper-bodies.js STRING-BODY branches (round10 gap 1): `su -c`, `flock
// ... -c`, `runuser -c` hand a full command STRING to a shell rather than
// exec'ing tokens as argv (wrapperCommandStringBodies); `env -S` / `env
// --split-string=` word-split their STRING and exec it (envSplitStringBodies).
// Round9's "wrapper-specs-exhaustive" table only proved the BARE (no -c flag)
// argv peel for su/flock/runuser reaches the wrapped command — it never
// exercised the -c STRING-BODY branch itself, so a regression there had zero
// coverage. Each wrapper gets a block/allow pair on its OWN command string.
runTable("wrapper-command-string-bodies (round10 gap 1)", [
  { label: "su -c 'rm -rf /tmp/x' (su -c string body blocks)", cmd: "su -c 'rm -rf /tmp/x'", want: true },
  { label: "su -c 'ls /tmp/x' (su -c string body, harmless)", cmd: "su -c 'ls /tmp/x'", want: false },
  { label: 'flock /tmp/l -c "rm -rf d" (flock -c string body blocks)', cmd: 'flock /tmp/l -c "rm -rf d"', want: true },
  { label: 'flock /tmp/l -c "ls d" (flock -c string body, harmless)', cmd: 'flock /tmp/l -c "ls d"', want: false },
  { label: "runuser -c 'rm -rf /tmp/x' (runuser -c string body blocks)", cmd: "runuser -c 'rm -rf /tmp/x'", want: true },
  { label: "runuser -c 'ls /tmp/x' (runuser -c string body, harmless)", cmd: "runuser -c 'ls /tmp/x'", want: false },
  { label: "env -S 'rm -rf d' (env -S split-string blocks)", cmd: "env -S 'rm -rf d'", want: true },
  { label: "env -S 'ls d' (env -S split-string, harmless)", cmd: "env -S 'ls d'", want: false },
  { label: "env --split-string='rm -rf d' (env --split-string= form blocks)", cmd: "env --split-string='rm -rf d'", want: true },
  { label: "env --split-string='ls d' (env --split-string= form, harmless)", cmd: "env --split-string='ls d'", want: false },
]);

// --- round11 C3: wrapperCommandStringBodies' `--command`/`--command=` long-form
// branch and envSplitStringBodies' ATTACHED short form (`-S'...'` with no space,
// vs the round10 table's `-S '...'` with a space) — both coded, both untested.
// wrapper-bodies.js line 48 checks `name !== "-c" && name !== "--command"`
// against a `=`-split name, so BOTH the two-token `--command X` and the
// one-token `--command=X` spellings hit the same branch (verified by reading
// wrapper-bodies.js before writing these). envSplitStringBodies line 25 takes
// `tok.slice(2)` off a token that STARTS WITH "-S" and is longer than 2 chars —
// `env -S'rm -rf d'` word-glues the flag and its quoted value into ONE argv
// token ("-Srm -rf d") with no space, which is exactly that branch.
runTable("wrapper-command-string-bodies-longform (round11 C3)", [
  { label: "su --command 'rm -rf /tmp/x' (su --command two-token long-form blocks)", cmd: "su --command 'rm -rf /tmp/x'", want: true },
  { label: "su --command 'ls /tmp/x' (su --command two-token long-form, harmless)", cmd: "su --command 'ls /tmp/x'", want: false },
  { label: 'flock /tmp/l --command="rm -rf d" (flock --command= one-token long-form blocks)', cmd: 'flock /tmp/l --command="rm -rf d"', want: true },
  { label: 'flock /tmp/l --command="ls d" (flock --command= one-token long-form, harmless)', cmd: 'flock /tmp/l --command="ls d"', want: false },
  { label: "runuser --command 'rm -rf /tmp/x' (runuser --command two-token long-form blocks)", cmd: "runuser --command 'rm -rf /tmp/x'", want: true },
  { label: "runuser --command 'ls /tmp/x' (runuser --command two-token long-form, harmless)", cmd: "runuser --command 'ls /tmp/x'", want: false },
  { label: "env -S'rm -rf d' (env -S attached-short form, no space, blocks)", cmd: "env -S'rm -rf d'", want: true },
  { label: "env -S'ls d' (env -S attached-short form, no space, harmless)", cmd: "env -S'ls d'", want: false },
]);

// --- round12 C2: `echo su -c "rm -rf x"` used to false-positive-block — "su"
// there is inert echo ARGUMENT DATA, never the invoked process. Fix (see
// wrapper-bodies.js's own "#2210 C2" comment): only a wrapper name reached by
// peeling from the command HEAD arms the -c/--command body search. Paired
// with a same-shape su-AT-the-head contrast case (already covered above by
// "su -c 'rm -rf /tmp/x'"; restated here double-quoted for a same-table pair).
runTable("wrapper-command-string-head-position (round12 C2)", [
  { label: 'echo su -c "rm -rf x" ("su" is inert echo ARGUMENT DATA, not the command head — must approve)', cmd: 'echo su -c "rm -rf x"', want: false },
  { label: 'su -c "rm -rf x" (su actually AT the head, same string — contrast pair, still blocks)', cmd: 'su -c "rm -rf x"', want: true },
]);
