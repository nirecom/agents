# resolve-project.sh — auto-resolve Projects v2 config from the origin remote (sourced, not executed).
# resolve_project_for_repo [--require-wip-fields] [--no-cache-read] sets RESOLVED_{OWNER (project owner,
#   not repo owner),PROJECT_NUM,PROJECT_ID,CONTENT_DATE_FIELD_ID,STATUS_FIELD_ID,TODO/IN_PROGRESS/DONE_OPTION_ID,
#   SESSION_ID_FIELD_ID} and RESOLVED_CACHE_KEY (owner/repo; empty on the internal short-circuit);
#   optional ids may be empty. rc=1: gh missing, origin not a github.com owner/repo, no linked Project,
#   or a graphql failure. --require-wip-fields: a cached row with an empty WIP column is a miss.
#   --no-cache-read: always fetch (the cache is still rewritten).
# _ISSUE_CREATE_INTERNAL_{OWNER,PROJECT_NUM,PROJECT_ID} (+ the optional *_FIELD_ID/*_OPTION_ID overrides) skip GraphQL.
# Cache: resolve-project/cache.sh (11-column rows tagged with a schema; any other row is refetched).
# Set-safety: every external command is guarded, so a failing gh never aborts a `set -e` caller.

_RESOLVE_PROJECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-project/cache.sh
. "$_RESOLVE_PROJECT_LIB_DIR/resolve-project/cache.sh"
# shellcheck source=session-id-field.sh
. "$_RESOLVE_PROJECT_LIB_DIR/session-id-field.sh"

resolve_project_for_repo() {
    # Always clear before populating so a stale value from a prior call cannot
    # leak through on failure.
    RESOLVED_OWNER=""
    RESOLVED_PROJECT_NUM=""
    RESOLVED_PROJECT_ID=""
    RESOLVED_CONTENT_DATE_FIELD_ID=""
    RESOLVED_STATUS_FIELD_ID=""
    RESOLVED_TODO_OPTION_ID=""
    RESOLVED_IN_PROGRESS_OPTION_ID=""
    RESOLVED_DONE_OPTION_ID=""
    RESOLVED_SESSION_ID_FIELD_ID=""
    RESOLVED_CACHE_KEY=""

    local require_wip=0 no_cache_read=0 arg
    for arg in "$@"; do
        case "$arg" in
            --require-wip-fields) require_wip=1 ;;
            --no-cache-read) no_cache_read=1 ;;
            *) echo "warn: resolve-project: unknown option '$arg' ignored" >&2 ;;
        esac
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
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "warn: resolve-project: gh CLI not found" >&2
        return 1
    fi

    # ---- Owner/repo from the ORIGIN remote (#1899) ----
    local script_dir owner_repo
    script_dir="$_RESOLVE_PROJECT_LIB_DIR"
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
    RESOLVED_CACHE_KEY="$owner_repo"

    # ---- Cache lookup (fixed-string key match; see resolve-project/cache.sh for hit rules) ----
    local cache_dir cache_file cache_row
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
        return 0
    fi

    # ---- Query A: count linked Projects v2 ----
    local owner_part repo_part
    owner_part="${owner_repo%/*}"
    repo_part="${owner_repo#*/}"

    local query_projects
    query_projects='query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    projectsV2(first: 10) {
      nodes { id number owner { ... on Organization { login } ... on User { login } } }
    }
  }
}'

    local count
    if ! count=$(gh api graphql \
            -F owner="$owner_part" \
            -F repo="$repo_part" \
            --jq '.data.repository.projectsV2.nodes | length' \
            -f query="$query_projects" 2>/dev/null); then
        echo "warn: resolve-project: gh api graphql (projectsV2 length) failed" >&2
        return 1
    fi
    count=$(printf '%s' "$count" | tr -d '\r' | head -1)
    if [ -z "$count" ] || [ "$count" = "0" ]; then
        echo "warn: resolve-project: no Projects v2 linked to $owner_repo" >&2
        return 1
    fi
    if [ "$count" -gt 1 ] 2>/dev/null; then
        echo "warn: resolve-project: multiple Projects v2 linked to $owner_repo — using first" >&2
    fi

    # ---- Query A (b): first-node {id, number, ownerLogin} ----
    local node_json
    if ! node_json=$(gh api graphql \
            -F owner="$owner_part" \
            -F repo="$repo_part" \
            --jq '.data.repository.projectsV2.nodes | if length == 0 then empty else .[0] | {id, number, ownerLogin: .owner.login} end' \
            -f query="$query_projects" 2>/dev/null); then
        echo "warn: resolve-project: gh api graphql (projectsV2 first-node) failed" >&2
        return 1
    fi
    node_json=$(printf '%s' "$node_json" | tr -d '\r' | head -1)
    if [ -z "$node_json" ]; then
        echo "warn: resolve-project: gh api graphql first-node returned empty" >&2
        return 1
    fi

    # Parse a single-line JSON object {"id":"...","number":N,"ownerLogin":"..."}.
    local pid pnum powner
    pid=$(printf '%s' "$node_json"   | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    pnum=$(printf '%s' "$node_json"  | sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    powner=$(printf '%s' "$node_json" | sed -n 's/.*"ownerLogin"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$pid" ] || [ -z "$pnum" ] || [ -z "$powner" ]; then
        echo "warn: resolve-project: could not parse project node JSON: $node_json" >&2
        return 1
    fi

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
    # Warn-only: a new project may not have these fields yet; missing ids are cached as empty
    # columns. First 50 fields only: a later session-id is picked up by the `set` recover.
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

    # ---- Cache write (best-effort) ----
    _resolve_project_write_cache "$cache_dir" "$cache_file" "$owner_repo" \
        "$powner" "$pnum" "$pid" "$content_date_id" \
        "$status_fid" "$todo_oid" "$inprog_oid" "$done_oid" "$sid_fid" || true

    return 0
}
