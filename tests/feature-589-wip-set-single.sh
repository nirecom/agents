#!/bin/bash
# Tests: bin/github-issues/wip-set-single.sh
# Tags: wip, meta, clarify-intent, issue-close

set -u

AGENTS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$AGENTS_REPO/bin/github-issues/wip-set-single.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

if [ ! -x "$SUT" ]; then
    echo "FAIL: precondition — $SUT missing or not executable"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

setup_tmp() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipsingle)"
    mkdir -p "$TMP/mock-bin" "$TMP/bin/github-issues"

    # Mock gh: reads GH_MOCK_LABELS env. "fail" → exit 1; else echo it.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
if [ "${GH_MOCK_LABELS:-}" = "fail" ]; then
    exit 1
fi
echo "${GH_MOCK_LABELS:-[]}"
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    # Mock wip-state.sh: exits $GH_MOCK_WIP_RC (default 0).
    cat > "$TMP/bin/github-issues/wip-state.sh" <<'MOCKWIP'
#!/bin/bash
exit "${GH_MOCK_WIP_RC:-0}"
MOCKWIP
    chmod +x "$TMP/bin/github-issues/wip-state.sh"

    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$TMP/mock-bin:$PATH"
}

teardown_tmp() {
    rm -rf "$TMP" 2>/dev/null
    unset GH_MOCK_LABELS GH_MOCK_WIP_RC
    # Restore PATH to remove mock-bin
    PATH="${PATH#$TMP/mock-bin:}"
    export PATH
}

# ============================================================================
# T1: non-meta label + wip-state rc=0 → stdout=SET_OK, exit 0
# ============================================================================
setup_tmp
export GH_MOCK_LABELS='["type:task","intent:clarified"]'
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$SUT" 123 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "SET_OK" ]; then
    pass "T1: non-meta + rc=0 → SET_OK, exit 0"
else
    fail "T1: expected (SET_OK,0); got ($OUT,$RC)"
fi
teardown_tmp

# ============================================================================
# T2: meta label → stdout=META_SKIP, exit 0
# ============================================================================
setup_tmp
export GH_MOCK_LABELS='["meta","type:task"]'
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$SUT" 123 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "META_SKIP" ]; then
    pass "T2: meta → META_SKIP, exit 0"
else
    fail "T2: expected (META_SKIP,0); got ($OUT,$RC)"
fi
teardown_tmp

# ============================================================================
# T3: label probe fails → fail-open, wip-state runs (rc=0), exit 0 SET_OK
# ============================================================================
setup_tmp
export GH_MOCK_LABELS="fail"
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$SUT" 123 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "SET_OK" ]; then
    pass "T3: label probe fail → fail-open SET_OK, exit 0"
else
    fail "T3: expected (SET_OK,0); got ($OUT,$RC)"
fi
teardown_tmp

# ============================================================================
# T4: non-meta + wip-state rc=1 → exit 1, no stdout token
# ============================================================================
setup_tmp
export GH_MOCK_LABELS='["type:task"]'
export GH_MOCK_WIP_RC=1
OUT=$(run_with_timeout 10 bash "$SUT" 123 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "T4: non-meta + rc=1 → exit 1"
else
    fail "T4: expected exit 1; got ($OUT,$RC)"
fi
teardown_tmp

# ============================================================================
# T5: non-meta + wip-state rc=2 → stdout=RC2, exit 2
# ============================================================================
setup_tmp
export GH_MOCK_LABELS='["type:task"]'
export GH_MOCK_WIP_RC=2
OUT=$(run_with_timeout 10 bash "$SUT" 123 2>/dev/null)
RC=$?
if [ "$RC" -eq 2 ] && [ "$OUT" = "RC2" ]; then
    pass "T5: non-meta + rc=2 → RC2, exit 2"
else
    fail "T5: expected (RC2,2); got ($OUT,$RC)"
fi
teardown_tmp

# ============================================================================
# T6: meta + wip-state rc=2 → META_SKIP, exit 0 (wip-state never runs)
# ============================================================================
setup_tmp
export GH_MOCK_LABELS='["meta"]'
export GH_MOCK_WIP_RC=2
OUT=$(run_with_timeout 10 bash "$SUT" 123 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "META_SKIP" ]; then
    pass "T6: meta + rc=2 unused → META_SKIP, exit 0"
else
    fail "T6: expected (META_SKIP,0); got ($OUT,$RC)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
