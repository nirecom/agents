#!/usr/bin/env bash
# tests/feature-417-issue-close-finalize-suppress-open-subs.sh
# Tests: bin/github-issues/issue-close-finalize-triage.sh, skills/issue-close-finalize/scripts/run-initial.sh
# Tags: scope:issue-specific
# Tests for issue #417 — /issue-close-finalize must skip (not error) an issue
# that still has OPEN sub-issues, recording a `skipped_open_sub_issues` outcome.
#
# Before #417: OPEN + open sub-issues either errors (OPEN:none) or is not
# routed to a graceful skip. This suite is RED against the current source: the
# `skipped_open_sub_issues` ACTION/state does not exist yet.
#
# L3 gap (what this test does NOT catch):
# - real GitHub API calls and actual issue state transitions
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-triage-lib.sh"
FINALIZE_TRIAGE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-finalize-triage.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

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
missing=()
[ -f "$LIB_SCRIPT" ]              || missing+=("bin/github-issues/issue-close-triage-lib.sh")
[ -f "$FINALIZE_TRIAGE_SCRIPT" ]  || missing+=("bin/github-issues/issue-close-finalize-triage.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/docs/history"
    : > "$TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
    unset GH_MOCK_COMMENT_LOG
}

run_triage() {
    local scenario="$1"
    local issue_n="${2:-42}"
    unset STATE SENTINEL ACTION NEXT_STEPS
    local out
    if out=$(cd "$TMP" && GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" "$issue_n" 2>/tmp/f417_err.$$); then
        T_RC=0
    else
        T_RC=$?
    fi
    T_ERR=$(cat /tmp/f417_err.$$ 2>/dev/null); rm -f /tmp/f417_err.$$
    # shellcheck disable=SC1090
    eval "$out" 2>/dev/null
    T_ACTION="${ACTION:-}"
    T_NEXT_STEPS="${NEXT_STEPS:-}"
}

# ============================================================================
# T1: OPEN issue with open sub-issues → graceful skip (skipped_open_sub_issues)
# ============================================================================
# Before #417: `one_open_subissue` on a non-meta OPEN issue is not routed to a
# dedicated skip action; triage errors or falls through. After #417, triage
# must exit 0 with ACTION=skipped_open_sub_issues and empty NEXT_STEPS, plus a
# stderr warning naming the open sub-issue condition.
setup_tmp
run_triage one_open_subissue 10
if [ "$T_RC" -eq 0 ] \
    && [ "$T_ACTION" = "skipped_open_sub_issues" ] \
    && [ -z "$T_NEXT_STEPS" ] \
    && echo "$T_ERR" | grep -qi "open sub-issue"; then
    pass "T1: OPEN + open sub-issues → skipped_open_sub_issues + warning (#417)"
else
    fail "T1: rc=$T_RC action=$T_ACTION next='$T_NEXT_STEPS' stderr='$T_ERR'"
fi
teardown_tmp

# ============================================================================
# T2: outcome JSON records skipped_open_sub_issues for the skipped issue
# ============================================================================
# The write-outcome helper must accept and persist a skipped_open_sub_issues
# state. Uses the --session-id / --out-file form so the test is deterministic.
setup_tmp
OUTCOME="$TMP/session-issue-close-outcome.json"
run_with_timeout 15 node "$AGENTS_DIR/bin/issue-close-write-outcome.js" \
    --session-id testsid --out-file "$OUTCOME" \
    42 skipped_open_sub_issues skipped skipped skipped skipped >/dev/null 2>&1
if [ -f "$OUTCOME" ] && grep -q '"skipped_open_sub_issues"' "$OUTCOME"; then
    # The state value round-trips; #417 requires the triage/worker to emit it.
    # This half PASSES today (writer is generic) — the RED half is T1.
    pass "T2: outcome JSON persists skipped_open_sub_issues state"
else
    fail "T2: outcome JSON missing skipped_open_sub_issues entry (file=$OUTCOME)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
