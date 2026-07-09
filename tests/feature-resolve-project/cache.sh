#!/bin/bash
# tests/feature-resolve-project/cache.sh
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: workflow, github, issues, plans, bin
#
# Cache tests: hit (10-col schema), dot-in-key fixed-string match, cache update
# replaces old row, malformed row treated as miss, cache miss writes TSV row,
# second resolution updates cache (not duplicated).
#
# L3 gap: whether cache persistence works across real process boundaries with
# concurrent resolve calls or filesystem contention.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/resolve-project.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 6 failed"
    exit 1
fi

# ===========================================================================
# T7: cache hit — pre-populate TSV, resolver returns cached values without graphql
# Updated for #1340: 10-column cache schema (cols 6-10: status, todo, inprog, done, finger).
# ===========================================================================
setup_mock
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
printf 'nirecom/agents\tcached-owner\t99\tPVT_cached\tPVTF_cached_field\tPVTF_status\tPVTF_todo\tPVTF_inprog\tPVTF_done\tPVTF_finger\n' > "$CACHE_FILE"
STDERR_FILE="$TMP/t7-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
R_FIELD=$(get_field "$OUT" RESOLVED_CONTENT_DATE_FIELD_ID)
GRAPHQL_CALLED=0
grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && GRAPHQL_CALLED=1
if [ "$RC" = "0" ] \
   && [ "$R_OWNER" = "cached-owner" ] \
   && [ "$R_NUM" = "99" ] \
   && [ "$R_ID" = "PVT_cached" ] \
   && [ "$R_FIELD" = "PVTF_cached_field" ] \
   && [ "$GRAPHQL_CALLED" -eq 0 ]; then
    pass "T7: cache hit — values from TSV (10-col schema), no graphql call"
else
    fail "T7: rc=$RC owner=$R_OWNER num=$R_NUM id=$R_ID field=$R_FIELD graphql=$GRAPHQL_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T7b: cache lookup with owner/repo containing "." (regex metachar safety)
# Updated for #1340: 10-column rows so schema guard accepts them as cache hits.
# ===========================================================================
setup_mock
export GH_MOCK_OWNER_REPO="nire.com/my.repo"
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
printf 'nireXcom/myXrepo\tWRONG-owner\t100\tPVT_WRONG\tPVTF_WRONG\tst\ttd\tip\tdn\tfg\n' > "$CACHE_FILE"
printf 'nire.com/my.repo\tcorrect-owner\t5\tPVT_correct\tPVTF_correct\tst\ttd\tip\tdn\tfg\n' >> "$CACHE_FILE"
STDERR_FILE="$TMP/t7b-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
if [ "$RC" = "0" ] \
   && [ "$R_OWNER" = "correct-owner" ] \
   && [ "$R_NUM" = "5" ] \
   && [ "$R_ID" = "PVT_correct" ]; then
    pass "T7b: cache lookup with '.' in owner/repo uses fixed-string match"
else
    fail "T7b: rc=$RC owner=$R_OWNER num=$R_NUM id=$R_ID stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T7c: cache update — old row replaced, only 1 row for the key after re-resolve
# ===========================================================================
setup_mock
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
printf 'nirecom/agents\tstale-owner\t100\tPVT_stale\tPVTF_stale\n' > "$CACHE_FILE"
rm -f "$CACHE_FILE"
export GH_MOCK_PROJECT_ID="PVT_first_call"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
export GH_MOCK_PROJECT_ID="PVT_second_call"
rm -f "$CACHE_FILE"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
if [ -f "$CACHE_FILE" ]; then
    ROW_COUNT=$(awk -F'\t' '$1=="nirecom/agents"' "$CACHE_FILE" | wc -l | tr -d ' ')
    HAS_NEW=0
    grep -q "PVT_second_call" "$CACHE_FILE" 2>/dev/null && HAS_NEW=1
    HAS_OLD=0
    grep -q "PVT_first_call" "$CACHE_FILE" 2>/dev/null && HAS_OLD=1
    if [ "$ROW_COUNT" = "1" ] && [ "$HAS_NEW" = "1" ] && [ "$HAS_OLD" = "0" ]; then
        pass "T7c: cache update replaces old row (1 row, new id, old id absent)"
    else
        fail "T7c: rows=$ROW_COUNT has_new=$HAS_NEW has_old=$HAS_OLD cache=$(cat "$CACHE_FILE" 2>/dev/null)"
    fi
else
    fail "T7c: cache file not created"
fi
teardown_mock

# ===========================================================================
# T7d: malformed cache row → treated as miss, re-fetch via graphql
# ===========================================================================
setup_mock
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
printf 'nirecom/agents\tincomplete\n' > "$CACHE_FILE"
STDERR_FILE="$TMP/t7d-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
GRAPHQL_CALLED=0
grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && GRAPHQL_CALLED=1
if [ "$RC" = "0" ] \
   && [ "$R_NUM" = "1" ] \
   && [ "$R_ID" = "PVT_mock123" ] \
   && [ "$GRAPHQL_CALLED" -eq 1 ]; then
    pass "T7d: malformed cache row → treated as miss, re-fetched via graphql"
else
    fail "T7d: rc=$RC num=$R_NUM id=$R_ID graphql=$GRAPHQL_CALLED stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T8: cache miss → fetch → cache file created with correct TSV row
# ===========================================================================
setup_mock
CACHE_FILE="$WORKFLOW_PLANS_DIR/cache/project-resolve.tsv"
[ -f "$CACHE_FILE" ] && rm "$CACHE_FILE"
STDERR_FILE="$TMP/t8-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "0" ] && [ -f "$CACHE_FILE" ]; then
    ROW=$(awk -F'\t' '$1=="nirecom/agents"' "$CACHE_FILE" | head -1)
    COL_COUNT=$(printf '%s' "$ROW" | awk -F'\t' '{print NF}')
    COL1=$(printf '%s' "$ROW" | cut -f1)
    COL2=$(printf '%s' "$ROW" | cut -f2)
    COL3=$(printf '%s' "$ROW" | cut -f3)
    COL4=$(printf '%s' "$ROW" | cut -f4)
    COL5=$(printf '%s' "$ROW" | cut -f5)
    if [ "$COL_COUNT" = "10" ] \
       && [ "$COL1" = "nirecom/agents" ] \
       && [ "$COL2" = "nirecom" ] \
       && [ "$COL3" = "1" ] \
       && [ "$COL4" = "PVT_mock123" ] \
       && [ "$COL5" = "PVTF_mock_content_date" ]; then
        pass "T8: cache miss → fetch → 10-column TSV row written correctly"
    else
        fail "T8: row mismatch — cols=$COL_COUNT col1=$COL1 col2=$COL2 col3=$COL3 col4=$COL4 col5=$COL5 row='$ROW'"
    fi
else
    fail "T8: rc=$RC cache_exists=$([ -f "$CACHE_FILE" ] && echo yes || echo no) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T8b: second resolution with different data → cache row updated (not duplicated)
# ===========================================================================
setup_mock
CACHE_FILE="$WORKFLOW_PLANS_DIR/cache/project-resolve.tsv"
export GH_MOCK_PROJECT_NUM=10
export GH_MOCK_PROJECT_ID="PVT_v1"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
rm -f "$CACHE_FILE"
export GH_MOCK_PROJECT_NUM=20
export GH_MOCK_PROJECT_ID="PVT_v2"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
ROW_COUNT=$(awk -F'\t' '$1=="nirecom/agents"' "$CACHE_FILE" 2>/dev/null | wc -l | tr -d ' ')
HAS_V2=0
grep -q "PVT_v2" "$CACHE_FILE" 2>/dev/null && HAS_V2=1
if [ "$ROW_COUNT" = "1" ] && [ "$HAS_V2" = "1" ]; then
    pass "T8b: second resolution updates cache row (not duplicated)"
else
    fail "T8b: rows=$ROW_COUNT has_v2=$HAS_V2 cache=$(cat "$CACHE_FILE" 2>/dev/null)"
fi
teardown_mock

finish
