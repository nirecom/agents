"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/wrapper-bodies.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Interpreter wrappers, the exhaustive WRAPPER_SPECS sweep, and the
// string-body branches in both short- and long-flag spellings.

const { runTable } = require("./harness");

runTable("wrapper", [
  { label: "bash -c 'rm -rf x'", cmd: "bash -c 'rm -rf x'", want: true },
  { label: "sh -c 'rm -r x'", cmd: "sh -c 'rm -r x'", want: true },
  { label: "bash -lc 'rm -rf x' (combined short flags)", cmd: "bash -lc 'rm -rf x'", want: true },
  { label: 'pwsh -Command "Remove-Item -Recurse x"', cmd: 'pwsh -Command "Remove-Item -Recurse x"', want: true },
  { label: "zsh -c 'rm -rf x'", cmd: "zsh -c 'rm -rf x'", want: true },
  { label: "dash -c 'rm -r x'", cmd: "dash -c 'rm -r x'", want: true },
  { label: "ksh -c 'rm -rf x'", cmd: "ksh -c 'rm -rf x'", want: true },
  { label: 'powershell -Command "Remove-Item -Recurse x" (full name)', cmd: 'powershell -Command "Remove-Item -Recurse x"', want: true },
  // Scope guard: this hook catches recursive delete only, not every write.
  { label: "bash -c 'echo hi > out.txt' (non-recursive write)", cmd: "bash -c 'echo hi > out.txt'", want: false },
  { label: "bash -c 'ls -la' (read-only)", cmd: "bash -c 'ls -la'", want: false },
  // node is deliberately NOT a wrapper: the sanctioned cleanup script must stay approvable.
  { label: "node hooks/cleanup-orphan-dir.js (sanctioned path)", cmd: "node hooks/cleanup-orphan-dir.js --force-if-not-registered /tmp/x", want: false },
  // A statically unresolvable inline body folds to true even with no delete in
  // it; the "bash -c 'ls -la'" row above proves a resolvable body does not.
  { label: "bash -c \"echo $(date)\" (unresolvable body, no delete at all, fail-closed)", cmd: 'bash -c "echo $(date)"', want: true },
]);

// One block/allow pair per WRAPPER_SPECS entry, so a change to that table
// cannot silently drop coverage without naming the regressed wrapper.
// sudo, xargs and timeout are covered in cases-posix.sh instead.
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

// These wrappers hand a full command STRING to a shell instead of exec'ing
// argv tokens, so the bare-invocation sweep above never reaches this branch.
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

// The long-form spellings split on `=`, so two-token and one-token forms hit
// the same branch; an attached `-S'...'` arrives word-glued as ONE argv token.
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

// Regression: a wrapper name appearing as inert ARGUMENT DATA once armed the
// body search; only a name reached by peeling from the command HEAD may.
runTable("wrapper-command-string-head-position (round12 C2)", [
  { label: 'echo su -c "rm -rf x" ("su" is inert echo ARGUMENT DATA, not the command head — must approve)', cmd: 'echo su -c "rm -rf x"', want: false },
  { label: 'su -c "rm -rf x" (su actually AT the head, same string — contrast pair, still blocks)', cmd: 'su -c "rm -rf x"', want: true },
]);
