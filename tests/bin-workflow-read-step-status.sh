#!/usr/bin/env bash
# tests/bin-workflow-read-step-status.sh
# Tests: bin/workflow/read-step-status
# Tags: workflow, state, cli, TL2, scope:common
#
# Why this CLI exists (#1378): when the run_tests hook demotes a step, the only
# way a skill could observe it was `next-step`, which also decides and advises.
# Reading a step's status through a decision engine means the reader cannot tell
# a fact from a recommendation. This bridge reports one fact and nothing else.
#
# Its SURFACE is the thing under test as much as its answer. Two sibling bridges
# already exist — bin/workflow/read-merge-base-baseline and
# bin/workflow/read-complexity-evaluation — and skills/run-tests/SKILL.md RNT-1
# already calls the flag form. A third bridge with positional args, or with a
# different absent marker, would put two conventions inside one skill (CPR-ORTH),
# so the argument form, the `NONE` marker, the validation regex and the exit
# codes are all pinned here against the siblings' behaviour.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The skill actually invoking this bridge and branching on its output.
#     Only a real /run-tests run shows that.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"
CLI="$AGENTS_DIR/bin/workflow/read-step-status"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin both dirs and
# drop the inherited live session ids before any child node runs.
TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rss-$$")"
mkdir -p "$TMPD/workflow-state" "$TMPD/workflow-plans"
trap 'rm -rf "$TMPD"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$(nodepath "$TMPD/workflow-plans")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# The CLI is the subject; its absence is a FAIL, never a skip.
if [ ! -f "$CLI" ]; then
    fail "0/cli-present" "implementation missing: bin/workflow/read-step-status"
fi

OUT=""
RC=0
# A missing CLI is reported as its own outcome rather than as node's own
# MODULE_NOT_FOUND exit 1. Otherwise every "must exit 1" assertion below would
# pass for the wrong reason while the subject does not exist at all.
ERR=""
cli() {
    RC=0
    if [ ! -f "$CLI" ]; then
        OUT="CLI_MISSING"; ERR="CLI_MISSING"; RC=127
        return
    fi
    OUT="$(run_with_timeout 30 node "$CLI" "$@" 2>"$TMPD/err")" || RC=$?
    ERR="$(cat "$TMPD/err")"
}
seed() {
    run_with_timeout 30 node -e '
require(process.argv[1] + "/hooks/workflow-state").markStep(process.argv[2], process.argv[3], process.argv[4]);
' "$AGENTS_WIN" "$1" "$2" "$3" >/dev/null 2>&1 || true
}

# ===========================================================================
# (a)/(b) — the recorded status is reported verbatim, one line, exit 0.
# Both a terminal and a non-terminal status are covered: a stub that always
# printed `complete` would satisfy (a) alone.
# ===========================================================================
SID_A="rss-a-$$-$RANDOM"
seed "$SID_A" run_tests complete
cli --session "$SID_A" --step run_tests
assert_eq "a/complete-value" "status=complete" "$OUT"
assert_eq "a/complete-exit" "0" "$RC"

SID_B="rss-b-$$-$RANDOM"
seed "$SID_B" run_tests pending
cli --session "$SID_B" --step run_tests
assert_eq "b/pending-value" "status=pending" "$OUT"
assert_eq "b/pending-exit" "0" "$RC"

# A step other than the one asked for must not bleed through.
SID_B2="rss-b2-$$-$RANDOM"
seed "$SID_B2" write_tests complete
seed "$SID_B2" run_tests pending
cli --session "$SID_B2" --step write_tests
assert_eq "b/step-argument-selects-the-step" "status=complete" "$OUT"

# ===========================================================================
# (c) — absent is `NONE` at exit 0, matching the sibling bridges' marker.
#
# Three distinct absences, kept apart on purpose (CPR-SC): no state file at all,
# a state file for a session that was never seen, and a real session whose step
# has no record. All three mean "nothing recorded", and a caller that had to
# distinguish them would be reading an implementation detail.
# ===========================================================================
cli --session "rss-nofile-$$-$RANDOM" --step run_tests
assert_eq "c/no-state-file-value" "NONE" "$OUT"
assert_eq "c/no-state-file-exit" "0" "$RC"

SID_C="rss-c-$$-$RANDOM"
seed "$SID_C" write_tests complete
cli --session "$SID_C" --step run_tests
assert_eq "c/step-never-recorded-value" "NONE" "$OUT"
assert_eq "c/step-never-recorded-exit" "0" "$RC"

# A corrupt state file is an absence too — never a crash and never a stack trace,
# which would put host paths into a transcript.
SID_CORRUPT="rss-corrupt-$$-$RANDOM"
printf 'not json at all' > "$TMPD/workflow-state/$SID_CORRUPT.json"
cli --session "$SID_CORRUPT" --step run_tests
assert_eq "c/corrupt-state-file-value" "NONE" "$OUT"
assert_eq "c/corrupt-state-file-exit" "0" "$RC"

# The sibling bridges' marker is the reference — pinned by reading THEIR source,
# so a future rename of the marker fails here instead of drifting silently.
if grep -q '"NONE\\n"' "$AGENTS_DIR/bin/workflow/read-merge-base-baseline"; then
    pass "c/absent-marker-matches-the-sibling-bridges"
else
    fail "c/absent-marker-matches-the-sibling-bridges" \
         "read-merge-base-baseline no longer writes NONE — reconcile the convention"
fi

# ===========================================================================
# (d) — argument validation. All four rejections exit 1 and say so on stderr;
# printing NONE for a malformed request would make a caller's typo look like a
# legitimate "nothing recorded".
# ===========================================================================
cli --step run_tests
assert_eq "d/missing-session-exit" "1" "$RC"
assert_eq "d/missing-session-stdout-empty" "" "$OUT"

SID_D="rss-d-$$-$RANDOM"
seed "$SID_D" run_tests complete
cli --session "$SID_D"
assert_eq "d/missing-step-exit" "1" "$RC"

cli --session "bad/../id" --step run_tests
assert_eq "d/session-id-regex-exit" "1" "$RC"
assert_eq "d/session-id-regex-stdout-empty" "" "$OUT"

cli --session "$SID_D" --step run_tests --verbose
assert_eq "d/unknown-argument-exit" "1" "$RC"

cli --session "$SID_D" --step not_a_real_step
assert_eq "d/unknown-step-exit" "1" "$RC"

# Every rejection must be diagnosable, not silent.
cli --session "bad/../id" --step run_tests
case "${ERR:-}" in
    *read-step-status*) pass "d/errors-name-the-tool-on-stderr" ;;
    *) fail "d/errors-name-the-tool-on-stderr" "stderr=$ERR" ;;
esac

# ===========================================================================
# (e) — read-only. A reader that mutates state is worse than no reader: the
# run_tests status it reports would be one it helped create.
# ===========================================================================
SID_E="rss-e-$$-$RANDOM"
seed "$SID_E" run_tests complete
E_FILE="$TMPD/workflow-state/$SID_E.json"
if [ -f "$E_FILE" ]; then
    BEFORE="$(cksum < "$E_FILE")"
    cli --session "$SID_E" --step run_tests
    cli --session "$SID_E" --step review_tests
    cli --session "rss-e-absent-$$-$RANDOM" --step run_tests
    AFTER="$(cksum < "$E_FILE")"
    assert_eq "e/state-file-byte-identical-after-reads" "$BEFORE" "$AFTER"
    # The absent-session read must not have created a file either.
    assert_eq "e/absent-read-creates-no-file" "1" "$(ls "$TMPD/workflow-state" | grep -c "^$SID_E.json$" | tr -d ' ')"
else
    fail "e/state-file-byte-identical-after-reads" "seed produced no state file at $E_FILE"
fi

# ===========================================================================
# (f) — the output is a fact, not advice. `next-step` vocabulary appearing here
# would mean the bridge started deciding as well as reporting.
# ===========================================================================
cli --session "$SID_A" --step run_tests
case "$OUT" in
    *ACTION*|*NEXT_SKILL*|*NEXT_HINT*)
        fail "f/no-decision-vocabulary-in-output" "$OUT" ;;
    *) pass "f/no-decision-vocabulary-in-output" ;;
esac
assert_eq "f/output-is-exactly-one-line" "1" "$(printf '%s\n' "$OUT" | grep -c '' | tr -d ' ')"
# …and that one line is the contracted shape, so the line count above cannot be
# satisfied by an empty string.
case "$OUT" in
    status=*) pass "f/output-is-the-contracted-key-value-shape" ;;
    *) fail "f/output-is-the-contracted-key-value-shape" "got=$OUT" ;;
esac

# ===========================================================================
# (g) — the barrel is the seam. Reaching into hooks/workflow-state/state-io/
# directly would couple a shell bridge to the store's internal file layout, and
# the two sibling bridges both go through the barrel.
# ===========================================================================
if [ -f "$CLI" ]; then
    if grep -qE 'require\(.*state-io' "$CLI"; then
        fail "g/requires-through-the-barrel" "direct state-io/ require found in $CLI"
    elif grep -q 'workflow-state' "$CLI"; then
        pass "g/requires-through-the-barrel"
    else
        fail "g/requires-through-the-barrel" "no workflow-state require found in $CLI"
    fi
else
    fail "g/requires-through-the-barrel" "implementation missing"
fi

# The bridge must be executable from a shell — a mode-644 file makes every
# caller's invocation fail on POSIX regardless of correct logic.
if [ -f "$CLI" ]; then
    MODE="$(git -C "$AGENTS_DIR" ls-files -s -- bin/workflow/read-step-status | awk '{print $1}')"
    case "${MODE:-}" in
        100755) pass "g/execute-bit-recorded-in-the-index" ;;
        "") fail "g/execute-bit-recorded-in-the-index" "file is not tracked yet" ;;
        *) fail "g/execute-bit-recorded-in-the-index" "index mode=$MODE, want 100755" ;;
    esac
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
