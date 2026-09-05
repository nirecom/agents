#!/usr/bin/env bash
# Tests: hooks/block-capture-echo.js, hooks/lib/tool-command-text.js
# Tags: capture-echo-guard, pretooluse, hook-registration, subprocess, scope:issue-specific, pwsh-not-required
# Section B — process boundary (TL2): spawn the entrypoint as a real subprocess and
# feed it a PreToolUse event on stdin. Verdict tokens come from hook-out.js so the
# assertion is on the block/pass-through contract, not on wording.
# CPR-ORTH: the same true positive is exercised for all three command tools.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$AGENTS_DIR/hooks/block-capture-echo.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

TMPDIR_B="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_B"' EXIT
EV="$TMPDIR_B/event.json"
OUT="$TMPDIR_B/out.json"

# Fixture isolation (rules/test/fixture-isolation.md): a hook spawned from here must
# never resolve the live session or the developer's real plans dir.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPDIR_B/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_B/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

# Sets globals VERDICT and LAST_RC. Deliberately NOT called via $(...) — a command
# substitution subshell would discard the exit code this section asserts on.
LAST_RC=0
VERDICT=""
run_hook() {
    LAST_RC=0
    node "$HOOK" <"$EV" >"$OUT" 2>"$TMPDIR_B/err.txt" || LAST_RC=$?
    VERDICT="$(node "$HERE/hook-out.js" "$OUT")"
}

if [ ! -f "$HOOK" ]; then
    # Pre-implementation signature: report HOOK_MISSING once per planned case rather
    # than emitting node's stack trace, so the expected failure mode stays legible.
    for c in B-1-bash-block B-2-runinterminal-block B-3-runcommands-elem0-block \
             B-4-runcommands-split-passthrough B-5-read-tool-passthrough \
             B-6-malformed-json-passthrough B-7-true-negative-passthrough \
             B-8-exit-code-zero; do
        assert_eq "$c" "present" "HOOK_MISSING"
    done
    echo ""
    echo "Section B: PASS=$PASS FAIL=$FAIL"
    exit "$FAIL"
fi

TP='PLANS_DIR=$(bash bin/workflow-plans-dir); echo "$PLANS_DIR"'

node "$HERE/mk-event.js" Bash "$TP" >"$EV"
run_hook
assert_eq "B-1-bash-block" "block" "$VERDICT"
assert_eq "B-8-exit-code-zero" "0" "$LAST_RC"

node "$HERE/mk-event.js" runInTerminal "$TP" >"$EV"
run_hook
assert_eq "B-2-runinterminal-block" "block" "$VERDICT"

# BD-6 at the process layer: element 0 alone is a full capture-echo unit.
node "$HERE/mk-event.js" runCommands 'X=$(a); echo "$X"' 'ls' >"$EV"
run_hook
assert_eq "B-3-runcommands-elem0-block" "block" "$VERDICT"

# BD-5 at the process layer: two SEPARATE shell executions must never be joined
# into one assignment->echo unit (the newline-join bug this hook must not have).
node "$HERE/mk-event.js" runCommands 'X=$(a)' 'echo "$X"' >"$EV"
run_hook
assert_eq "B-4-runcommands-split-passthrough" "passthrough" "$VERDICT"

node "$HERE/mk-event.js" Read "$TP" >"$EV"
run_hook
assert_eq "B-5-read-tool-passthrough" "passthrough" "$VERDICT"

printf '%s' 'not json at all {{{' >"$EV"
run_hook
assert_eq "B-6-malformed-json-passthrough" "passthrough" "$VERDICT"
assert_eq "B-6b-malformed-exit-zero" "0" "$LAST_RC"

node "$HERE/mk-event.js" Bash 'PLANS_DIR=$(bash bin/workflow-plans-dir); cat "$PLANS_DIR/a.md"; echo "$PLANS_DIR"' >"$EV"
run_hook
assert_eq "B-7-true-negative-passthrough" "passthrough" "$VERDICT"

# Classifier both-direction (Pattern 4): an ordinary sanctioned command is untouched.
node "$HERE/mk-event.js" Bash 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"' >"$EV"
run_hook
assert_eq "B-9-bare-command-passthrough" "passthrough" "$VERDICT"

# C6: runCommands is an ARRAY, so the guard must scan every element — not just [0].
# A hit parked at index 2 behind two innocuous elements is the realistic evasion.
node "$HERE/mk-event.js" runCommands 'ls' 'pwd' 'X=$(a); echo "$X"' >"$EV"
run_hook
assert_eq "B-10-runcommands-elem2-block" "block" "$VERDICT"
assert_eq "B-10b-elem2-exit-zero" "0" "$LAST_RC"

# Both-direction: an all-clean array must not be blocked by the same loop.
node "$HERE/mk-event.js" runCommands 'ls' 'pwd' 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"' >"$EV"
run_hook
assert_eq "B-11-runcommands-all-clean-passthrough" "passthrough" "$VERDICT"

# C6: runInTerminal carries the hit under the same .command key as Bash.
node "$HERE/mk-event.js" runInTerminal 'X=$(a); Y=$(b); printf '"'"'%s %s\n'"'"' "$X" "$Y"' >"$EV"
run_hook
assert_eq "B-12-runinterminal-multi-assign-block" "block" "$VERDICT"

# --- C8: the denial must not echo the captured command's secrets back ---------
# The blocked command carries a token-shaped literal. The hook prints its remedy to
# stdout and its diagnostics to stderr; a naive "here is what you ran" remedy would
# copy the whole invocation into the transcript, turning a guard into a leak.
# Attack scenario (protection-fix-tests.md Pattern 2): the secret must appear in no
# output channel, in BOTH the normal path and the AGENTS_CONFIG_DIR-absent
# degradation path, and the command must still be blocked in both.
SECRET='ghp_TESTFIXTUREAAAABBBBCCCCDDDDEEEE1234'
node "$HERE/mk-event.js" Bash "TOK=\$(printf '%s' $SECRET); echo \"\$TOK\"" >"$EV"

assert_no_secret() {
    local name="$1" out="$2" err="$3"
    local hits=0
    grep -qF "$SECRET" "$out" && hits=$((hits + 1))
    grep -qF "$SECRET" "$err" && hits=$((hits + 1))
    assert_eq "$name" "0" "$hits"
}

node "$HOOK" <"$EV" >"$OUT" 2>"$TMPDIR_B/err.txt"
VERDICT="$(node "$HERE/hook-out.js" "$OUT")"
assert_eq "B-13-secret-command-still-blocked" "block" "$VERDICT"
assert_no_secret "B-14-secret-absent-from-hook-output" "$OUT" "$TMPDIR_B/err.txt"

# Degradation path: with no AGENTS_CONFIG_DIR the remedy cannot consult the allow
# list, so it falls back to generic guidance — which must also stay secret-free.
env -u AGENTS_CONFIG_DIR node "$HOOK" <"$EV" >"$OUT" 2>"$TMPDIR_B/err.txt"
VERDICT="$(node "$HERE/hook-out.js" "$OUT")"
assert_eq "B-15-secret-blocked-without-config-dir" "block" "$VERDICT"
assert_no_secret "B-16-secret-absent-in-degraded-remedy" "$OUT" "$TMPDIR_B/err.txt"

# --- B-17..B-21: the MATCHED path, and what it refuses to reproduce ------------
# B-13..B-16 cover the unmatched/degraded remedy, which never quotes the command.
# The matched path renders the blocked invocation's arguments so the author can
# reissue it bare — but ONLY arguments that do not look secret-bearing. Round 11
# replaced the earlier "SAFE_ARG_RE spelling gate is enough" tradeoff: a
# secret-shaped argument now routes the whole invocation to branch B, which names
# no argument at all, so the guard can no longer copy a token into the transcript.
# Scope: stdout guidance only. stderr is diagnostics, never the command, and the
# verdict must stay "block" — a leak concern must not soften it.
CFGTOK='--token=supersecret123unique'
node "$HERE/mk-event.js" Bash \
    "X=\$(bash \"\$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip\" $CFGTOK); echo \"\$X\"" >"$EV"
env AGENTS_CONFIG_DIR="$AGENTS_DIR" node "$HOOK" <"$EV" >"$OUT" 2>"$TMPDIR_B/err.txt"
VERDICT="$(node "$HERE/hook-out.js" "$OUT")"
assert_eq "B-17-matched-secret-arg-still-blocked" "block" "$VERDICT"
grep -qF -e "$CFGTOK" "$OUT" && TOK_IN_OUT=yes || TOK_IN_OUT=no
assert_eq "B-18-matched-secret-arg-not-reproduced" "no" "$TOK_IN_OUT"
# Both-direction control (CPR-ORTH / protection-fix Pattern 4): the SAME matched
# entry point with an ordinary, non-secret-shaped argument still gets the verbatim
# recipe. Without this row, B-18 would also pass if branchA stopped rendering
# arguments altogether — or if the entry simply stopped matching.
CFGARG='--target outline'
node "$HERE/mk-event.js" Bash \
    "X=\$(bash \"\$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip\" $CFGARG); echo \"\$X\"" >"$EV"
env AGENTS_CONFIG_DIR="$AGENTS_DIR" node "$HOOK" <"$EV" >"$OUT" 2>"$TMPDIR_B/err2.txt"
VERDICT="$(node "$HERE/hook-out.js" "$OUT")"
assert_eq "B-18b-matched-plain-arg-still-blocked" "block" "$VERDICT"
grep -qF -e "$CFGARG" "$OUT" && ARG_IN_OUT=yes || ARG_IN_OUT=no
assert_eq "B-18c-matched-plain-arg-reproduced" "yes" "$ARG_IN_OUT"
grep -qF -e "$CFGTOK" "$TMPDIR_B/err.txt" && TOK_IN_ERR=yes || TOK_IN_ERR=no
assert_eq "B-19-stderr-never-carries-the-command" "no" "$TOK_IN_ERR"
# Contrast row: the very same argument on an UNMATCHED entry point degrades to generic
# guidance, so verbatim reproduction is scoped to a recipe the SSOT already sanctions.
node "$HERE/mk-event.js" Bash \
    "X=\$(bash /tmp/not-registered $CFGTOK); echo \"\$X\"" >"$EV"
env AGENTS_CONFIG_DIR="$AGENTS_DIR" node "$HOOK" <"$EV" >"$OUT" 2>"$TMPDIR_B/err.txt"
grep -qF -e "$CFGTOK" "$OUT" && TOK_IN_OUT=yes || TOK_IN_OUT=no
assert_eq "B-20-unmatched-entry-does-not-reproduce-arg" "no" "$TOK_IN_OUT"

echo ""
echo "Section B: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
