#!/bin/bash
# tests/feature-1340-issue-setup/resolve-project-schema.sh
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: issue-setup, resolve-project, github-issues, scope:issue-specific
# N/A: secret-leakage — cached field IDs are project-structure identifiers, not secrets; gh owns token handling.
#
# Tests for resolve-project.sh 10-column TSV schema guard (step 3 of #1340).
# L2: table-driven parser/schema-guard cases (5/9/3-col, empty file, blank lines,
#     trailing-blank hit, duplicate-row hit, empty-middle-field hit,
#     empty-required-field miss, col7 retention); 10-col full hit (5 exact IDs);
#     cold fetch → 5 new vars = EXACT known mock IDs; cache write → 10 cols with
#     cols 6-10 = exact field/option IDs.
#
# L3 gap (what this test does NOT catch):
# - Whether GraphQL field-ID queries return correct IDs from a live GitHub Projects API.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TARGET="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"
export TARGET

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/resolve-project.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 10 failed"
    exit 1
fi

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"

    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  repo\ view\ *--json\ owner,name*)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0
    ;;
  api\ graphql\ *projectsV2*)
    if [ "${GH_MOCK_GRAPHQL_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2; exit 1
    fi
    NODE_COUNT="${GH_MOCK_PROJECTS_NODE_COUNT:-1}"
    PROJ_OWNER="${GH_MOCK_PROJECT_OWNER:-nirecom}"
    PROJ_NUM="${GH_MOCK_PROJECT_NUM:-1}"
    PROJ_ID="${GH_MOCK_PROJECT_ID:-PVT_mock123}"
    case "$ARGS" in
      *"length == 0 then empty"*|*"{id, number, ownerLogin"*)
        if [ "$NODE_COUNT" -eq 0 ]; then echo ""
        else printf '{"id":"%s","number":%s,"ownerLogin":"%s"}\n' "$PROJ_ID" "$PROJ_NUM" "$PROJ_OWNER"
        fi
        exit 0
        ;;
      *"| length"*)
        echo "$NODE_COUNT"; exit 0
        ;;
      *)
        echo "$NODE_COUNT"; exit 0
        ;;
    esac
    ;;
  api\ graphql\ *fields*|api\ graphql\ *Content\ Date*|api\ graphql\ *projectId*|api\ graphql\ *Status*|api\ graphql\ *SINGLE_SELECT*|api\ graphql\ *fingerprint*|api\ graphql\ *PVTF*)
    if [ "${GH_MOCK_GRAPHQL_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2; exit 1
    fi
    # Dispatch on the --jq filter substring. Each field/option query carries a
    # distinct select(.name == "...") clause; return distinct KNOWN ids so a
    # cold-fetch test can assert exact values (not just RC=0).
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *'"In Progress")'*)
        echo "${GH_MOCK_IN_PROGRESS_OPTION_ID:-opt_mock_inprog}"; exit 0
        ;;
      *'"Todo")'*)
        echo "${GH_MOCK_TODO_OPTION_ID:-opt_mock_todo}"; exit 0
        ;;
      *'"Done")'*)
        echo "${GH_MOCK_DONE_OPTION_ID:-opt_mock_done}"; exit 0
        ;;
      *'"Status")'*|*'"Status" '*|*'== "Status"'*)
        echo "${GH_MOCK_STATUS_FIELD_ID:-PVTF_mock_status}"; exit 0
        ;;
      *'"session-fingerprint")'*|*'session-fingerprint'*)
        echo "${GH_MOCK_FINGERPRINT_FIELD_ID:-PVTF_mock_finger}"; exit 0
        ;;
      *"Content Date"*|*"name == \"Content Date\""*)
        FIELD_ID="${GH_MOCK_CONTENT_DATE_FIELD_ID-PVTF_mock_content_date}"
        echo "$FIELD_ID"; exit 0
        ;;
      *"Status"*|*"status_field"*|*"SINGLE_SELECT"*)
        echo "${GH_MOCK_STATUS_FIELD_ID:-PVTF_mock_status}"; exit 0
        ;;
      *)
        # Generic field query — return content date field id
        FIELD_ID="${GH_MOCK_CONTENT_DATE_FIELD_ID-PVTF_mock_content_date}"
        echo "$FIELD_ID"; exit 0
        ;;
    esac
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2; exit 2
    ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR \
          GH_MOCK_OWNER_REPO GH_MOCK_PROJECTS_NODE_COUNT GH_MOCK_PROJECT_OWNER \
          GH_MOCK_PROJECT_NUM GH_MOCK_PROJECT_ID GH_MOCK_CONTENT_DATE_FIELD_ID \
          GH_MOCK_STATUS_FIELD_ID GH_MOCK_TODO_OPTION_ID \
          GH_MOCK_IN_PROGRESS_OPTION_ID GH_MOCK_DONE_OPTION_ID \
          GH_MOCK_FINGERPRINT_FIELD_ID GH_MOCK_GRAPHQL_FAIL \
          _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM \
          _ISSUE_CREATE_INTERNAL_PROJECT_ID _ISSUE_CREATE_INTERNAL_FIELD_ID \
          RESOLVED_OWNER RESOLVED_PROJECT_NUM RESOLVED_PROJECT_ID \
          RESOLVED_CONTENT_DATE_FIELD_ID RESOLVED_STATUS_FIELD_ID \
          RESOLVED_TODO_OPTION_ID RESOLVED_IN_PROGRESS_OPTION_ID \
          RESOLVED_DONE_OPTION_ID RESOLVED_FINGERPRINT_FIELD_ID 2>/dev/null || true
}

# Helper: run resolver in a subshell and capture RESOLVED_* + RC
run_resolver() {
    local stderr_file="${1:-/dev/null}"
    bash -c "
        source '$TARGET' >/dev/null 2>&1 || { echo 'RC=99'; exit 99; }
        if resolve_project_for_repo; then RC=0; else RC=\$?; fi
        printf 'RESOLVED_OWNER=%s\n'                       \"\${RESOLVED_OWNER:-}\"
        printf 'RESOLVED_PROJECT_NUM=%s\n'                 \"\${RESOLVED_PROJECT_NUM:-}\"
        printf 'RESOLVED_PROJECT_ID=%s\n'                  \"\${RESOLVED_PROJECT_ID:-}\"
        printf 'RESOLVED_CONTENT_DATE_FIELD_ID=%s\n'       \"\${RESOLVED_CONTENT_DATE_FIELD_ID:-}\"
        printf 'RESOLVED_STATUS_FIELD_ID=%s\n'             \"\${RESOLVED_STATUS_FIELD_ID:-}\"
        printf 'RESOLVED_TODO_OPTION_ID=%s\n'              \"\${RESOLVED_TODO_OPTION_ID:-}\"
        printf 'RESOLVED_IN_PROGRESS_OPTION_ID=%s\n'       \"\${RESOLVED_IN_PROGRESS_OPTION_ID:-}\"
        printf 'RESOLVED_DONE_OPTION_ID=%s\n'              \"\${RESOLVED_DONE_OPTION_ID:-}\"
        printf 'RESOLVED_FINGERPRINT_FIELD_ID=%s\n'        \"\${RESOLVED_FINGERPRINT_FIELD_ID:-}\"
        printf 'RC=%s\n' \"\$RC\"
    " 2>"$stderr_file"
}

# get_field / pass / fail / AGENTS_DIR provided by _lib.sh.

# ===========================================================================
# TSV parser / schema-guard table (C7: table-driven per test-design.md).
# Each row: name | setup_kind | expect
#   setup_kind writes a cache row/file for key "nirecom/agents":
#     5col | 9col | 3col | empty-file | blank-lines | 10col-trailingblank |
#     10col-dup | 10col-emptystatus | 10col-emptyid
#   expect:
#     miss            → resolver must re-fetch (api graphql called)
#     hit:<ID>        → cache hit, no graphql, RESOLVED_PROJECT_ID == <ID>
#     hit-emptystatus:<ID> → hit, no graphql, RESOLVED_PROJECT_ID == <ID>,
#                            RESOLVED_STATUS_FIELD_ID empty
# Contract observed in resolve-project.sh: lookup is
# `awk -F'\t' '$1==key {print; exit}'` (first match wins, blank lines never
# match a non-empty key); post-#1340 guard requires exactly 10 fields AND
# non-empty cols 2/3/4. Empty cols 5-10 are tolerated.
#
# Two variants are asserted PER THE ACTUAL GUARD, not a fabricated stricter
# contract: the guard's required-field check is `[ -n "$col" ]` — non-emptiness
# ONLY, with NO numeric validation and NO whitespace trimming/validation.
# Therefore:
#   - 10col-nonnumeric-num: col3 = "abc" (non-numeric) → non-empty → HIT is correct.
#   - 10col-wsonly-owner: col2 = " " (whitespace-only) → `[ -n " " ]` is TRUE in
#     bash → non-empty → HIT is correct.
# Asserting a MISS here would encode a contract the source will never implement
# (a forever-RED test). An EMPTY required field, by contrast, IS a miss — see
# emptyid-required-miss.
# ===========================================================================
write_cache_case() {
    # $1=setup_kind ; writes $CACHE_FILE
    local kind="$1"
    mkdir -p "$(dirname "$CACHE_FILE")"
    case "$kind" in
      5col)
        printf 'nirecom/agents\tcached-owner\t99\tPVT_cached\tPVTF_cached_field\n' > "$CACHE_FILE" ;;
      9col)
        printf 'nirecom/agents\towner\t1\tPVT_id\tfield\tstatus_id\ttodo_id\tinprog_id\tdone_id\n' > "$CACHE_FILE" ;;
      3col)
        printf 'nirecom/agents\tincomplete\n' > "$CACHE_FILE" ;;
      empty-file)
        : > "$CACHE_FILE" ;;
      blank-lines)
        printf '\n\n\n' > "$CACHE_FILE" ;;
      10col-trailingblank)
        printf 'nirecom/agents\towner\t7\tPVT_hit\tcontent\tstatus_f\ttodo_f\tinprog_f\tdone_f\tfinger_f\n\n' > "$CACHE_FILE" ;;
      10col-dup)
        printf 'nirecom/agents\towner\t1\tPVT_first\tc\ts\tt\ti\td\tf\n'  > "$CACHE_FILE"
        printf 'nirecom/agents\towner\t2\tPVT_second\tc\ts\tt\ti\td\tf\n' >> "$CACHE_FILE" ;;
      10col-emptystatus)
        printf 'nirecom/agents\towner\t3\tPVT_emptystatus\tcontent\t\ttodo_f\tinprog_f\tdone_f\tfinger_f\n' > "$CACHE_FILE" ;;
      10col-emptyid)
        printf 'nirecom/agents\towner\t3\t\tcontent\tstatus_f\ttodo_f\tinprog_f\tdone_f\tfinger_f\n' > "$CACHE_FILE" ;;
      10col-nonnumeric-num)
        # col3 (project_num) is non-numeric. The guard checks NON-EMPTINESS only
        # (no numeric validation), so this is a HIT — matches the real guard.
        printf 'nirecom/agents\towner\tabc\tPVT_nonnum\tcontent\tstatus_f\ttodo_f\tinprog_f\tdone_f\tfinger_f\n' > "$CACHE_FILE" ;;
      10col-wsonly-owner)
        # col2 (project_owner, required) is whitespace-only (a single space).
        # `[ -n " " ]` is TRUE in bash, so the non-empty guard treats it as a
        # HIT — matches the real guard (no whitespace trimming/validation).
        printf 'nirecom/agents\t \t5\tPVT_wsowner\tcontent\tstatus_f\ttodo_f\tinprog_f\tdone_f\tfinger_f\n' > "$CACHE_FILE" ;;
      col7-retain)
        printf 'nirecom/agents\towner\t1\tPVT_id\tcontent\tstatus_f\ttodo_f\tinprog_f\tdone_f\tfinger_f\n' > "$CACHE_FILE" ;;
      *) echo "unknown setup_kind: $kind" >&2; return 1 ;;
    esac
}

while IFS='|' read -r name setup_kind expect; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; setup_kind="${setup_kind//[[:space:]]/}"; expect="${expect//[[:space:]]/}"
    setup_mock
    CACHE_FILE="$WORKFLOW_PLANS_DIR/cache/project-resolve.tsv"
    write_cache_case "$setup_kind"
    STDERR_FILE="$TMP/tst-$name.log"
    OUT=$(bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
    RC=$(get_field "$OUT" RC)
    R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
    R_STATUS=$(get_field "$OUT" RESOLVED_STATUS_FIELD_ID)
    GRAPHQL_CALLED=0
    grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && GRAPHQL_CALLED=1
    case "$expect" in
      miss)
        if [ "$RC" = "0" ] && [ "$GRAPHQL_CALLED" = "1" ]; then
            pass "TS-table[$name]: $setup_kind → miss → re-fetch (graphql called)"
        else
            fail "TS-table[$name]: rc=$RC graphql=$GRAPHQL_CALLED (expected miss: rc=0, graphql=1)"
        fi
        ;;
      hit:*)
        want_id="${expect#hit:}"
        if [ "$RC" = "0" ] && [ "$GRAPHQL_CALLED" = "0" ] && [ "$R_ID" = "$want_id" ]; then
            pass "TS-table[$name]: $setup_kind → hit id=$want_id, no graphql"
        else
            fail "TS-table[$name]: rc=$RC id=$R_ID graphql=$GRAPHQL_CALLED (expected hit id=$want_id, no graphql)"
        fi
        ;;
      hit-emptystatus:*)
        want_id="${expect#hit-emptystatus:}"
        if [ "$RC" = "0" ] && [ "$GRAPHQL_CALLED" = "0" ] && [ "$R_ID" = "$want_id" ] && [ -z "$R_STATUS" ]; then
            pass "TS-table[$name]: $setup_kind → hit id=$want_id with empty status, no graphql"
        else
            fail "TS-table[$name]: rc=$RC id=$R_ID status='$R_STATUS' graphql=$GRAPHQL_CALLED (expected hit id=$want_id, status empty, no graphql)"
        fi
        ;;
      *) fail "TS-table[$name]: unknown expect='$expect'" ;;
    esac
    teardown_mock
done <<'TABLE'
5col-miss              | 5col                  | miss
9col-miss              | 9col                  | miss
3col-miss              | 3col                  | miss
empty-file-miss        | empty-file            | miss
blank-lines-miss       | blank-lines           | miss
trailingblank-hit      | 10col-trailingblank   | hit:PVT_hit
duplicate-first-wins   | 10col-dup             | hit:PVT_first
emptystatus-hit        | 10col-emptystatus     | hit-emptystatus:PVT_emptystatus
emptyid-required-miss  | 10col-emptyid         | miss
col7-retention-hit     | col7-retain           | hit:PVT_id
nonnumeric-num-hit     | 10col-nonnumeric-num  | hit:PVT_nonnum
wsonly-owner-hit       | 10col-wsonly-owner    | hit:PVT_wsowner
TABLE

# ===========================================================================
# TS-4: 10-column cache row → hit; all 5 new RESOLVED_* set; NO graphql call
# ===========================================================================
setup_mock
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
# Exactly 10 columns
printf 'nirecom/agents\tcached-owner\t99\tPVT_cached\tPVTF_content\tPVTF_status\tPVTF_todo\tPVTF_inprog\tPVTF_done\tPVTF_finger\n' > "$CACHE_FILE"
STDERR_FILE="$TMP/ts4-stderr.log"
OUT=$(bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_STATUS=$(get_field "$OUT" RESOLVED_STATUS_FIELD_ID)
R_TODO=$(get_field "$OUT" RESOLVED_TODO_OPTION_ID)
R_INPROG=$(get_field "$OUT" RESOLVED_IN_PROGRESS_OPTION_ID)
R_DONE=$(get_field "$OUT" RESOLVED_DONE_OPTION_ID)
R_FINGER=$(get_field "$OUT" RESOLVED_FINGERPRINT_FIELD_ID)
GRAPHQL_CALLED=0
grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && GRAPHQL_CALLED=1
if [ "$RC" = "0" ] \
   && [ "$R_OWNER" = "cached-owner" ] \
   && [ "$R_NUM" = "99" ] \
   && [ "$R_STATUS" = "PVTF_status" ] \
   && [ "$R_TODO" = "PVTF_todo" ] \
   && [ "$R_INPROG" = "PVTF_inprog" ] \
   && [ "$R_DONE" = "PVTF_done" ] \
   && [ "$R_FINGER" = "PVTF_finger" ] \
   && [ "$GRAPHQL_CALLED" = "0" ]; then
    pass "TS-4: 10-col cache hit → all 5 new RESOLVED_* set, NO graphql call"
else
    fail "TS-4: rc=$RC owner=$R_OWNER num=$R_NUM status=$R_STATUS todo=$R_TODO inprog=$R_INPROG done=$R_DONE finger=$R_FINGER graphql=$GRAPHQL_CALLED"
fi
teardown_mock

# ===========================================================================
# TS-5: cold fetch → EXACT known field/option IDs (C1: no vacuous RC=0 pass).
# The GraphQL mock returns distinct known IDs per field/option; assert each
# RESOLVED_* equals its known value. RED now: source populates none of them.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_OWNER="cold-owner"
export GH_MOCK_PROJECT_NUM=42
export GH_MOCK_PROJECT_ID="PVT_cold"
export GH_MOCK_CONTENT_DATE_FIELD_ID="PVTF_cold_content"
export GH_MOCK_STATUS_FIELD_ID="PVTF_cold_status"
export GH_MOCK_TODO_OPTION_ID="opt_cold_todo"
export GH_MOCK_IN_PROGRESS_OPTION_ID="opt_cold_inprog"
export GH_MOCK_DONE_OPTION_ID="opt_cold_done"
export GH_MOCK_FINGERPRINT_FIELD_ID="PVTF_cold_finger"
STDERR_FILE="$TMP/ts5-stderr.log"
OUT=$(bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_STATUS=$(get_field "$OUT" RESOLVED_STATUS_FIELD_ID)
R_TODO=$(get_field "$OUT" RESOLVED_TODO_OPTION_ID)
R_INPROG=$(get_field "$OUT" RESOLVED_IN_PROGRESS_OPTION_ID)
R_DONE=$(get_field "$OUT" RESOLVED_DONE_OPTION_ID)
R_FINGER=$(get_field "$OUT" RESOLVED_FINGERPRINT_FIELD_ID)
if [ "$RC" = "0" ] \
   && [ "$R_STATUS" = "PVTF_cold_status" ] \
   && [ "$R_TODO" = "opt_cold_todo" ] \
   && [ "$R_INPROG" = "opt_cold_inprog" ] \
   && [ "$R_DONE" = "opt_cold_done" ] \
   && [ "$R_FINGER" = "PVTF_cold_finger" ]; then
    pass "TS-5: cold fetch → all 5 new RESOLVED_* set to EXACT known mock IDs"
else
    fail "TS-5: rc=$RC status=$R_STATUS todo=$R_TODO inprog=$R_INPROG done=$R_DONE finger=$R_FINGER (expected exact cold-* IDs) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TS-6: cache write after cold fetch → exactly 10 cols, cols 1-5 known,
# cols 6-10 = the EXACT field/option IDs the mock returned (C1: no vacuous
# column-count-only pass). RED now: source writes 5-col rows without new IDs.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_OWNER="nirecom"
export GH_MOCK_PROJECT_NUM=1
export GH_MOCK_PROJECT_ID="PVT_mock123"
export GH_MOCK_CONTENT_DATE_FIELD_ID="PVTF_mock_content_date"
export GH_MOCK_STATUS_FIELD_ID="PVTF_w_status"
export GH_MOCK_TODO_OPTION_ID="opt_w_todo"
export GH_MOCK_IN_PROGRESS_OPTION_ID="opt_w_inprog"
export GH_MOCK_DONE_OPTION_ID="opt_w_done"
export GH_MOCK_FINGERPRINT_FIELD_ID="PVTF_w_finger"
CACHE_FILE="$WORKFLOW_PLANS_DIR/cache/project-resolve.tsv"
STDERR_FILE="$TMP/ts6-stderr.log"
bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'" >/dev/null
if [ -f "$CACHE_FILE" ]; then
    ROW=$(awk -F'\t' '$1=="nirecom/agents"' "$CACHE_FILE" | head -1)
    COL_COUNT=$(printf '%s' "$ROW" | awk -F'\t' '{print NF}')
    C1=$(printf '%s' "$ROW" | cut -f1);  C2=$(printf '%s' "$ROW" | cut -f2)
    C3=$(printf '%s' "$ROW" | cut -f3);  C4=$(printf '%s' "$ROW" | cut -f4)
    C5=$(printf '%s' "$ROW" | cut -f5);  C6=$(printf '%s' "$ROW" | cut -f6)
    C7=$(printf '%s' "$ROW" | cut -f7);  C8=$(printf '%s' "$ROW" | cut -f8)
    C9=$(printf '%s' "$ROW" | cut -f9);  C10=$(printf '%s' "$ROW" | cut -f10)
    if [ "$COL_COUNT" = "10" ] \
       && [ "$C1" = "nirecom/agents" ] && [ "$C2" = "nirecom" ] \
       && [ "$C3" = "1" ] && [ "$C4" = "PVT_mock123" ] \
       && [ "$C5" = "PVTF_mock_content_date" ] \
       && [ "$C6" = "PVTF_w_status" ] && [ "$C7" = "opt_w_todo" ] \
       && [ "$C8" = "opt_w_inprog" ] && [ "$C9" = "opt_w_done" ] \
       && [ "$C10" = "PVTF_w_finger" ]; then
        pass "TS-6: cache write → 10 cols, cols 6-10 = exact field/option IDs"
    else
        fail "TS-6: cols=$COL_COUNT c6=$C6 c7=$C7 c8=$C8 c9=$C9 c10=$C10 (expected exact w-* IDs) row='$ROW'"
    fi
else
    fail "TS-6: cache file not created after cold fetch"
fi
teardown_mock

# ===========================================================================
# TS-7: col7 retention — RESOLVED_TODO_OPTION_ID populated from 10-col cache
# even though no runtime verb consumes it. Exact-value assertion (complements
# the table's col7-retention-hit row, which only checks PROJECT_ID).
# ===========================================================================
setup_mock
CACHE_FILE="$WORKFLOW_PLANS_DIR/cache/project-resolve.tsv"
mkdir -p "$(dirname "$CACHE_FILE")"
printf 'nirecom/agents\towner\t1\tPVT_id\tcontent\tstatus_f\ttodo_f\tinprog_f\tdone_f\tfinger_f\n' > "$CACHE_FILE"
STDERR_FILE="$TMP/ts7-stderr.log"
OUT=$(bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_TODO=$(get_field "$OUT" RESOLVED_TODO_OPTION_ID)
GRAPHQL_CALLED=0
grep -q "api graphql" "$MOCK_LOG" 2>/dev/null && GRAPHQL_CALLED=1
if [ "$RC" = "0" ] && [ "$R_TODO" = "todo_f" ] && [ "$GRAPHQL_CALLED" = "0" ]; then
    pass "TS-7: RESOLVED_TODO_OPTION_ID = todo_f from 10-col cache (col7 retained)"
else
    fail "TS-7: rc=$RC todo=$R_TODO graphql=$GRAPHQL_CALLED (expected rc=0, todo=todo_f, no graphql)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
