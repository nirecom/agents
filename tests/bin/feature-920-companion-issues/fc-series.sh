#!/bin/bash
# tests/feature-920-companion-issues/fc-series.sh
# Tests: bin/github-issues/find-companion-issues.sh
# Tags: companion-issues, find-companion-issues, wip-filter, parent-filter, scope:issue-specific
#
# FC-series (#1117 Step 3): the candidate loop in find-companion-issues.sh gains
# two extra exclusion axes layered on top of the existing CLOSED/meta filters:
#   - WIP filter: a candidate already owned by ANOTHER session (wip-state check
#     prints "other") is excluded. "none"/"same" do NOT exclude. A wip-state
#     probe error is fail-open (candidate kept).
#   - parent filter: when the primary HAS a parent (PASS_C_PARENT_N non-empty),
#     a candidate whose number equals the primary's parent is excluded — the
#     parent itself is never proposed as a companion. When the primary has no
#     parent, the filter is disabled.
#
# Split from a-series.sh to keep each file under the 500-line HARD cap
# (rules/coding/file-split.md). Mirrors the existing a/b/c-d split convention.
# FC-1..FC-8 are the new RED contract — they pass once Step 3 rewrites the
# candidate loop. The split test suite is collected by feature-920-companion.sh.
#
# L3 gap (what these tests do NOT catch):
# - Whether the real wip-state.sh fingerprint logic classifies live sessions
#   identically to the mock (mock returns a fixed token).
# - Whether the live Projects v2 parent linkage matches the mocked
#   gh api `.parent.number` shape.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Common fixture: primary #100 xrefs candidate #201 (Pass A), no identifier
# overlap, parent varies per test. Candidate #201 OPEN non-meta.
seed_xref_201() {
    export GH_MOCK_VIEW_100='{"number":100,"title":"Unrelated topic","body":"See also #201"}'
    export GH_MOCK_BODY_COMMENTS_100='{"body":"See also #201","comments":[]}'
    export GH_MOCK_CAND_201='{"number":201,"title":"Some candidate","labels":[],"state":"OPEN"}'
}

# FC-1 (A18): WIP "none" → candidate included normally.
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":null}'
export MOCK_WIP_STATE_GET_RESULT=none
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-1: WIP none → candidate #201 included"
    else
        fail "FC-1: expected #201 present (WIP none); got rc=$RC out=$OUT"
    fi
else
    fail "FC-1: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-2 (A19): WIP "other" → candidate excluded (owned by another session).
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":null}'
export MOCK_WIP_STATE_GET_RESULT=other
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-2: WIP other → candidate #201 excluded"
    else
        fail "FC-2: expected #201 absent (WIP other); got rc=$RC out=$OUT"
    fi
else
    fail "FC-2: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-3 (A20): WIP "same" → candidate NOT excluded (this session already owns it).
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":null}'
export MOCK_WIP_STATE_GET_RESULT=same
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-3: WIP same → candidate #201 included"
    else
        fail "FC-3: expected #201 present (WIP same); got rc=$RC out=$OUT"
    fi
else
    fail "FC-3: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-4 (A21): wip-state probe errors (rc=1) → fail-open, candidate included.
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":null}'
export MOCK_WIP_STATE_GET_RC=1
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-4: wip-state rc=1 → fail-open, candidate #201 included"
    else
        fail "FC-4: expected #201 present (wip-state error fail-open); got rc=$RC out=$OUT"
    fi
else
    fail "FC-4: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-5 (A22): candidate state=CLOSED → excluded (named regression for the
# 3-axis filter; the CLOSED axis must survive the Step-3 rewrite).
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":null}'
export GH_MOCK_CAND_201='{"number":201,"title":"Closed candidate","labels":[],"state":"CLOSED"}'
export MOCK_WIP_STATE_GET_RESULT=none
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-5: CLOSED candidate → excluded (regression for CLOSED axis)"
    else
        fail "FC-5: expected #201 absent (CLOSED); got rc=$RC out=$OUT"
    fi
else
    fail "FC-5: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-6 (A23): primary has parent #201 → candidate #201 (== parent) excluded.
# Primary body also xrefs #201 so it enters the candidate set via Pass A; the
# parent filter must drop it. #202 (sibling, also xref'd) survives.
setup_mock
export GH_MOCK_VIEW_100='{"number":100,"title":"Child issue","body":"See #201 and #202"}'
export GH_MOCK_BODY_COMMENTS_100='{"body":"See #201 and #202","comments":[]}'
export GH_MOCK_ISSUE_100='{"parent":{"number":201}}'
export GH_MOCK_SUBISSUES_201='[{"number":202,"state":"open"},{"number":100,"state":"open"}]'
export GH_MOCK_CAND_201='{"number":201,"title":"Parent issue","labels":[],"state":"OPEN"}'
export GH_MOCK_CAND_202='{"number":202,"title":"Sibling issue","labels":[],"state":"OPEN"}'
export MOCK_WIP_STATE_GET_RESULT=none
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | grep -qE '^201	' \
       && printf '%s\n' "$OUT" | grep -qE '^202	'; then
        pass "FC-6: parent #201 excluded; sibling #202 kept"
    else
        fail "FC-6: expected #201 absent + #202 present; got rc=$RC out=$OUT"
    fi
else
    fail "FC-6: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-7 (A24): primary has no parent (PASS_C_PARENT_N empty) → parent filter
# disabled; candidate #201 included.
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":null}'
export MOCK_WIP_STATE_GET_RESULT=none
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-7: no parent → parent filter disabled, #201 included"
    else
        fail "FC-7: expected #201 present (no parent); got rc=$RC out=$OUT"
    fi
else
    fail "FC-7: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

# FC-8 (A25): primary has parent #999 which does NOT match candidate #201 →
# parent filter active but #201 not the parent → candidate included.
setup_mock
seed_xref_201
export GH_MOCK_ISSUE_100='{"parent":{"number":999}}'
export GH_MOCK_SUBISSUES_999='[{"number":201,"state":"open"}]'
export MOCK_WIP_STATE_GET_RESULT=none
if [ -x "$FIND_SCRIPT" ]; then
    OUT=$(run_with_timeout 10 bash "$FIND_SCRIPT" --primary 100 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE '^201	'; then
        pass "FC-8: parent #999 != candidate #201 → #201 included"
    else
        fail "FC-8: expected #201 present (parent mismatch); got rc=$RC out=$OUT"
    fi
else
    fail "FC-8: find-companion-issues.sh not found at $FIND_SCRIPT"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
