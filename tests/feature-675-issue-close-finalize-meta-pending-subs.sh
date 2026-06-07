#!/bin/bash
# Tests: bin/github-issues/issue-close-finalize-triage.sh, skills/issue-close-finalize/SKILL.md
# Tags: issue-close, finalize, triage, meta, cascade, wip
# Tests for issue #675 — meta_pending_subs graceful exit.
#
# When a meta parent has open sub-issues, /issue-close-finalize must exit 0
# with ACTION=meta_pending_subs and empty NEXT_STEPS so the caller can return
# cleanly. A child close cascade will re-attempt the parent close once the
# last sub-issue closes; surfacing an error here just spammed the user with
# false alarms (#675-B).
#
# RED before /write-code runs — triage source still returns the old
# `exit 1 + /issue-close-stage` error path for meta_child_open.

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

# Helper: run finalize triage; capture STATE/SENTINEL/ACTION/NEXT_STEPS.
run_triage() {
    local scenario="$1"
    unset STATE SENTINEL ACTION NEXT_STEPS
    local out
    if out=$(cd "$TMP" && GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/dev/null); then
        T_RC=0
    else
        T_RC=$?
    fi
    # shellcheck disable=SC1090
    eval "$out" 2>/dev/null
    T_STATE="${STATE:-}"
    T_SENTINEL="${SENTINEL:-}"
    T_ACTION="${ACTION:-}"
    T_NEXT_STEPS="${NEXT_STEPS:-}"
}

# ============================================================================
# T1: meta parent with 1 open child → exit 0 + meta_pending_subs + empty NEXT_STEPS
# ============================================================================
# Triage must NOT error out; it must emit ACTION=meta_pending_subs with
# NEXT_STEPS="" so the caller can return cleanly. A warning on stderr is
# expected so the user knows why the close was deferred.
setup_tmp
T1_OUT=$(cd "$TMP" && GH_MOCK_SCENARIO=meta_child_open run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/t1_err.$$)
T1_RC=$?
unset STATE SENTINEL ACTION NEXT_STEPS
# shellcheck disable=SC1090
eval "$T1_OUT" 2>/dev/null
T1_ERR=$(cat /tmp/t1_err.$$); rm -f /tmp/t1_err.$$
if [ "$T1_RC" -eq 0 ] \
    && [ "${ACTION:-}" = "meta_pending_subs" ] \
    && [ -z "${NEXT_STEPS:-}" ] \
    && echo "$T1_ERR" | grep -qi "meta parent with open sub-issues"; then
    pass "T1: meta_child_open → exit 0 + ACTION=meta_pending_subs + empty NEXT_STEPS + stderr warns"
else
    fail "T1: rc=$T1_RC action=${ACTION:-} next='${NEXT_STEPS:-}' stderr=$T1_ERR"
fi
teardown_tmp

# ============================================================================
# T2: meta repo lookup fails → still exit non-zero (API errors still surface)
# ============================================================================
# meta_pending_subs is reserved for the case where the gate ran successfully
# and found open sub-issues. If the gate cannot run (repo lookup fails),
# triage must NOT silently route to meta_pending_subs — it must error so the
# user can investigate.
setup_tmp
T2_OUT=$(cd "$TMP" && GH_MOCK_SCENARIO=meta_no_repo run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/tmp/t2_err.$$)
T2_RC=$?
T2_ERR=$(cat /tmp/t2_err.$$); rm -f /tmp/t2_err.$$
unset STATE SENTINEL ACTION NEXT_STEPS
# shellcheck disable=SC1090
eval "$T2_OUT" 2>/dev/null
if [ "$T2_RC" -ne 0 ] && [ "${ACTION:-}" != "meta_pending_subs" ]; then
    pass "T2: meta_no_repo (gate cannot run) → exit non-zero, NOT meta_pending_subs"
else
    fail "T2: rc=$T2_RC action=${ACTION:-} (expected non-zero exit + ACTION != meta_pending_subs)"
fi
teardown_tmp

# ============================================================================
# T3: meta parent with all sub-issues closed → admin_close_path (regression)
# ============================================================================
# meta_pending_subs must only apply when SUB_RC=1 (open child). When all
# sub-issues are closed (SUB_RC=0) or zero children (SUB_RC=2), triage must
# still route to admin_close_path.
setup_tmp
run_triage meta_admin_close_path
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "admin_close_path" ] && [ "$T_NEXT_STEPS" = "G,H,J,K" ]; then
    pass "T3 (regression): meta + all subs closed → admin_close_path (G,H,J,K)"
else
    fail "T3: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
