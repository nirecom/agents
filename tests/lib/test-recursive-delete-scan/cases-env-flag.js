"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/var-tracking.js  (lang-check: ignore)
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Env-prefix variable-flag bypass (round-2 C3, forward-only single-hop),
// documented non-goals that turned out to already be implemented (encoded
// -Command, cross-newline var correlation), and the exact-boundary
// out-of-scope pair. See ./harness.js for the shared runTable() runner.

const { runTable } = require("./harness");

runTable("env-flag", [
  { label: "FLAGS=-rf; rm $FLAGS x", cmd: "FLAGS=-rf; rm $FLAGS x", want: true },
  { label: 'FLAGS=-rf; rm "$FLAGS" x (double-quoted reference)', cmd: 'FLAGS=-rf; rm "$FLAGS" x', want: true },
  { label: "FLAGS=-rf; rm ${FLAGS} x (braced reference)", cmd: "FLAGS=-rf; rm ${FLAGS} x", want: true },
  { label: "FLAGS=-f; rm $FLAGS x (assigned flag is not recursive)", cmd: "FLAGS=-f; rm $FLAGS x", want: false },
  { label: "FLAGS=-rf; rm $OTHER x (variable name mismatch)", cmd: "FLAGS=-rf; rm $OTHER x", want: false },
  // Intentional residual gap pinned as spec (detail.md Risks & edge cases): the
  // assignment must precede the reference, mirroring real shell evaluation.
  { label: "rm $FLAGS x; FLAGS=-rf (assignment after the rm — accepted gap)", cmd: "rm $FLAGS x; FLAGS=-rf", want: false },
  // An inline env-prefix does not affect the same command's own expansion in a
  // real shell, so it is not a working bypass and must not be blocked.
  { label: "FLAGS=-rf rm $FLAGS x (inline env-prefix, same segment)", cmd: "FLAGS=-rf rm $FLAGS x", want: false },
  // Everyday variable target must stay approvable — the zero-false-positive line.
  { label: 'DIR=/tmp/x; rm "$DIR" (variable target, non-recursive)', cmd: 'DIR=/tmp/x; rm "$DIR"', want: false },
  // round-4 "0'": envRecursiveFlagVars removes a name when it is reassigned
  // to a non-recursive value, or when `unset NAME` appears — no longer an
  // accepted gap (reverts round-6's over-blocking regression).
  { label: "FLAGS=-rf; FLAGS=-f; rm $FLAGS x (reassigned to a safe value before use)", cmd: "FLAGS=-rf; FLAGS=-f; rm $FLAGS x", want: false },
  { label: "FLAGS=-rf; unset FLAGS; rm $FLAGS x (unset clears tracking, round-4)", cmd: "FLAGS=-rf; unset FLAGS; rm $FLAGS x", want: false },
  // #2210 N5: a `${VAR:-default}` parameter-expansion default is flag-shaped,
  // so it must classify the same as a literal `-rf` token.
  { label: "rm ${X:--rf} /tmp/x (param-expansion default is flag-shaped, N5)", cmd: "rm ${X:--rf} /tmp/x", want: true },
  { label: "rm ${X:=-rf} /tmp/x (round9 C11: := assign-default operand, PARAM_EXPANSION_RE)", cmd: "rm ${X:=-rf} /tmp/x", want: true },

  // round9 C8: split-variable reconstruction — substituteKnownVars's global
  // replace naturally reassembles `$A$B` into one flag string without any
  // special-casing (var-tracking.js's own comment, "#2210 round8 item 7").
  { label: "A=-; B=rf; rm $A$B x (split-variable concatenation reassembles to -rf)", cmd: "A=-; B=rf; rm $A$B x", want: true },
  { label: "A=-; B=f; rm $A$B x (split-variable concatenation reassembles to -f, safe)", cmd: "A=-; B=f; rm $A$B x", want: false },
  // round9 C8: `export NAME` with NO inline value re-exports an ALREADY
  // tracked assignment from an earlier statement — applyAssignmentCarryingCommand
  // only picks up argv tokens shaped like an assignment, so a bare `export
  // FLAGS` (no `=`) neither re-asserts nor drops the existing tracked value.
  { label: "FLAGS=-rf; export FLAGS; rm $FLAGS x (bare re-export of an already-tracked var)", cmd: "FLAGS=-rf; export FLAGS; rm $FLAGS x", want: true },
]);

// --- Out of scope (detail.md "Out of scope"): documented non-goals stay approved ---
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

// --- C1-style staleness fix: two "documented non-goal" rows above turned out
// to be already-implemented capabilities, discovered while verifying the
// suite after the round9 write-code pass (mirrors cases-posix.sh's xargs/
// eval/timeout staleness). Empirically confirmed against the live scan
// module before changing the assertions, per the same fail-closed-contract
// principle as C1.
runTable("encoded-command (round9: no longer a documented non-goal)", [
  // interpreter-specs.js's decodeEncodedCommand + pwshInterpreterBodies's
  // "encodedcommand".startsWith(name) branch decode the base64 UTF-16LE
  // payload and hand it back to the scan layer as a shell body — the old
  // SKIPPED/Because comment claiming this is "never decoded" (detail.md Out
  // of scope) contradicts the current implementation. Both directions are
  // pinned: a malicious decoded body blocks, a harmless one approves.
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
  // The newline-route recursive call now carries `envVarValues` forward as
  // `inheritedVars` (scan.js's own comment: "#2210 round8 item 7"), so an
  // assignment on an earlier line DOES reach a reference on a later one —
  // the old SKIPPED/Because comment (detail.md Step 4 step 4, "改行をまたいだ
  // 代入と参照の相関追跡は行わない") describes behavior this scan no longer has.
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
