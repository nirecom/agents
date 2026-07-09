#!/bin/bash
# tests/feature-resolve-project/resolver-core.sh
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: workflow, github, issues, plans, bin
#
# Core resolver tests: single-project resolution, 0-project, multi-project,
# no Content Date field, short-circuit via _ISSUE_CREATE_INTERNAL_*, pagination,
# cross-org owner, SSH remote, and missing remote.
#
# L3 gap: whether resolve_project_for_repo works against a live GitHub GraphQL
# API with real tokens and real Projects v2 data.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/resolve-project.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 9 failed"
    exit 1
fi

# ===========================================================================
# T1: 1 linked project + Content Date field → all RESOLVED_* set, return 0
# ===========================================================================
setup_mock
STDERR_FILE="$TMP/t1-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
R_FIELD=$(get_field "$OUT" RESOLVED_CONTENT_DATE_FIELD_ID)
if [ "$RC" = "0" ] \
   && [ "$R_OWNER" = "nirecom" ] \
   && [ "$R_NUM" = "1" ] \
   && [ "$R_ID" = "PVT_mock123" ] \
   && [ "$R_FIELD" = "PVTF_mock_content_date" ]; then
    pass "T1: 1 linked project + Content Date field → all RESOLVED_* set"
else
    fail "T1: rc=$RC owner=$R_OWNER num=$R_NUM id=$R_ID field=$R_FIELD stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T2: 0 linked projects → return 1, stderr contains "no Projects v2"
# ===========================================================================
setup_mock
export GH_MOCK_PROJECTS_NODE_COUNT=0
STDERR_FILE="$TMP/t2-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "1" ] && grep -qi "no Projects v2" "$STDERR_FILE" 2>/dev/null; then
    pass "T2: 0 linked projects → return 1, stderr 'no Projects v2'"
else
    fail "T2: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T3: 2+ linked projects → return 0, RESOLVED_* from first node, warn on stderr
# ===========================================================================
setup_mock
export GH_MOCK_PROJECTS_NODE_COUNT=2
export GH_MOCK_PROJECT_OWNER="first-owner"
export GH_MOCK_PROJECT_NUM=7
export GH_MOCK_PROJECT_ID="PVT_first"
STDERR_FILE="$TMP/t3-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
if [ "$RC" = "0" ] \
   && [ "$R_OWNER" = "first-owner" ] \
   && [ "$R_NUM" = "7" ] \
   && [ "$R_ID" = "PVT_first" ] \
   && grep -qi "multiple Projects v2" "$STDERR_FILE" 2>/dev/null; then
    pass "T3: 2+ linked projects → first wins + warn on stderr"
else
    fail "T3: rc=$RC owner=$R_OWNER num=$R_NUM id=$R_ID stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T4: 1 project but no Content Date field → return 0, RESOLVED_CONTENT_DATE_FIELD_ID empty
# ===========================================================================
setup_mock
export GH_MOCK_CONTENT_DATE_FIELD_ID=""
STDERR_FILE="$TMP/t4-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_FIELD=$(get_field "$OUT" RESOLVED_CONTENT_DATE_FIELD_ID)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
if [ "$RC" = "0" ] && [ -z "$R_FIELD" ] && [ "$R_NUM" = "1" ]; then
    pass "T4: project but no Content Date field → return 0, field id empty"
else
    fail "T4: rc=$RC field='$R_FIELD' num=$R_NUM stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T5: short-circuit — _ISSUE_CREATE_INTERNAL_* all set, graphql NOT called
# ===========================================================================
setup_mock
export _ISSUE_CREATE_INTERNAL_OWNER="internal-owner"
export _ISSUE_CREATE_INTERNAL_PROJECT_NUM="42"
export _ISSUE_CREATE_INTERNAL_PROJECT_ID="PVT_internal"
STDERR_FILE="$TMP/t5-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
GRAPHQL_CALLED=0
grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && GRAPHQL_CALLED=1
if [ "$RC" = "0" ] \
   && [ "$R_OWNER" = "internal-owner" ] \
   && [ "$R_NUM" = "42" ] \
   && [ "$R_ID" = "PVT_internal" ] \
   && [ "$GRAPHQL_CALLED" -eq 0 ]; then
    pass "T5: short-circuit via _ISSUE_CREATE_INTERNAL_* → no graphql, values from internal vars"
else
    fail "T5: rc=$RC owner=$R_OWNER num=$R_NUM id=$R_ID graphql_called=$GRAPHQL_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T6: fields pagination — Content Date appears on page 2
# ===========================================================================
setup_mock
export GH_MOCK_FIELDS_TWO_PAGES=1
export GH_MOCK_FIELDS_PAGE_COUNTER="$TMP/fields-page-counter"
echo 0 > "$GH_MOCK_FIELDS_PAGE_COUNTER"
STDERR_FILE="$TMP/t6-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_FIELD=$(get_field "$OUT" RESOLVED_CONTENT_DATE_FIELD_ID)
FIELDS_CALL_COUNT=$(grep -c "api graphql" "$MOCK_LOG" 2>/dev/null || echo 0)
if [ "$RC" = "0" ] && [ "$R_FIELD" = "PVTF_mock_content_date" ] && [ "$FIELDS_CALL_COUNT" -ge 2 ]; then
    pass "T6: fields pagination — Content Date found on page 2 (graphql calls: $FIELDS_CALL_COUNT)"
else
    fail "T6: rc=$RC field=$R_FIELD calls=$FIELDS_CALL_COUNT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-cross-org: project owner.login differs from repo remote owner
# RESOLVED_OWNER must be the project node owner, NOT the repo owner.
# ===========================================================================
setup_mock
export GH_MOCK_OWNER_REPO="repo-owner-org/some-repo"
export GH_MOCK_PROJECT_OWNER="different-project-owner"
STDERR_FILE="$TMP/t-cross-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
if [ "$RC" = "0" ] && [ "$R_OWNER" = "different-project-owner" ]; then
    pass "T-cross-org: RESOLVED_OWNER = project node owner (not repo owner)"
else
    fail "T-cross-org: rc=$RC owner=$R_OWNER (expected 'different-project-owner', not 'repo-owner-org')"
fi
teardown_mock

# ===========================================================================
# T-ssh-remote: gh repo view returns org/repo (gh internally parses SSH URL)
# ===========================================================================
setup_mock
export GH_MOCK_OWNER_REPO="ssh-org/ssh-repo"
STDERR_FILE="$TMP/t-ssh-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
CACHE_FILE="$WORKFLOW_PLANS_DIR/cache/project-resolve.tsv"
HAS_KEY=0
[ -f "$CACHE_FILE" ] && grep -q "^ssh-org/ssh-repo" "$CACHE_FILE" 2>/dev/null && HAS_KEY=1
if [ "$RC" = "0" ] && [ "$HAS_KEY" = "1" ]; then
    pass "T-ssh-remote: owner/repo from gh repo view consumed correctly (ssh-org/ssh-repo)"
else
    fail "T-ssh-remote: rc=$RC has_key=$HAS_KEY cache=$(cat "$CACHE_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-no-remote: gh repo view fails → return 1
# ===========================================================================
setup_mock
export GH_MOCK_REPO_VIEW_FAIL=1
STDERR_FILE="$TMP/t-no-remote-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "1" ] && [ -s "$STDERR_FILE" ]; then
    pass "T-no-remote: gh repo view fails → return 1 + warn"
else
    fail "T-no-remote: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

finish
