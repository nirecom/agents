#!/bin/bash
# Tests for issue #325 — /issue-close-stage skill triage script.
#
# Phase 1 (`/issue-close-stage`) runs inside the linked worktree BEFORE PR merge.
# After issue #325 centralized history.md writes into Phase 2, Phase 1 steps
# are B,D,F,G (Step E — doc-append — has been moved to Phase 2 entirely).
#
# Routing scenarios for issue-close-stage-triage.sh:
#   ST1: OPEN + no sentinel        → proceed, B,D,F,G
#   ST2: OPEN + pending            → resume_f, F,G
#   ST4: OPEN + appended           → resume_g, G
#   ST5: CLOSED:*                  → error (mentions /issue-close-finalize)
#   ST6: non-numeric N             → error (injection guard)
#   ST7: AGENTS_CONFIG_DIR unset   → error
#
# Note: pre-#325 ST3 (`phase1_done` short-circuit when history.md already
# contained an entry for #N) was removed — Phase 1 no longer touches
# history.md, so the only signal that determines Phase 1 completion is
# the sentinel state. ST2's branching on history presence collapses into
# a single `resume_f` case.
#
# RED: this suite fails clean while the script + shared lib are missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-triage-lib.sh"
STAGE_TRIAGE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-stage-triage.sh"
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

# --- Existence gate (RED until both files land) -----------------------------
missing=()
[ -f "$LIB_SCRIPT" ]          || missing+=("bin/github-issues/issue-close-triage-lib.sh")
[ -f "$STAGE_TRIAGE_SCRIPT" ] || missing+=("bin/github-issues/issue-close-stage-triage.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# Ensure mock helpers are executable (Windows checkouts may strip the bit).
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

# Helper: run stage triage for a scenario; capture STATE/SENTINEL/ACTION/NEXT_STEPS.
# CRITICAL: cd into $TMP because the triage script reads docs/history.md
# relative to CWD when needed.
run_stage_triage() {
    local scenario="$1"
    unset STATE SENTINEL ACTION NEXT_STEPS
    local out
    if out=$(cd "$TMP" && GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$STAGE_TRIAGE_SCRIPT" 42 2>/dev/null); then
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
# ST-series — stage triage routing
# ============================================================================

# --- ST1: OPEN + no sentinel → proceed (B,D,F,G)
setup_tmp
run_stage_triage issue_task
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "proceed" ] && [ "$T_NEXT_STEPS" = "B,D,F,G" ]; then
    pass "ST1: OPEN + no sentinel → proceed (B,D,F,G)"
else
    fail "ST1: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- ST2: OPEN + pending → resume_f (F,G)
# After #325, Phase 1 doesn't touch history.md, so pending always resumes at F
# regardless of history.md content.
setup_tmp
run_stage_triage open_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_f" ] && [ "$T_NEXT_STEPS" = "F,G" ]; then
    pass "ST2: OPEN + pending → resume_f (F,G)"
else
    fail "ST2: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- ST4: OPEN + appended → resume_g (G)
setup_tmp
run_stage_triage open_with_appended
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_g" ] && [ "$T_NEXT_STEPS" = "G" ]; then
    pass "ST4: OPEN + appended → resume_g (G)"
else
    fail "ST4: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- ST5: CLOSED:* → non-zero + stderr mentions /issue-close-finalize
setup_tmp
ERR_OUT=$(cd "$TMP" && GH_MOCK_SCENARIO=closed_no_sentinel run_with_timeout 15 bash "$STAGE_TRIAGE_SCRIPT" 42 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$ERR_OUT" | grep -qi "issue-close-finalize"; then
    pass "ST5: CLOSED state → non-zero exit + stderr mentions issue-close-finalize"
else
    fail "ST5: rc=$RC stderr=$ERR_OUT"
fi
teardown_tmp

# --- ST6: non-numeric N → non-zero, no shell injection
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$STAGE_TRIAGE_SCRIPT" "42; touch /tmp/ST6_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/ST6_INJECT ]; then
    pass "ST6: non-numeric N rejected, no shell injection"
else
    fail "ST6: rc=$RC inject=$([ -f /tmp/ST6_INJECT ] && echo yes || echo no)"
    rm -f /tmp/ST6_INJECT 2>/dev/null
fi
teardown_tmp

# --- ST7: AGENTS_CONFIG_DIR unset → non-zero
setup_tmp
unset AGENTS_CONFIG_DIR
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$STAGE_TRIAGE_SCRIPT" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "ST7: AGENTS_CONFIG_DIR unset → non-zero"
else
    fail "ST7: rc=$RC"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
