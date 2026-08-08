#!/bin/bash
# tests/feature-405-final-report.sh
# Tests: hooks/lib/parse-closes-issues.js, hooks/lib/worktree-notes.js, hooks/lib/final-report-schema.js, skills/worktree-end/SKILL.md, skills/session-close/SKILL.md
# Tags: worktree, end, cleanup, parse, closes-issues, schema
#
# Issue #405 / #771 — Final Report feature (post-renderer-abolition).
#
# After #771: bin/worktree-final-report.js is deleted. The Final Report is now
# emitted by Claude inline using `renderSkeleton(sessionId)` from
# hooks/lib/final-report-schema.js as a guide. Tests for the deleted renderer
# (R-series) have been removed; K-series (skeleton) tests added.
#
# This is a dispatcher (file-split rule: >500 lines). Series live in
# feature-405-final-report/: p-series.sh (parse-closes-issues.js),
# s-series.sh (worktree-notes.js buildNotesBody), k-series.sh (renderSkeleton /
# renderFinalReport), i-series.sh (SKILL.md + detect-restart.sh invariants).

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

run_sub "$TESTS_DIR/feature-405-final-report/p-series.sh"
run_sub "$TESTS_DIR/feature-405-final-report/s-series.sh"
run_sub "$TESTS_DIR/feature-405-final-report/k-series.sh"
run_sub "$TESTS_DIR/feature-405-final-report/i-series.sh"

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed, $TOTAL_SKIP skipped"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"

exit $TOTAL_FAIL
