# shellcheck shell=bash
# tests/lib/xfail.sh — expected-failure (xfail) assertions pinned to a source bug.
# Tests: tests/lib/xfail.sh
# Tags: test-infrastructure, xfail, known-gap, shared-lib, scope:common

# A test that finds a source defect asserts the CORRECT behaviour and marks the gap, instead of
# blessing the bug or deleting the case: unmet -> XFAIL (counted in XFAIL_N, not a failure);
# met -> XPASS, a FAILURE (counted in FAIL and XPASS_N) so the stale pin gets converted to assert_*.
# Pinned issue: nirecom/agents#2032 by default; override XFAIL_ISSUE before sourcing.
# Usage (the sourcing suite owns PASS / FAIL):
#   . "$AGENTS_ROOT/tests/lib/xfail.sh"; xfail_eq "<name>" "<want-correct>" "$got"; xfail_summary

XFAIL_ISSUE="${XFAIL_ISSUE:-#2032}"
XFAIL_N=0
XPASS_N=0

# _xfail_note <name> — the expectation is still unmet: the known gap is intact.
_xfail_note() {
    echo "XFAIL ($XFAIL_ISSUE, known source gap — asserting the correct behaviour): $1"
    XFAIL_N=$((XFAIL_N + 1))
}

# _xpass_fail <name> — the expectation is now met. The gap is closed, so the
# pin is stale and the case must be rewritten as a plain assertion.
_xpass_fail() {
    echo "FAIL: $1 — XPASS: the $XFAIL_ISSUE gap appears CLOSED. Convert this case to a plain assert_* and drop the xfail pin."
    FAIL=$((FAIL + 1))
    XPASS_N=$((XPASS_N + 1))
    # tests/lib/harness.sh, when sourced: the open case's immediate FAIL record.
    if declare -F _harness_case_failed >/dev/null; then _harness_case_failed; fi
}

# xfail_eq <name> <want-correct> <got>
xfail_eq() {
    if [ "$2" = "$3" ]; then
        _xpass_fail "$1"
    else
        _xfail_note "$1 — want=$(printf '%q' "$2") got=$(printf '%q' "$3")"
    fi
}

# xfail_contains <name> <needle-that-should-be-there> <haystack>
xfail_contains() {
    if printf '%s' "$3" | grep -Fq -- "$2"; then
        _xpass_fail "$1"
    else
        _xfail_note "$1 — expected output to contain $(printf '%q' "$2")"
    fi
}

# xfail_not_contains <name> <needle-that-should-be-absent> <haystack>
xfail_not_contains() {
    if printf '%s' "$3" | grep -Fq -- "$2"; then
        _xfail_note "$1 — output still contains $(printf '%q' "$2")"
    else
        _xpass_fail "$1"
    fi
}

# xfail_summary — one line naming how many known gaps are still open, so a gap
# can never be silently invisible in a green run.
xfail_summary() {
    if [ "$XFAIL_N" -gt 0 ]; then
        echo ""
        echo "=== Known gaps: $XFAIL_N xfail (pinned to $XFAIL_ISSUE — asserted as the correct behaviour, not yet implemented) ==="
    fi
}
