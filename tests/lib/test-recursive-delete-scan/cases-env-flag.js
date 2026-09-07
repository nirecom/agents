"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/var-tracking.js  (lang-check: ignore)
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Variable-flag bypass tracking, plus the encoded-Command and cross-newline
// rows whose "out of scope" label the implementation has since outgrown.

const { runTable } = require("./harness");

runTable("env-flag", [
  { label: "FLAGS=-rf; rm $FLAGS x", cmd: "FLAGS=-rf; rm $FLAGS x", want: true },
  { label: 'FLAGS=-rf; rm "$FLAGS" x (double-quoted reference)', cmd: 'FLAGS=-rf; rm "$FLAGS" x', want: true },
  { label: "FLAGS=-rf; rm ${FLAGS} x (braced reference)", cmd: "FLAGS=-rf; rm ${FLAGS} x", want: true },
  { label: "FLAGS=-f; rm $FLAGS x (assigned flag is not recursive)", cmd: "FLAGS=-f; rm $FLAGS x", want: false },
  { label: "FLAGS=-rf; rm $OTHER x (variable name mismatch)", cmd: "FLAGS=-rf; rm $OTHER x", want: false },
  // Accepted gap pinned as spec: tracking is forward-only, like a real shell.
  { label: "rm $FLAGS x; FLAGS=-rf (assignment after the rm — accepted gap)", cmd: "rm $FLAGS x; FLAGS=-rf", want: false },
  // An inline env-prefix does not reach the same command's own expansion, so
  // this is not a working bypass and must not be blocked.
  { label: "FLAGS=-rf rm $FLAGS x (inline env-prefix, same segment)", cmd: "FLAGS=-rf rm $FLAGS x", want: false },
  { label: 'DIR=/tmp/x; rm "$DIR" (variable target, non-recursive)', cmd: 'DIR=/tmp/x; rm "$DIR"', want: false },
  // Reassignment and `unset` must DROP the tracked name; keeping it over-blocks.
  { label: "FLAGS=-rf; FLAGS=-f; rm $FLAGS x (reassigned to a safe value before use)", cmd: "FLAGS=-rf; FLAGS=-f; rm $FLAGS x", want: false },
  { label: "FLAGS=-rf; unset FLAGS; rm $FLAGS x (unset clears tracking, round-4)", cmd: "FLAGS=-rf; unset FLAGS; rm $FLAGS x", want: false },
  // A flag-shaped parameter-expansion default classifies as the literal flag.
  { label: "rm ${X:--rf} /tmp/x (param-expansion default is flag-shaped, N5)", cmd: "rm ${X:--rf} /tmp/x", want: true },
  { label: "rm ${X:=-rf} /tmp/x (round9 C11: := assign-default operand, PARAM_EXPANSION_RE)", cmd: "rm ${X:=-rf} /tmp/x", want: true },

  // Literal values, not a boolean: `$A$B` must reassemble into one flag string.
  { label: "A=-; B=rf; rm $A$B x (split-variable concatenation reassembles to -rf)", cmd: "A=-; B=rf; rm $A$B x", want: true },
  { label: "A=-; B=f; rm $A$B x (split-variable concatenation reassembles to -f, safe)", cmd: "A=-; B=f; rm $A$B x", want: false },
  // A bare `export FLAGS` (no `=`) must neither re-assert nor drop the tracked value.
  { label: "FLAGS=-rf; export FLAGS; rm $FLAGS x (bare re-export of an already-tracked var)", cmd: "FLAGS=-rf; export FLAGS; rm $FLAGS x", want: true },
]);

runTable("out-of-scope", [
  {
    label: "export FLAGS=-rf; rm $FLAGS x (export carries the assignment too, #2210 N5)",
    cmd: "export FLAGS=-rf; rm $FLAGS x",
    want: true,
  },
  {
    label: "declare -x FLAGS=-rf; rm $FLAGS x (declare carries the assignment too, #2210 N5)",
    cmd: "declare -x FLAGS=-rf; rm $FLAGS x",
    want: true,
  },
]);

// The base64 UTF-16LE payload IS decoded and re-scanned; the plan's "never
// decoded" non-goal is stale, so both directions are pinned here.
runTable("encoded-command (round9: no longer a documented non-goal)", [
  {
    label: "pwsh -EncodedCommand <base64 of Remove-Item -Recurse x> (now decoded and scanned, blocks)",
    cmd: "pwsh -EncodedCommand UgBlAG0AbwB2AGUALQBJAHQAZQBtACAALQBSAGUAYwB1AHIAcwBlACAAeAA=",
    want: true,
  },
  {
    label: "pwsh -EncodedCommand <base64 of Get-ChildItem x> (decoded, harmless body approves)",
    cmd: "pwsh -EncodedCommand RwBlAHQALQBDAGgAaQBsAGQASQB0AGUAbQAgAHgA",
    want: false,
  },
]);

runTable("cross-newline var correlation (round9: no longer a documented non-goal)", [
  // The newline route carries tracked vars forward as `inheritedVars`, so an
  // assignment on an earlier line does reach a reference on a later one.
  {
    label: "FLAGS=-rf split across newline from its reference (now tracked, blocks)",
    cmd: "FLAGS=-rf\nrm $FLAGS x",
    want: true,
  },
  {
    label: "FLAGS=-rf, harmless line between, then reference on a third line (tracked across >1 intervening line)",
    cmd: "FLAGS=-rf\necho mid\nrm $FLAGS x",
    want: true,
  },
  {
    label: "FLAGS=-f (safe) split across newline from its reference (tracked, stays approved)",
    cmd: "FLAGS=-f\nrm $FLAGS x",
    want: false,
  },
  {
    label: "rm $FLAGS x; FLAGS=-rf (assignment AFTER the reference — still an accepted gap, real shells don't hoist)",
    cmd: "rm $FLAGS x; FLAGS=-rf",
    want: false,
  },
]);
