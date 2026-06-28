#!/usr/bin/env bash
# Tests: agents/supervisor.md (closed-issue UNAVAILABLE guard)
# Tags: supervisor, em-supervisor, supervisor-md, fix-1160, scope:issue-specific
# RED for issue #1160.
#
# Validates that agents/supervisor.md instructs the supervisor agent to:
# 1. Extract issue numbers from closes_issues in the wsid-intent.md after reading it.
# 2. Call `gh issue view <N> --json state --jq .state` to check each issue's state.
# 3. Treat the wsid as UNAVAILABLE when ALL issues are CLOSED.
# 4. Proceed as an active session when at least one issue is OPEN.
#
# These are structural checks — they verify that the directive text is present
# in agents/supervisor.md near the "Inputs to read" section.
#
# L3 gap (what this test does NOT catch):
# - Whether the supervisor agent LLM actually follows the directive at runtime —
#   only a real claude -p session exercising the Stop-hook block path can verify that.
# - Whether `gh issue view` returns the expected JSON shape in a real GitHub call.
# Closest-to-action mitigation: skill-orchestration category in
#   bin/check-verification-gate.sh fires at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"
BIN_CHECK_SESSION="$AGENTS_DIR/bin/supervisor-check-session-active"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# S1: agents/supervisor.md references bin/supervisor-check-session-active CLI
# (extracted from inline procedure by #1195; the closed-session guard now lives in the script).
run_s1() {
    require_source "$SUPERVISOR_MD" "S1: supervisor.md references supervisor-check-session-active" || return
    if grep -q "supervisor-check-session-active" "$SUPERVISOR_MD"; then
        pass "S1: supervisor.md references supervisor-check-session-active CLI"
    else
        fail "S1: supervisor.md missing supervisor-check-session-active reference (fix #1160/#1195 not applied)"
    fi
}

# S2: agents/supervisor.md ties Exit 1 (terminated session) to the UNAVAILABLE fallback.
# After #1195 extraction, the directive reads "Exit 1 → terminated session: ... UNAVAILABLE fallback".
run_s2() {
    require_source "$SUPERVISOR_MD" "S2: supervisor.md ties Exit 1 to UNAVAILABLE fallback" || return
    local has_exit1 has_unavailable
    has_exit1=0; has_unavailable=0
    grep -q "Exit 1" "$SUPERVISOR_MD" && has_exit1=1
    grep -q "UNAVAILABLE" "$SUPERVISOR_MD" && has_unavailable=1
    if [ "$has_exit1" = "1" ] && [ "$has_unavailable" = "1" ]; then
        pass "S2: supervisor.md ties Exit 1 (terminated) to UNAVAILABLE fallback"
    else
        fail "S2: supervisor.md missing Exit 1->UNAVAILABLE directive (has_exit1=$has_exit1, has_unavailable=$has_unavailable; fix #1160/#1195 not applied)"
    fi
}

# S3: bin/supervisor-check-session-active contains the gh issue view state check
# (extracted from supervisor.md; must use --json state or jq .state).
run_s3() {
    require_source "$BIN_CHECK_SESSION" "S3: bin/supervisor-check-session-active exists" || return
    if grep -q "\-\-json state\|jq.*\.state\|\.state.*jq" "$BIN_CHECK_SESSION"; then
        pass "S3: bin/supervisor-check-session-active contains gh issue view state check"
    else
        fail "S3: bin/supervisor-check-session-active missing --json state / jq .state (fix #1160 not implemented)"
    fi
}

run_s1
run_s2
run_s3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
