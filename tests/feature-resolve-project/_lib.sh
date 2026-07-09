#!/bin/bash
# tests/feature-resolve-project/_lib.sh — shared scaffolding
#
# Sourced by each split file (via a BASH_SOURCE-relative path) so they can also
# run standalone. Provides the scaffolding common to all split files:
#   - AGENTS_DIR + TARGET constants
#   - PASS / FAIL counters and pass / fail helpers
#   - run_with_timeout wrapper
#   - get_field (extract KEY=value from a RESOLVED_* round-trip block)
#   - setup_mock / teardown_mock / run_resolver helpers (verbatim from original)
#   - finish() — prints "Results: N passed, M failed" and exits
#
# NOT a test file: no # Tests:/# Tags: frontmatter; excluded from the
# dispatcher's SPLIT_GROUPS.
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_RESOLVE_PROJECT_LIB_SOURCED:-}" ]; then
    return 0
fi
_RESOLVE_PROJECT_LIB_SOURCED=1

set -u

# Repo root, resolved relative to this lib (tests/feature-resolve-project/).
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"
# Inner bash subshells need TARGET to expand `source '$TARGET'`.
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

# ---------------------------------------------------------------------------
# Inline gh mock factory (verbatim from feature-resolve-project.sh).
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
    case "$ARGS" in
      *"length == 0 then empty"*|*"{id, number, ownerLogin"*)
        if [ "$NODE_COUNT" -eq 0 ]; then
            echo ""
        else
            printf '{"id":"%s","number":%s,"ownerLogin":"%s"}\n' "$PROJ_ID" "$PROJ_NUM" "$PROJ_OWNER"
        fi
        exit 0
        ;;
      *"| length"*)
        echo "$NODE_COUNT"
        exit 0
        ;;
      *)
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
    if [ "${GH_MOCK_FIELDS_TWO_PAGES:-0}" = "1" ] && [ -n "${GH_MOCK_FIELDS_PAGE_COUNTER:-}" ]; then
        N=$(cat "$GH_MOCK_FIELDS_PAGE_COUNTER" 2>/dev/null || echo 0)
        N=$((N + 1)); echo "$N" > "$GH_MOCK_FIELDS_PAGE_COUNTER"
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
            if [ "$N" -le 1 ]; then echo ""; else echo "$FIELD_ID"; fi
            exit 0
            ;;
        esac
    fi
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

    if [ "${GH_MOCK_MV_FAIL:-0}" = "1" ]; then
        cat > "$TMP/mock-bin/mv" <<'MV_EOF'
#!/bin/bash
echo "mock mv: simulated failure" >&2
exit 1
MV_EOF
        chmod +x "$TMP/mock-bin/mv"
    fi

    export WORKFLOW_PLANS_DIR="$TMP/plans"
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
          RESOLVED_CONTENT_DATE_FIELD_ID RESOLVED_STATUS_FIELD_ID \
          RESOLVED_TODO_OPTION_ID RESOLVED_IN_PROGRESS_OPTION_ID \
          RESOLVED_DONE_OPTION_ID RESOLVED_FINGERPRINT_FIELD_ID 2>/dev/null || true
}

# Helper: run resolver in a subshell and capture state via env-export round-trip.
run_resolver() {
    local stderr_file="${1:-/dev/null}"
    bash -c "
        source '$TARGET' >/dev/null 2>&1 || { echo 'RC=99'; exit 99; }
        if resolve_project_for_repo; then RC=0; else RC=\$?; fi
        printf 'RESOLVED_OWNER=%s\n'                  \"\${RESOLVED_OWNER:-}\"
        printf 'RESOLVED_PROJECT_NUM=%s\n'            \"\${RESOLVED_PROJECT_NUM:-}\"
        printf 'RESOLVED_PROJECT_ID=%s\n'             \"\${RESOLVED_PROJECT_ID:-}\"
        printf 'RESOLVED_CONTENT_DATE_FIELD_ID=%s\n'  \"\${RESOLVED_CONTENT_DATE_FIELD_ID:-}\"
        printf 'RESOLVED_STATUS_FIELD_ID=%s\n'        \"\${RESOLVED_STATUS_FIELD_ID:-}\"
        printf 'RESOLVED_TODO_OPTION_ID=%s\n'         \"\${RESOLVED_TODO_OPTION_ID:-}\"
        printf 'RESOLVED_IN_PROGRESS_OPTION_ID=%s\n'  \"\${RESOLVED_IN_PROGRESS_OPTION_ID:-}\"
        printf 'RESOLVED_DONE_OPTION_ID=%s\n'         \"\${RESOLVED_DONE_OPTION_ID:-}\"
        printf 'RESOLVED_FINGERPRINT_FIELD_ID=%s\n'   \"\${RESOLVED_FINGERPRINT_FIELD_ID:-}\"
        printf 'RC=%s\n' \"\$RC\"
    " 2>"$stderr_file"
}

# Extract a field from run_resolver's output.
get_field() {
    local out="$1" key="$2"
    printf '%s\n' "$out" | grep -E "^${key}=" | head -1 | cut -d= -f2-
}

# Print results summary and exit with appropriate code.
finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
