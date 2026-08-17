# tests/lib/xfail.sh — expected-failure (xfail) assertions pinned to a source bug.
# Tests: tests/lib/xfail.sh
# Tags: test-infrastructure, xfail, known-gap, shared-lib, scope:common

# Why this file exists. A test suite written alongside a change sometimes finds
# a defect in the source it was written against. There are only three things a
# test can then do, and two of them are wrong: assert the buggy behaviour (which
# blesses it as the contract and makes the eventual fix look like a regression),
# or delete the case (which loses the finding entirely). The third is to assert
# the CORRECT behaviour and mark the case as a known gap.

# So every xfail_* assertion below takes the expectation the source SHOULD
# satisfy, and reports:
#   - expectation not met -> XFAIL. Reported, counted in XFAIL_N, not a failure.
#   - expectation met     -> XPASS, counted as a FAILURE, because the gap is
#                            closed and the case must be converted to a plain
#                            assert_* and unpinned from its issue.
# The XPASS-is-a-failure half is what keeps this honest: without it an xfail is
# just a permanently silenced test.

# Pinned issue: nirecom/agents#2032 — the source defects in the concern-ledger
# stack that #1992 deliberately does NOT fix (it is a test-only PR). Override
# XFAIL_ISSUE before sourcing to pin to another issue.

# Usage (the sourcing suite owns PASS / FAIL and its own pass() helper):
#   . "$AGENTS_ROOT/tests/lib/xfail.sh"
#   xfail_eq "3: a '..' session id is rejected before any write" "rejected" "$got"
#   xfail_summary          # prints the known-gap line, before the Results line

XFAIL_ISSUE="${XFAIL_ISSUE:-#2032}"
XFAIL_N=0

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
