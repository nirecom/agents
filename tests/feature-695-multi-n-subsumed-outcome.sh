#!/usr/bin/env bash
# tests/feature-695-multi-n-subsumed-outcome.sh
# Tests: bin/issue-close-write-outcome.js, hooks/lib/parse-closes-issues.js
# Tags: scope:issue-specific
# Tests for issue #695 — a session that subsumes multiple issues (closes_issues
# with N1 + N2) must record an outcome entry for EVERY N, not just the primary.
#
# Before #695: a single `--from-session` finalize records only the issue it was
# handed; subsumed siblings from intent.md's `## Issues` block are never written
# to the outcome JSON. This suite is RED: after processing the primary issue,
# the second subsumed N is missing from the outcome bag.
#
# L3 gap (what this test does NOT catch):
# - real GitHub API calls and actual issue state transitions
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITE_OUTCOME="$AGENTS_DIR/bin/issue-close-write-outcome.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$WRITE_OUTCOME" ]; then
    echo "FAIL: precondition missing — bin/issue-close-write-outcome.js"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

setup_tmp() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    # WORKFLOW_PLANS_DIR must point at TMP so write-outcome.js resolves
    # "testsid-intent.md" when looking up subsumed issues in the session.
    export WORKFLOW_PLANS_DIR="$TMP"
    INTENT="$TMP/testsid-intent.md"
    cat > "$INTENT" <<'EOF'
# Intent

## Issues
- #701
- #702
EOF
    OUTCOME="$TMP/session-issue-close-outcome.json"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
    unset WORKFLOW_PLANS_DIR
}

# ============================================================================
# T1: processing the primary issue records BOTH subsumed N values (#695)
# ============================================================================
# Simulate the finalize step for the PRIMARY issue #701 only. Per #695, the
# outcome bag must end up with entries for BOTH #701 and #702 (the subsumed
# sibling declared in intent.md `## Issues`). Today only #701 is written, so
# this assertion is RED.
setup_tmp
# Write the primary issue outcome the way run-finalize would.
run_with_timeout 15 node "$WRITE_OUTCOME" \
    --session-id testsid --out-file "$OUTCOME" \
    701 finalized appended closed posted cleared >/dev/null 2>&1

HAVE_701=0; HAVE_702=0
grep -q '"issueNumber": 701' "$OUTCOME" 2>/dev/null && HAVE_701=1
grep -q '"issueNumber": 702' "$OUTCOME" 2>/dev/null && HAVE_702=1

if [ "$HAVE_701" -eq 1 ] && [ "$HAVE_702" -eq 1 ]; then
    pass "T1: both subsumed N (701, 702) recorded in outcome JSON (#695)"
else
    fail "T1: outcome missing subsumed N — have701=$HAVE_701 have702=$HAVE_702 (expected both)"
fi
teardown_tmp

# ============================================================================
# T2: --fallback baseline — parser DOES enumerate both N from ## Issues
# ============================================================================
# Guards against a parser regression: the multi-N enumeration primitive exists
# and both N appear when the fallback path explicitly iterates intent.md.
setup_tmp
run_with_timeout 15 node "$WRITE_OUTCOME" --fallback "$INTENT" "$OUTCOME" >/dev/null 2>&1
if grep -q '"issueNumber": 701' "$OUTCOME" 2>/dev/null \
    && grep -q '"issueNumber": 702' "$OUTCOME" 2>/dev/null; then
    pass "T2: parser enumerates both N (701, 702) via --fallback"
else
    fail "T2: --fallback did not enumerate both N (parser primitive broken)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
