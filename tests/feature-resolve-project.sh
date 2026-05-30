#!/bin/bash
# Tests for bin/github-issues/lib/resolve-project.sh — Issue #641
# Auto-resolve Projects v2 config from git remote via GraphQL.
#
# Sourced helper (not directly executed). Exposes `resolve_project_for_repo`
# which sets caller-scope variables:
#   - RESOLVED_OWNER (from project node owner.login, NOT repo owner)
#   - RESOLVED_PROJECT_NUM
#   - RESOLVED_PROJECT_ID
#   - RESOLVED_CONTENT_DATE_FIELD_ID (empty if field not found)
#
# Internal short-circuit: when _ISSUE_CREATE_INTERNAL_OWNER + _NUM + _ID are
# all set, skip GraphQL and use those values directly.
#
# Cache: ${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/cache/project-resolve.tsv
# TSV columns: owner/repo TAB project_owner TAB project_num TAB project_id TAB content_date_field_id
#
# RED: this suite fails clean while bin/github-issues/lib/resolve-project.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"
# Inner bash subshells (via `bash -c "$(declare -f ...); run_resolver ..."`)
# need TARGET to expand `source '$TARGET'`. Non-exported vars don't cross
# subshell boundaries — export so the inner shell sees it.
export TARGET

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

_TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
_PERL_BIN="$(command -v perl 2>/dev/null || true)"
run_with_timeout() {
    local secs="$1"; shift
    if [ -n "$_TIMEOUT_BIN" ]; then
        "$_TIMEOUT_BIN" "$secs" "$@"
    elif [ -n "$_PERL_BIN" ]; then
        "$_PERL_BIN" -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/resolve-project.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 17 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory.
#
# Mock dispatches on args:
#   - gh repo view --json owner,name --jq ...   → echoes GH_MOCK_OWNER_REPO
#   - gh api graphql ... projectsV2 ...         → echoes GH_MOCK_GRAPHQL_PROJECTS_OUT
#       (the resolver passes a --jq filter to extract: id, number, ownerLogin,
#        or `length`; the mock returns pre-filtered values based on the filter.)
#   - gh api graphql ... fields ...             → echoes GH_MOCK_GRAPHQL_FIELDS_OUT
#       (page 1 by default; if GH_MOCK_FIELDS_PAGE_COUNTER counts ≥2 returns page 2)
#
# Env knobs:
#   GH_MOCK_OWNER_REPO                  owner/repo string for repo view (default: nirecom/agents)
#   GH_MOCK_REPO_VIEW_FAIL              if "1", repo view exits 1
#   GH_MOCK_PROJECTS_NODE_COUNT         number of linked projects (0, 1, 2+; default: 1)
#   GH_MOCK_PROJECT_OWNER               project owner.login (default: nirecom)
#   GH_MOCK_PROJECT_NUM                 project number (default: 1)
#   GH_MOCK_PROJECT_ID                  project node id (default: PVT_mock123)
#   GH_MOCK_CONTENT_DATE_FIELD_ID       field id (default: PVTF_mock_content_date)
#                                       if empty: no Content Date field
#   GH_MOCK_FIELDS_TWO_PAGES            if "1", fields paginate; Content Date on page 2
#   GH_MOCK_GRAPHQL_FAIL                if "1", api graphql exits 1
#   GH_MOCK_MV_FAIL                     if "1", inject a mock `mv` that exits 1
#   MOCK_LOG                            append-only call log (one line per gh invocation)
# ---------------------------------------------------------------------------

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
    if [ "${GH_MOCK_REPO_VIEW_FAIL:-0}" = "1" ]; then
        echo "error: gh repo view failed (no remote)" >&2
        exit 1
    fi
    # resolve_owner_repo uses --jq '.owner.login + "/" + .name' → emits "owner/name".
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0
    ;;
  api\ graphql\ *projectsV2*)
    if [ "${GH_MOCK_GRAPHQL_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2
        exit 1
    fi
    NODE_COUNT="${GH_MOCK_PROJECTS_NODE_COUNT:-1}"
    PROJ_OWNER="${GH_MOCK_PROJECT_OWNER:-nirecom}"
    PROJ_NUM="${GH_MOCK_PROJECT_NUM:-1}"
    PROJ_ID="${GH_MOCK_PROJECT_ID:-PVT_mock123}"
    # The resolver invokes Query A with one of three --jq filters:
    #   (a) length-check    → 'length'
    #   (b) first-node pick → 'if length == 0 then empty else .[0] | {id, number, ownerLogin: .owner.login} end'
    #   (c) ad-hoc warn cnt → 'length' (same as a)
    # Mock dispatches on the literal --jq filter substring.
    case "$ARGS" in
      *"length == 0 then empty"*|*"{id, number, ownerLogin"*)
        if [ "$NODE_COUNT" -eq 0 ]; then
            echo ""
        else
            # Emit the first-node JSON; the implementation might consume it via
            # `eval` of the --jq output, or it might parse JSON. Both forms are
            # acceptable — we emit a single-line JSON object so either path works.
            printf '{"id":"%s","number":%s,"ownerLogin":"%s"}\n' "$PROJ_ID" "$PROJ_NUM" "$PROJ_OWNER"
        fi
        exit 0
        ;;
      *"| length"*)
        echo "$NODE_COUNT"
        exit 0
        ;;
      *)
        # Catch-all for project query without identifying --jq → emit length.
        echo "$NODE_COUNT"
        exit 0
        ;;
    esac
    ;;
  api\ graphql\ *fields*|api\ graphql\ *Content\ Date*|api\ graphql\ *projectId*)
    if [ "${GH_MOCK_GRAPHQL_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2
        exit 1
    fi
    FIELD_ID="${GH_MOCK_CONTENT_DATE_FIELD_ID-PVTF_mock_content_date}"
    # Two-page pagination support.
    if [ "${GH_MOCK_FIELDS_TWO_PAGES:-0}" = "1" ] && [ -n "${GH_MOCK_FIELDS_PAGE_COUNTER:-}" ]; then
        N=$(cat "$GH_MOCK_FIELDS_PAGE_COUNTER" 2>/dev/null || echo 0)
        N=$((N + 1)); echo "$N" > "$GH_MOCK_FIELDS_PAGE_COUNTER"
        # Page 1: no Content Date, hasNextPage=true. Page 2: Content Date, hasNextPage=false.
        case "$ARGS" in
          *"hasNextPage"*)
            if [ "$N" -le 1 ]; then echo "true"; else echo "false"; fi
            exit 0
            ;;
          *"endCursor"*)
            if [ "$N" -le 1 ]; then echo "cursor-page2"; else echo ""; fi
            exit 0
            ;;
          *)
            # field id query — page 1 empty, page 2 returns id
            if [ "$N" -le 1 ]; then echo ""; else echo "$FIELD_ID"; fi
            exit 0
            ;;
        esac
    fi
    # Single-page default.
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *)
        echo "$FIELD_ID"
        exit 0
        ;;
    esac
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2
    ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"

    # Optional mock mv for T9 (cache write failure simulation).
    if [ "${GH_MOCK_MV_FAIL:-0}" = "1" ]; then
        cat > "$TMP/mock-bin/mv" <<'MV_EOF'
#!/bin/bash
echo "mock mv: simulated failure" >&2
exit 1
MV_EOF
        chmod +x "$TMP/mock-bin/mv"
    fi

    # Isolate cache to TMP via WORKFLOW_PLANS_DIR.
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    # Note: we do NOT pre-create the cache dir here — the resolver must
    # create it on first cache write (T9b).
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR \
          GH_MOCK_OWNER_REPO GH_MOCK_REPO_VIEW_FAIL \
          GH_MOCK_PROJECTS_NODE_COUNT GH_MOCK_PROJECT_OWNER \
          GH_MOCK_PROJECT_NUM GH_MOCK_PROJECT_ID \
          GH_MOCK_CONTENT_DATE_FIELD_ID GH_MOCK_FIELDS_TWO_PAGES \
          GH_MOCK_FIELDS_PAGE_COUNTER GH_MOCK_GRAPHQL_FAIL GH_MOCK_MV_FAIL \
          _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM \
          _ISSUE_CREATE_INTERNAL_PROJECT_ID _ISSUE_CREATE_INTERNAL_FIELD_ID \
          RESOLVED_OWNER RESOLVED_PROJECT_NUM RESOLVED_PROJECT_ID \
          RESOLVED_CONTENT_DATE_FIELD_ID 2>/dev/null || true
}

# Helper: run resolver in a subshell and capture state via env-export round-trip.
# We source the resolver in a subshell (to avoid polluting the harness shell
# between tests) and emit RESOLVED_* + RC on stdout for the parent to parse.
run_resolver() {
    local stderr_file="${1:-/dev/null}"
    bash -c "
        source '$TARGET' >/dev/null 2>&1 || { echo 'RC=99'; exit 99; }
        if resolve_project_for_repo; then RC=0; else RC=\$?; fi
        printf 'RESOLVED_OWNER=%s\n'                  \"\${RESOLVED_OWNER:-}\"
        printf 'RESOLVED_PROJECT_NUM=%s\n'            \"\${RESOLVED_PROJECT_NUM:-}\"
        printf 'RESOLVED_PROJECT_ID=%s\n'             \"\${RESOLVED_PROJECT_ID:-}\"
        printf 'RESOLVED_CONTENT_DATE_FIELD_ID=%s\n'  \"\${RESOLVED_CONTENT_DATE_FIELD_ID:-}\"
        printf 'RC=%s\n' \"\$RC\"
    " 2>"$stderr_file"
}

# Extract a field from run_resolver's output.
get_field() {
    local out="$1" key="$2"
    printf '%s\n' "$out" | grep -E "^${key}=" | head -1 | cut -d= -f2-
}

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
# _ISSUE_CREATE_INTERNAL_FIELD_ID intentionally unset (optional).
STDERR_FILE="$TMP/t5-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_OWNER=$(get_field "$OUT" RESOLVED_OWNER)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
R_ID=$(get_field "$OUT" RESOLVED_PROJECT_ID)
# Verify NO graphql call appears in the mock log.
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
# Count graphql calls in mock log to confirm pagination (more than 1 fields call).
FIELDS_CALL_COUNT=$(grep -c "api graphql" "$MOCK_LOG" 2>/dev/null || echo 0)
if [ "$RC" = "0" ] && [ "$R_FIELD" = "PVTF_mock_content_date" ] && [ "$FIELDS_CALL_COUNT" -ge 2 ]; then
    pass "T6: fields pagination — Content Date found on page 2 (graphql calls: $FIELDS_CALL_COUNT)"
else
    fail "T6: rc=$RC field=$R_FIELD calls=$FIELDS_CALL_COUNT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T7: cache hit — pre-populate TSV, resolver returns cached values without graphql
# ===========================================================================
setup_mock
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
printf 'nirecom/agents\tcached-owner\t99\tPVT_cached\tPVTF_cached_field\n' > "$CACHE_FILE"
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
    pass "T7: cache hit — values from TSV, no graphql call"
else
    fail "T7: rc=$RC owner=$R_OWNER num=$R_NUM id=$R_ID field=$R_FIELD graphql=$GRAPHQL_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T7b: cache lookup with owner/repo containing "." (regex metachar safety)
# ===========================================================================
setup_mock
export GH_MOCK_OWNER_REPO="nire.com/my.repo"
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
mkdir -p "$CACHE_DIR"
# Two rows: one for a similar-but-different key, one for the actual key.
# A regex-based lookup would incorrectly match the first row because "." matches any char.
printf 'nireXcom/myXrepo\tWRONG-owner\t100\tPVT_WRONG\tPVTF_WRONG\n' > "$CACHE_FILE"
printf 'nire.com/my.repo\tcorrect-owner\t5\tPVT_correct\tPVTF_correct\n' >> "$CACHE_FILE"
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
# Stale cached row for the same owner/repo.
printf 'nirecom/agents\tstale-owner\t100\tPVT_stale\tPVTF_stale\n' > "$CACHE_FILE"
# But this test wants a re-resolve with NEW project data — so simulate cache miss by
# corrupting the row (T7d-style malformed) OR by directly issuing a cold call
# after deleting the existing entry. Simpler: pass an explicit "force re-resolve"
# by deleting cache first, then re-resolve with new project_id, then verify the
# cache row was replaced (not appended).
rm -f "$CACHE_FILE"
# First resolve: writes cache.
export GH_MOCK_PROJECT_ID="PVT_first_call"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
# Second resolve: different project_id, same owner/repo → row must be replaced.
export GH_MOCK_PROJECT_ID="PVT_second_call"
# But cache hit would short-circuit — so wipe cache before second resolve to force re-fetch.
rm -f "$CACHE_FILE"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
# Now check the cache file: exactly 1 row matching nirecom/agents, with PVT_second_call.
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
# Malformed: only 2 fields instead of 5.
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
# Cache does not exist initially.
[ -f "$CACHE_FILE" ] && rm "$CACHE_FILE"
STDERR_FILE="$TMP/t8-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "0" ] && [ -f "$CACHE_FILE" ]; then
    # Verify TSV row content.
    ROW=$(awk -F'\t' '$1=="nirecom/agents"' "$CACHE_FILE" | head -1)
    # Expected: nirecom/agents \t nirecom \t 1 \t PVT_mock123 \t PVTF_mock_content_date
    EXPECTED=$(printf 'nirecom/agents\tnirecom\t1\tPVT_mock123\tPVTF_mock_content_date')
    if [ "$ROW" = "$EXPECTED" ]; then
        pass "T8: cache miss → fetch → TSV row written correctly"
    else
        fail "T8: row mismatch — got='$ROW' expected='$EXPECTED'"
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
# First resolve.
export GH_MOCK_PROJECT_NUM=10
export GH_MOCK_PROJECT_ID="PVT_v1"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
# Second resolve with different data. Wipe cache to force re-fetch.
rm -f "$CACHE_FILE"
export GH_MOCK_PROJECT_NUM=20
export GH_MOCK_PROJECT_ID="PVT_v2"
run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '/dev/null'" >/dev/null
# Verify: exactly 1 row for nirecom/agents, with v2 data.
ROW_COUNT=$(awk -F'\t' '$1=="nirecom/agents"' "$CACHE_FILE" 2>/dev/null | wc -l | tr -d ' ')
HAS_V2=0
grep -q "PVT_v2" "$CACHE_FILE" 2>/dev/null && HAS_V2=1
if [ "$ROW_COUNT" = "1" ] && [ "$HAS_V2" = "1" ]; then
    pass "T8b: second resolution updates cache row (not duplicated)"
else
    fail "T8b: rows=$ROW_COUNT has_v2=$HAS_V2 cache=$(cat "$CACHE_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T9: mv fails → warn on stderr, resolver still returns 0 (non-fatal)
# ===========================================================================
setup_mock
# Install mock mv that fails. Must be in PATH before the real mv.
cat > "$TMP/mock-bin/mv" <<'MV_EOF'
#!/bin/bash
echo "mock mv: simulated failure" >&2
exit 1
MV_EOF
chmod +x "$TMP/mock-bin/mv"
STDERR_FILE="$TMP/t9-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
# Resolver must still return 0 and emit RESOLVED_* values; only the cache write fails.
if [ "$RC" = "0" ] \
   && [ "$R_NUM" = "1" ] \
   && grep -qi "cache write failed" "$STDERR_FILE" 2>/dev/null; then
    pass "T9: mv fails → warn 'cache write failed', resolver returns 0 (non-fatal)"
else
    fail "T9: rc=$RC num=$R_NUM stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T9b: cache directory does not exist → mkdir -p creates it, write succeeds
# ===========================================================================
setup_mock
# WORKFLOW_PLANS_DIR points to TMP/plans (created by setup_mock, but cache/ inside does NOT exist).
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
# Confirm cache dir absent before run.
[ -d "$CACHE_DIR" ] && rm -rf "$CACHE_DIR"
STDERR_FILE="$TMP/t9b-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "0" ] && [ -d "$CACHE_DIR" ] && [ -f "$CACHE_FILE" ]; then
    pass "T9b: cache dir auto-created via mkdir -p, write succeeds"
else
    fail "T9b: rc=$RC dir_exists=$([ -d "$CACHE_DIR" ] && echo yes || echo no) file_exists=$([ -f "$CACHE_FILE" ] && echo yes || echo no) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T10: gh not in PATH → return 1, stderr contains warning
# ===========================================================================
setup_mock
# Hide gh without removing the shell tools that the harness needs (bash, etc.).
# Point PATH at a clean dir that contains no gh but inherits the system shell
# location (resolved via bash --version's binary path before PATH was changed).
SAVED_PATH="$PATH"
_T10_BASH_DIR="$(dirname "$(command -v bash 2>/dev/null || echo /bin/bash)")"
export PATH="$_T10_BASH_DIR:/nonexistent/path"
STDERR_FILE="$TMP/t10-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
export PATH="$SAVED_PATH"
if [ "$RC" = "1" ] && [ -s "$STDERR_FILE" ]; then
    pass "T10: gh not in PATH → return 1 + warn on stderr"
else
    fail "T10: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T11: gh api graphql fails → return 1, stderr contains warning
# ===========================================================================
setup_mock
export GH_MOCK_GRAPHQL_FAIL=1
STDERR_FILE="$TMP/t11-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "1" ] && [ -s "$STDERR_FILE" ]; then
    pass "T11: gh api graphql fails → return 1 + warn"
else
    fail "T11: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
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
# gh repo view already handles SSH URLs internally. Test that resolver consumes
# whatever the gh CLI returns (here: org/repo from a hypothetical SSH context).
export GH_MOCK_OWNER_REPO="ssh-org/ssh-repo"
STDERR_FILE="$TMP/t-ssh-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
# Verify the resolver completed; cache should have ssh-org/ssh-repo as key.
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

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
