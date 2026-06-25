#!/bin/bash
# tests/feature-961-sc5-heuristic.sh
# Tests: skills/session-close/SKILL.md
# Tags: supervisor, em-supervisor, l2-findings, scope:issue-specific
# Tests for issue #961 — SC-5 heuristic for orphaned alert_armed_at + #1027 SC-7.
# Text-contract assertions on skills/session-close/SKILL.md.
#
# # L3 gap
# Static text checks. L3 not applicable.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SC_FILE="$AGENTS_DIR/skills/session-close/SKILL.md"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

if [ ! -f "$SC_FILE" ]; then
    skip "skills/session-close/SKILL.md missing"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 0
fi

# T1: SC-5 heuristic mentions last_run_at as heuristic signal
if grep -q "last_run_at" "$SC_FILE"; then
    pass "T1: SC-5 heuristic mentions 'last_run_at'"
else
    fail "T1: 'last_run_at' not present in session-close SKILL.md"
fi

# T2: SC-5 references --clear-l2-armed-at state repair
if grep -q "clear-l2-armed-at" "$SC_FILE"; then
    pass "T2: SC-5 mentions 'clear-l2-armed-at' repair flag"
else
    fail "T2: 'clear-l2-armed-at' not present in session-close SKILL.md"
fi

# T3: issue citation #961
if grep -q "#961" "$SC_FILE"; then
    pass "T3: issue #961 cited"
else
    fail "T3: '#961' not present in session-close SKILL.md"
fi

# T4: eligibility write — post_final_report_window
if grep -q "post_final_report_window" "$SC_FILE"; then
    pass "T4: eligibility token 'post_final_report_window' present"
else
    fail "T4: 'post_final_report_window' not present in session-close SKILL.md"
fi

# T5: SC-7 step present
if grep -q "SC-7" "$SC_FILE"; then
    pass "T5: SC-7 step heading present"
else
    fail "T5: 'SC-7' not present in session-close SKILL.md"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
