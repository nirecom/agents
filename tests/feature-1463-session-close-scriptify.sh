#!/bin/bash
# tests/feature-1463-session-close-scriptify.sh
# Tests: bin/render-final-report.js, bin/session-close-detect-wf-meta.js, bin/session-close-render-sc7.js, hooks/lib/final-report-schema.js, hooks/stop-final-report-guard.js, skills/session-close/SKILL.md
# Tags: scope:issue-specific
#
# Issue #1463 — scriptify session-close/SKILL.md.
# The SC-6 Final Report emit and its `node -e` helpers move out of SKILL.md into
# three bin/ scripts. This suite verifies those scripts render the full Final
# Report with no unresolved guard tokens, plus structural assertions on SKILL.md.
#
# This is a dispatcher (file-split rule: >500 lines). Series live in
# feature-1463-session-close-scriptify/: render-tests.sh (bin/render-final-report.js
# existence + rendering, T1-T9/T7b/T7c/T19-T21), detect-sc7-tests.sh
# (bin/session-close-detect-wf-meta.js + bin/session-close-render-sc7.js,
# T10-T18), structural-tests.sh (SKILL.md + guard structural assertions, S1-S7).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

run_sub() {
    local out rc
    out="$(bash "$1" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    local p f s
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    s=$(printf '%s\n' "$out" | grep -c '^SKIP:' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    TOTAL_SKIP=$((TOTAL_SKIP + s))
    # A nonzero child exit with zero printed FAIL: lines means the child
    # crashed (syntax error, missing file, uncaught exception) before it
    # could report its own failures. Without this, such a crash would be
    # silently treated as a clean 0-failure run (false green).
    if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
        printf 'FAIL: %s exited with status %s but printed no FAIL: lines (likely a crash)\n' "$1" "$rc"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

run_sub "$TESTS_DIR/feature-1463-session-close-scriptify/render-tests.sh"
run_sub "$TESTS_DIR/feature-1463-session-close-scriptify/detect-sc7-tests.sh"
run_sub "$TESTS_DIR/feature-1463-session-close-scriptify/structural-tests.sh"

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed, $TOTAL_SKIP skipped"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"

exit $TOTAL_FAIL
