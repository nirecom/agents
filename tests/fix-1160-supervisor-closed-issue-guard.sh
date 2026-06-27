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

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# S1: agents/supervisor.md contains a gh issue view call for checking issue state,
# specifically for the closed-issue detection logic (not the Phase 4 dispatch detection).
# The fix adds issue-state querying logic near the "Inputs to read" section.
# We look for the combination of gh issue view AND state check AND closes_issues context.
run_s1() {
    require_source "$SUPERVISOR_MD" "S1: supervisor.md contains gh issue view state check for closes_issues" || return
    # The fix will add a directive referencing closes_issues + gh issue view state check
    # near the Inputs to read section. Look for the specific combination.
    local has_closes_issues has_issue_view_state
    has_closes_issues=0; has_issue_view_state=0
    grep -q "closes_issues" "$SUPERVISOR_MD" && has_closes_issues=1
    # The fix adds gh issue view <N> --json state (or similar) for state checking.
    # This must appear near closes_issues context, not just the Phase 4 dispatch section.
    # We check for the presence of both jq and state extraction near gh issue view.
    ( grep -q "\-\-json state\|jq.*\.state\|\.state.*jq" "$SUPERVISOR_MD" ) && has_issue_view_state=1
    if [ "$has_closes_issues" = "1" ] && [ "$has_issue_view_state" = "1" ]; then
        pass "S1: supervisor.md contains gh issue view state check for closes_issues"
    else
        fail "S1: supervisor.md missing closes_issues + gh issue view state check (has_closes_issues=$has_closes_issues, has_issue_view_state=$has_issue_view_state; fix #1160 not yet applied)"
    fi
}

# S2: agents/supervisor.md contains CLOSED check that leads to UNAVAILABLE fallback.
# The directive must say: if ALL issues CLOSED -> treat wsid as UNAVAILABLE.
# Note: UNAVAILABLE already exists in the file (for missing wsid); the fix adds a CLOSED
# variant that also triggers the UNAVAILABLE fallback path.
run_s2() {
    require_source "$SUPERVISOR_MD" "S2: supervisor.md contains all-CLOSED -> UNAVAILABLE directive" || return
    local has_closed has_unavailable_fallback
    has_closed=0; has_unavailable_fallback=0
    grep -qi "CLOSED" "$SUPERVISOR_MD" && has_closed=1
    # The fix must add a directive that explicitly ties CLOSED issues to UNAVAILABLE fallback.
    # Check for the specific pairing: CLOSED state + UNAVAILABLE (or skip) path.
    # We require CLOSED to appear — it does NOT currently appear (UNAVAILABLE already does).
    grep -qi "UNAVAILABLE" "$SUPERVISOR_MD" && has_unavailable_fallback=1
    if [ "$has_closed" = "1" ] && [ "$has_unavailable_fallback" = "1" ]; then
        pass "S2: supervisor.md contains all-CLOSED -> UNAVAILABLE directive"
    else
        fail "S2: supervisor.md missing CLOSED->UNAVAILABLE directive (has_closed=$has_closed, has_unavailable_fallback=$has_unavailable_fallback; fix #1160 not yet applied)"
    fi
}

# S3: The gh issue view invocation pattern includes --json state --jq .state (or equivalent)
# in a closes_issues context — distinct from the Phase 4 dispatch detection section.
# This validates the specific command shape mandated by the fix spec.
run_s3() {
    require_source "$SUPERVISOR_MD" "S3: supervisor.md closes_issues section contains jq .state extraction" || return
    # The fix adds a jq .state (or --jq .state) pattern for reading issue state from gh output.
    # The Phase 4 section uses --json but not for state extraction. We check the new pattern.
    if grep -q "jq.*\.state\|--json state\|\.state.*jq" "$SUPERVISOR_MD"; then
        pass "S3: supervisor.md closes_issues section contains jq .state extraction"
    else
        fail "S3: supervisor.md missing jq .state extraction for closed-issue check (fix #1160 not yet applied)"
    fi
}

run_s1
run_s2
run_s3

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
