#!/bin/bash
# tests/bin/feature-resolve-project/cache-sid1.sh
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: workflow, github, issues, bin, scope:issue-specific
# #2925 cache schema: 11-col + sid1 tag hit, legacy 10-col / wrong-tag miss, --require-wip-fields,
# --no-cache-read, resolve_project_drop_cache_row, RESOLVED_CACHE_KEY (empty on internal short-circuit).
# TL3 gap: concurrent resolves rewriting the same cache file need real multi-session runs.
#   Closest-to-action mitigation: before merge, start two real sessions on one repo at the same time,
#   run `wip-state set` in both, and confirm project-resolve.tsv keeps one intact 11-column row.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/resolve-project.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 9 failed"
    exit 1
fi

KEY="mock-owner/mock-repo"

# rr <stderr-file> [resolver flags...] — run_resolver with flags; also prints the cache key and the
# session-id field id. Self-contained so it can be shipped into a subshell via declare -f.
rr() {
    local stderr_file="$1"; shift
    git -C "$REPO_FIXTURE" remote remove origin 2>/dev/null || true
    git -C "$REPO_FIXTURE" remote add origin "https://github.com/${GH_MOCK_OWNER_REPO:-mock-owner/mock-repo}.git"
    bash -c "
        cd '$REPO_FIXTURE' || { echo 'RC=98'; exit 98; }
        source '$TARGET' >/dev/null 2>&1 || { echo 'RC=99'; exit 99; }
        if resolve_project_for_repo $*; then RC=0; else RC=\$?; fi
        printf 'RESOLVED_PROJECT_ID=%s\n'           \"\${RESOLVED_PROJECT_ID:-}\"
        printf 'RESOLVED_SESSION_ID_FIELD_ID=%s\n'  \"\${RESOLVED_SESSION_ID_FIELD_ID:-}\"
        printf 'RESOLVED_CACHE_KEY=%s\n'            \"\${RESOLVED_CACHE_KEY:-}\"
        printf 'RC=%s\n' \"\$RC\"
    " 2>"$stderr_file"
}
# row <col10> [<col11>] — 10/11-col cache row for $KEY; col 11 omitted when not given.
row() {
    printf '%s\tcached-owner\t99\tPVT_cached\tPVTF_cd\tPVTF_status\tOPT_t\tOPT_ip\tOPT_d\t%s' "$KEY" "$1"
    if [ "$#" -ge 2 ]; then printf '\t%s' "$2"; fi
    printf '\n'
}
gql_called() { grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && echo 1 || echo 0; }
run_rr() { OUT=$(run_with_timeout 30 bash -c "$(declare -f rr get_field); rr '$TMP/err' $*"); }
cache_init() { CACHE_FILE="$WORKFLOW_STATE_DIR/cache/project-resolve.tsv"; mkdir -p "$(dirname "$CACHE_FILE")"; }

# C1: an 11-col row tagged sid1 is a hit — no graphql, column 10 → RESOLVED_SESSION_ID_FIELD_ID.
setup_mock; cache_init
row PVTF_sid sid1 > "$CACHE_FILE"
run_rr
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(get_field "$OUT" RESOLVED_PROJECT_ID)" = "PVT_cached" ] \
   && [ "$(get_field "$OUT" RESOLVED_SESSION_ID_FIELD_ID)" = "PVTF_sid" ] && [ "$(gql_called)" = "0" ]; then
    pass "C1: 11-col sid1 row → hit, session-id id from column 10, no graphql"
else fail "C1: out=[$OUT] graphql=$(gql_called)"; fi
teardown_mock

# C2: a legacy 10-col row (pre-rename fingerprint id) is a miss and is replaced by an 11-col row.
setup_mock; cache_init
row PVTF_old_fp > "$CACHE_FILE"
run_rr
NF_NOW=$(awk -F'\t' -v k="$KEY" '$1==k {print NF}' "$CACHE_FILE" 2>/dev/null | head -1)
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(gql_called)" = "1" ] && [ "$NF_NOW" = "11" ] \
   && ! grep -q "PVTF_old_fp" "$CACHE_FILE" && [ "$(get_field "$OUT" RESOLVED_PROJECT_ID)" = "PVT_mock123" ]; then
    pass "C2: legacy 10-col row → miss, refetched, rewritten as 11 columns"
else fail "C2: nf=$NF_NOW out=[$OUT] cache=[$(cat "$CACHE_FILE")]"; fi
teardown_mock

# C3: an 11-col row whose tag is not sid1 is a miss.
setup_mock; cache_init
row PVTF_sid sid0 > "$CACHE_FILE"
run_rr
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(gql_called)" = "1" ] && [ "$(get_field "$OUT" RESOLVED_PROJECT_ID)" = "PVT_mock123" ]; then
    pass "C3: wrong schema tag → miss, refetched"
else fail "C3: out=[$OUT]"; fi
teardown_mock

# C4: --require-wip-fields turns a row with an empty session-id column into a miss.
setup_mock; cache_init
row "" sid1 > "$CACHE_FILE"
run_rr --require-wip-fields
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(gql_called)" = "1" ]; then
    pass "C4: --require-wip-fields + empty column 10 → miss, refetched"
else fail "C4: out=[$OUT] graphql=$(gql_called)"; fi
teardown_mock

# C5: the same row without the flag is a hit (other consumers keep their zero-call path).
setup_mock; cache_init
row "" sid1 > "$CACHE_FILE"
run_rr
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(gql_called)" = "0" ] && [ "$(get_field "$OUT" RESOLVED_PROJECT_ID)" = "PVT_cached" ]; then
    pass "C5: no flag + empty column 10 → still a hit, no graphql"
else fail "C5: out=[$OUT] graphql=$(gql_called)"; fi
teardown_mock

# C6: --no-cache-read fetches even with a valid row present.
setup_mock; cache_init
row PVTF_sid sid1 > "$CACHE_FILE"
run_rr --no-cache-read
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(gql_called)" = "1" ] && [ "$(get_field "$OUT" RESOLVED_PROJECT_ID)" = "PVT_mock123" ]; then
    pass "C6: --no-cache-read → fetched despite a valid cached row"
else fail "C6: out=[$OUT]"; fi
teardown_mock

# C7: resolve_project_drop_cache_row removes only its key's row.
setup_mock; cache_init
{ row PVTF_sid sid1; printf 'other/repo\to\t2\tPVT_o\t\tS\tT\tI\tD\tF\tsid1\n'; } > "$CACHE_FILE"
DROP_OUT=$(run_with_timeout 30 bash -c "source '$TARGET' >/dev/null 2>&1; resolve_project_drop_cache_row '$KEY'; echo RC=\$?" 2>"$TMP/err")
if [ "$(get_field "$DROP_OUT" RC)" = "0" ] && ! awk -F'\t' -v k="$KEY" '$1==k {f=1} END {exit !f}' "$CACHE_FILE" \
   && awk -F'\t' '$1=="other/repo" {f=1} END {exit !f}' "$CACHE_FILE"; then
    pass "C7: resolve_project_drop_cache_row drops its key, keeps other keys"
else fail "C7: out=[$DROP_OUT] err=$(cat "$TMP/err") cache=[$(cat "$CACHE_FILE")]"; fi
teardown_mock

# C8: RESOLVED_CACHE_KEY is the origin owner/repo after a normal resolve.
setup_mock; cache_init
run_rr
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(get_field "$OUT" RESOLVED_CACHE_KEY)" = "$KEY" ]; then
    pass "C8: RESOLVED_CACHE_KEY = owner/repo"
else fail "C8: out=[$OUT]"; fi
teardown_mock

# C9: the internal short-circuit leaves RESOLVED_CACHE_KEY empty and writes no cache row.
setup_mock; cache_init
rm -f "$CACHE_FILE"
export _ISSUE_CREATE_INTERNAL_OWNER=io _ISSUE_CREATE_INTERNAL_PROJECT_NUM=7 _ISSUE_CREATE_INTERNAL_PROJECT_ID=PVT_internal
export _ISSUE_CREATE_INTERNAL_SESSION_ID_FIELD_ID=PVTF_internal_sid
export RESOLVED_CACHE_KEY="stale/key"
run_rr
if [ "$(get_field "$OUT" RC)" = "0" ] && [ "$(get_field "$OUT" RESOLVED_PROJECT_ID)" = "PVT_internal" ] \
   && [ "$(get_field "$OUT" RESOLVED_SESSION_ID_FIELD_ID)" = "PVTF_internal_sid" ] \
   && [ -z "$(get_field "$OUT" RESOLVED_CACHE_KEY)" ] && [ ! -s "$CACHE_FILE" ]; then
    pass "C9: internal short-circuit → empty RESOLVED_CACHE_KEY, internal session-id override, no cache write"
else fail "C9: out=[$OUT]"; fi
unset RESOLVED_CACHE_KEY
teardown_mock

finish
