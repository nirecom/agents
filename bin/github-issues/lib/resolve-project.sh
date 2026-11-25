# resolve-project.sh — auto-resolve Projects v2 config from the origin remote (sourced, not executed).
# resolve_project_for_repo [--repo owner/repo] [--require-wip-fields] [--no-cache-read] [--no-cache-write]
#   sets RESOLVED_{OWNER (project owner, not repo owner),PROJECT_NUM,PROJECT_ID,CONTENT_DATE_FIELD_ID,
#   STATUS_FIELD_ID,TODO/IN_PROGRESS/DONE_OPTION_ID,SESSION_ID_FIELD_ID}, RESOLVED_CACHE_KEY (owner/repo;
#   empty on the internal short-circuit) and RESOLVED_STATUS: resolved (rc 0, the repo's only open linked
#   board), no-link, ambiguous (RESOLVED_CANDIDATES "<owner>#<number>" words) or fetch-failed (rc 1).
#   --repo replaces the origin remote. --require-wip-fields: a cached row with an empty WIP column is a miss.
# _ISSUE_CREATE_INTERNAL_{OWNER,PROJECT_NUM,PROJECT_ID} (+ the optional *_FIELD_ID/*_OPTION_ID overrides) skip GraphQL.
# Cache: resolve-project/cache.sh; a hit is re-checked against the open linked boards (resolve-project/linked.sh).
# Set-safety: every external command is guarded, so a failing gh never aborts a `set -e` caller.

_RESOLVE_PROJECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-project/cache.sh
. "$_RESOLVE_PROJECT_LIB_DIR/resolve-project/cache.sh"
# shellcheck source=resolve-project/linked.sh
. "$_RESOLVE_PROJECT_LIB_DIR/resolve-project/linked.sh"
# shellcheck source=session-id-field.sh
. "$_RESOLVE_PROJECT_LIB_DIR/session-id-field.sh"

_resolve_project_clear_board() {
    RESOLVED_OWNER=""
    RESOLVED_PROJECT_NUM=""
    RESOLVED_PROJECT_ID=""
    RESOLVED_CONTENT_DATE_FIELD_ID=""
    RESOLVED_STATUS_FIELD_ID=""
    RESOLVED_TODO_OPTION_ID=""
    RESOLVED_IN_PROGRESS_OPTION_ID=""
    RESOLVED_DONE_OPTION_ID=""
    RESOLVED_SESSION_ID_FIELD_ID=""
}

resolve_project_for_repo() {
    # Always clear before populating so a stale value from a prior call cannot leak through on failure.
    _resolve_project_clear_board
    RESOLVED_CACHE_KEY=""
    RESOLVED_STATUS="fetch-failed"
    RESOLVED_CANDIDATES=""

    local require_wip=0 no_cache_read=0 no_cache_write=0 repo_flag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --require-wip-fields) require_wip=1 ;;
            --no-cache-read) no_cache_read=1 ;;
            --no-cache-write) no_cache_write=1 ;;
            --repo) repo_flag="${2:-}"; shift ;;
            --repo=*) repo_flag="${1#--repo=}" ;;
            *) echo "warn: resolve-project: unknown option '$1' ignored" >&2 ;;
        esac
        shift
    done

    # ---- Internal short-circuit (no cache key, no cache write) ----
    if [ -n "${_ISSUE_CREATE_INTERNAL_OWNER:-}" ] \
       && [ -n "${_ISSUE_CREATE_INTERNAL_PROJECT_NUM:-}" ] \
       && [ -n "${_ISSUE_CREATE_INTERNAL_PROJECT_ID:-}" ]; then
        RESOLVED_OWNER="$_ISSUE_CREATE_INTERNAL_OWNER"
        RESOLVED_PROJECT_NUM="$_ISSUE_CREATE_INTERNAL_PROJECT_NUM"
        RESOLVED_PROJECT_ID="$_ISSUE_CREATE_INTERNAL_PROJECT_ID"
        RESOLVED_CONTENT_DATE_FIELD_ID="${_ISSUE_CREATE_INTERNAL_FIELD_ID:-}"
        RESOLVED_STATUS_FIELD_ID="${_ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID:-}"
        RESOLVED_TODO_OPTION_ID="${_ISSUE_CREATE_INTERNAL_TODO_OPTION_ID:-}"
        RESOLVED_IN_PROGRESS_OPTION_ID="${_ISSUE_CREATE_INTERNAL_IN_PROGRESS_OPTION_ID:-}"
        RESOLVED_DONE_OPTION_ID="${_ISSUE_CREATE_INTERNAL_DONE_OPTION_ID:-}"
        RESOLVED_SESSION_ID_FIELD_ID="${_ISSUE_CREATE_INTERNAL_SESSION_ID_FIELD_ID:-}"
        RESOLVED_STATUS="resolved"
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "warn: resolve-project: gh CLI not found" >&2
        return 1
    fi

    # ---- Owner/repo: --repo, else the ORIGIN remote (#1899) ----
    local script_dir owner_repo
    script_dir="$_RESOLVE_PROJECT_LIB_DIR"
    if [ -n "$repo_flag" ]; then
        if [[ ! "$repo_flag" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]]; then
            echo "warn: resolve-project: --repo '$repo_flag' is not owner/repo" >&2
            return 1
        fi
        owner_repo="$repo_flag"
    else
        # shellcheck source=board-card.sh
        . "$script_dir/board-card.sh"
        if ! owner_repo=$(resolve_owner_repo); then
            echo "warn: resolve-project: could not resolve owner/repo from the origin remote (missing origin, or not a github.com repo)" >&2
            return 1
        fi
        owner_repo=$(printf '%s' "$owner_repo" | tr -d '\r' | head -1)
        if [ -z "$owner_repo" ]; then
            echo "warn: resolve-project: origin remote resolved to an empty owner/repo" >&2
            return 1
        fi
    fi
    RESOLVED_CACHE_KEY="$owner_repo"
    local owner_part="${owner_repo%/*}" repo_part="${owner_repo#*/}"

    # ---- Cache lookup (resolve-project/cache.sh hit rules), then a link re-check of the cached board ----
    local cache_dir cache_file cache_row check_rc
    cache_dir="$(_resolve_project_cache_dir "$script_dir")" || cache_dir=""
    cache_file="${cache_dir:+$cache_dir/project-resolve.tsv}"
    if [ "$no_cache_read" -eq 0 ] \
       && cache_row="$(_resolve_project_read_cache_row "$cache_file" "$owner_repo" "$require_wip")"; then
        local _key _tag
        # Unit separator, not tab: tab is IFS whitespace and would collapse empty columns.
        IFS=$'\x1f' read -r _key RESOLVED_OWNER RESOLVED_PROJECT_NUM RESOLVED_PROJECT_ID \
            RESOLVED_CONTENT_DATE_FIELD_ID RESOLVED_STATUS_FIELD_ID RESOLVED_TODO_OPTION_ID \
            RESOLVED_IN_PROGRESS_OPTION_ID RESOLVED_DONE_OPTION_ID RESOLVED_SESSION_ID_FIELD_ID _tag \
            <<<"${cache_row//$'\t'/$'\x1f'}"
        check_rc=0
        if [[ "$RESOLVED_PROJECT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
            _resolve_project_link_check "$owner_part" "$repo_part" "$RESOLVED_PROJECT_ID" || check_rc=$?
        else
            check_rc=2  # pid outside the id charset: never embedded in a query; treated as a failed confirmation
        fi
        if [ "$check_rc" -eq 2 ]; then
            echo "warn: resolve-project: link check of cached board $RESOLVED_PROJECT_ID failed; using the cached board" >&2
        fi
        if [ "$check_rc" -ne 1 ]; then
            RESOLVED_STATUS="resolved"
            return 0
        fi
        echo "info: cached board $RESOLVED_PROJECT_ID is no longer the only open linked board of $owner_repo; re-resolving" >&2
        resolve_project_drop_cache_row "$owner_repo" || true
        _resolve_project_clear_board
    fi

    # ---- Query A: the repo's open linked boards (exactly one resolves) ----
    _resolve_project_query_linked "$owner_part" "$repo_part" || return 1
    local pid="$_RP_LINKED_PID" pnum="$_RP_LINKED_PNUM" powner="$_RP_LINKED_POWNER"

    # ---- Query B: paginate fields, locate "Content Date" (DATE dataType) ----
    # Two query bodies (endCursor / field id) keep the test mock's substring dispatch unambiguous.
    # Ends when the field is found, the cursor stops advancing, or the guard is hit.
    local query_cursor query_field_id
    query_cursor='query($projectId: ID!, $after: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 50, after: $after) { pageInfo { hasNextPage endCursor } }
    }
  }
}'
    query_field_id='query($projectId: ID!, $after: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 50, after: $after) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name dataType }
        }
      }
    }
  }
}'

    local content_date_id="" cursor="" guard=0 page_cursor page_field
    local -a after_args
    while [ "$guard" -lt 20 ]; do
        guard=$((guard + 1))
        after_args=()
        [ -n "$cursor" ] && after_args=(-F after="$cursor")

        # endCursor advance for the NEXT page (empty on the final page).
        page_cursor=$(gh api graphql \
            -F projectId="$pid" ${after_args[@]+"${after_args[@]}"} \
            --jq '.data.node.fields.pageInfo.endCursor // ""' \
            -f query="$query_cursor" 2>/dev/null) || page_cursor=""
        page_cursor=$(printf '%s' "$page_cursor" | tr -d '\r' | head -1)

        # Field id lookup against the same page.
        page_field=$(gh api graphql \
            -F projectId="$pid" ${after_args[@]+"${after_args[@]}"} \
            --jq '[.data.node.fields.nodes[]? | select(.name == "Content Date" and .dataType == "DATE") | .id] | first // ""' \
            -f query="$query_field_id" 2>/dev/null) || page_field=""
        page_field=$(printf '%s' "$page_field" | tr -d '\r' | head -1)
        if [ -n "$page_field" ]; then
            content_date_id="$page_field"
            break
        fi

        # No more pages — exit without finding.
        if [ -z "$page_cursor" ]; then
            break
        fi
        cursor="$page_cursor"
    done

    # ---- Query C: Status field + options + session-id field ids ----
    # Warn-only: a new project may not have these fields yet (/migrate-tracker creates them); missing
    # ids are cached as empty columns. First 50 fields only: a later session-id is picked up by `set`.
    local field_query
    field_query='query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 50) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name }
          ... on ProjectV2SingleSelectField {
            id name
            options { id name }
          }
        }
      }
    }
  }
}'
    local status_fid todo_oid inprog_oid done_oid sid_fid
    status_fid=$(gh api graphql -F projectId="$pid" \
        --jq '[.data.node.fields.nodes[]? | select(.__typename == "ProjectV2SingleSelectField" and .name == "Status") | .id] | first // ""' \
        -f query="$field_query" 2>/dev/null) || status_fid=""
    todo_oid=$(gh api graphql -F projectId="$pid" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "Todo") | .id] | first // ""' \
        -f query="$field_query" 2>/dev/null) || todo_oid=""
    inprog_oid=$(gh api graphql -F projectId="$pid" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "In Progress") | .id] | first // ""' \
        -f query="$field_query" 2>/dev/null) || inprog_oid=""
    done_oid=$(gh api graphql -F projectId="$pid" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "Done") | .id] | first // ""' \
        -f query="$field_query" 2>/dev/null) || done_oid=""
    sid_fid=$(gh api graphql -F projectId="$pid" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "'"$SESSION_ID_FIELD_NAME"'") | .id] | first // ""' \
        -f query="$field_query" 2>/dev/null) || sid_fid=""
    status_fid=$(printf '%s' "$status_fid" | tr -d '\r' | head -1)
    todo_oid=$(printf '%s' "$todo_oid" | tr -d '\r' | head -1)
    inprog_oid=$(printf '%s' "$inprog_oid" | tr -d '\r' | head -1)
    done_oid=$(printf '%s' "$done_oid" | tr -d '\r' | head -1)
    sid_fid=$(printf '%s' "$sid_fid" | tr -d '\r' | head -1)

    # ---- Populate caller-scope state ----
    RESOLVED_OWNER="$powner"
    RESOLVED_PROJECT_NUM="$pnum"
    RESOLVED_PROJECT_ID="$pid"
    RESOLVED_CONTENT_DATE_FIELD_ID="$content_date_id"
    RESOLVED_STATUS_FIELD_ID="$status_fid"
    RESOLVED_TODO_OPTION_ID="$todo_oid"
    RESOLVED_IN_PROGRESS_OPTION_ID="$inprog_oid"
    RESOLVED_DONE_OPTION_ID="$done_oid"
    RESOLVED_SESSION_ID_FIELD_ID="$sid_fid"

    RESOLVED_STATUS="resolved"

    # ---- Cache write (best-effort) ----
    [ "$no_cache_write" -eq 1 ] || _resolve_project_write_cache "$cache_dir" "$cache_file" "$owner_repo" \
        "$powner" "$pnum" "$pid" "$content_date_id" \
        "$status_fid" "$todo_oid" "$inprog_oid" "$done_oid" "$sid_fid" || true

    return 0
}
