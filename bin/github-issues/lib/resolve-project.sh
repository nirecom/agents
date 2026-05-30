# resolve-project.sh — auto-resolve Projects v2 config from git remote.
#
# Sourced (not executed). Exposes `resolve_project_for_repo` which sets the
# following caller-scope variables on success (rc=0):
#   RESOLVED_OWNER                  project node owner.login (NOT repo owner)
#   RESOLVED_PROJECT_NUM            project number
#   RESOLVED_PROJECT_ID             project node id
#   RESOLVED_CONTENT_DATE_FIELD_ID  Content Date field id (empty if not present)
#
# Returns rc=1 on:
#   - gh not in PATH
#   - gh repo view failed (no remote / not a github repo)
#   - 0 linked Projects v2 to the repo
#   - any gh api graphql failure
#
# Internal short-circuit: when all three of
#   _ISSUE_CREATE_INTERNAL_OWNER, _ISSUE_CREATE_INTERNAL_PROJECT_NUM,
#   _ISSUE_CREATE_INTERNAL_PROJECT_ID
# are set in the environment, populate RESOLVED_* from them and skip GraphQL.
# The optional _ISSUE_CREATE_INTERNAL_FIELD_ID is used when set.
#
# Cache: ${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/cache/project-resolve.tsv
# TSV: owner/repo \t project_owner \t project_num \t project_id \t content_date_field_id
# Cache lookup is fixed-string (awk $1==key) — no regex metachar exposure.
# Cache write uses mktemp + mv for atomicity; mv failure is non-fatal (warn,
# return 0 with resolved values still set).
#
# Set-safety: callers may have `set -e`. Every external command is guarded
# with `|| return 1` / `|| true` / `if !` so a single failing gh invocation
# never aborts the caller mid-resolve.

# resolve_project_for_repo
#   no positional args.
#   side effect: sets RESOLVED_OWNER, RESOLVED_PROJECT_NUM, RESOLVED_PROJECT_ID,
#                RESOLVED_CONTENT_DATE_FIELD_ID.
resolve_project_for_repo() {
    # Always clear before populating so a stale value from a prior call cannot
    # leak through on failure.
    RESOLVED_OWNER=""
    RESOLVED_PROJECT_NUM=""
    RESOLVED_PROJECT_ID=""
    RESOLVED_CONTENT_DATE_FIELD_ID=""

    # ---- Internal short-circuit ----
    if [ -n "${_ISSUE_CREATE_INTERNAL_OWNER:-}" ] \
       && [ -n "${_ISSUE_CREATE_INTERNAL_PROJECT_NUM:-}" ] \
       && [ -n "${_ISSUE_CREATE_INTERNAL_PROJECT_ID:-}" ]; then
        RESOLVED_OWNER="$_ISSUE_CREATE_INTERNAL_OWNER"
        RESOLVED_PROJECT_NUM="$_ISSUE_CREATE_INTERNAL_PROJECT_NUM"
        RESOLVED_PROJECT_ID="$_ISSUE_CREATE_INTERNAL_PROJECT_ID"
        RESOLVED_CONTENT_DATE_FIELD_ID="${_ISSUE_CREATE_INTERNAL_FIELD_ID:-}"
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "warn: resolve-project: gh CLI not found" >&2
        return 1
    fi

    # ---- Owner/repo from git remote (via gh) ----
    local script_dir owner_repo
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=board-card.sh
    . "$script_dir/board-card.sh"

    if ! owner_repo=$(resolve_owner_repo); then
        echo "warn: resolve-project: gh repo view failed (no remote or not a GitHub repo)" >&2
        return 1
    fi
    owner_repo=$(printf '%s' "$owner_repo" | tr -d '\r' | head -1)
    if [ -z "$owner_repo" ]; then
        echo "warn: resolve-project: gh repo view returned empty owner/repo" >&2
        return 1
    fi

    # ---- Cache lookup (fixed-string match on $1) ----
    local plans_dir cache_dir cache_file cache_row
    plans_dir="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    cache_dir="$plans_dir/cache"
    cache_file="$cache_dir/project-resolve.tsv"
    if [ -f "$cache_file" ]; then
        cache_row=$(awk -F'\t' -v key="$owner_repo" '$1==key {print; exit}' "$cache_file" 2>/dev/null || true)
        if [ -n "$cache_row" ]; then
            # Require exactly 5 fields. NF check rejects malformed rows.
            local n_fields
            n_fields=$(printf '%s' "$cache_row" | awk -F'\t' '{print NF}')
            if [ "$n_fields" = "5" ]; then
                RESOLVED_OWNER=$(printf '%s' "$cache_row"   | cut -f2)
                RESOLVED_PROJECT_NUM=$(printf '%s' "$cache_row" | cut -f3)
                RESOLVED_PROJECT_ID=$(printf '%s' "$cache_row"  | cut -f4)
                RESOLVED_CONTENT_DATE_FIELD_ID=$(printf '%s' "$cache_row" | cut -f5)
                # Sanity-check required fields: malformed row → fall through to fetch.
                if [ -n "$RESOLVED_OWNER" ] && [ -n "$RESOLVED_PROJECT_NUM" ] \
                   && [ -n "$RESOLVED_PROJECT_ID" ]; then
                    return 0
                fi
            fi
            # Malformed/incomplete row — fall through to graphql fetch.
            RESOLVED_OWNER=""; RESOLVED_PROJECT_NUM=""; RESOLVED_PROJECT_ID=""
            RESOLVED_CONTENT_DATE_FIELD_ID=""
        fi
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
    # Tolerant of attribute ordering; uses non-greedy regex per field.
    local pid pnum powner
    pid=$(printf '%s' "$node_json"   | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    pnum=$(printf '%s' "$node_json"  | sed -n 's/.*"number"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    powner=$(printf '%s' "$node_json" | sed -n 's/.*"ownerLogin"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -z "$pid" ] || [ -z "$pnum" ] || [ -z "$powner" ]; then
        echo "warn: resolve-project: could not parse project node JSON: $node_json" >&2
        return 1
    fi

    # ---- Query B: paginate fields, locate "Content Date" (DATE dataType) ----
    # Two query bodies — one for endCursor (cursor advancement) and one for the
    # Content Date field id. Real gojq could fetch both in one round trip; the
    # split-call shape keeps the test mock's substring-based dispatch
    # unambiguous. Loop terminates when field is found, cursor stops advancing,
    # or guard limit is hit.
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

    local content_date_id="" cursor="" guard=0
    while [ "$guard" -lt 20 ]; do
        guard=$((guard + 1))

        # endCursor advance for the NEXT page (empty on the final page).
        local page_cursor
        if [ -z "$cursor" ]; then
            page_cursor=$(gh api graphql \
                -F projectId="$pid" \
                --jq '.data.node.fields.pageInfo.endCursor // ""' \
                -f query="$query_cursor" 2>/dev/null) || page_cursor=""
        else
            page_cursor=$(gh api graphql \
                -F projectId="$pid" \
                -F after="$cursor" \
                --jq '.data.node.fields.pageInfo.endCursor // ""' \
                -f query="$query_cursor" 2>/dev/null) || page_cursor=""
        fi
        page_cursor=$(printf '%s' "$page_cursor" | tr -d '\r' | head -1)

        # Field id lookup against the same page (or advanced page when cursor
        # was set by previous iteration).
        local page_field
        if [ -z "$cursor" ]; then
            page_field=$(gh api graphql \
                -F projectId="$pid" \
                --jq '[.data.node.fields.nodes[]? | select(.name == "Content Date" and .dataType == "DATE") | .id] | first // ""' \
                -f query="$query_field_id" 2>/dev/null) || page_field=""
        else
            page_field=$(gh api graphql \
                -F projectId="$pid" \
                -F after="$cursor" \
                --jq '[.data.node.fields.nodes[]? | select(.name == "Content Date" and .dataType == "DATE") | .id] | first // ""' \
                -f query="$query_field_id" 2>/dev/null) || page_field=""
        fi
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

    # ---- Populate caller-scope state ----
    RESOLVED_OWNER="$powner"
    RESOLVED_PROJECT_NUM="$pnum"
    RESOLVED_PROJECT_ID="$pid"
    RESOLVED_CONTENT_DATE_FIELD_ID="$content_date_id"

    # ---- Cache write (best-effort) ----
    _resolve_project_write_cache "$cache_dir" "$cache_file" "$owner_repo" \
        "$powner" "$pnum" "$pid" "$content_date_id" || true

    return 0
}

# Internal: rewrite the cache TSV with the new row replacing any prior row for
# the same key. Atomic via mktemp + mv. mv failure is non-fatal (warn only).
_resolve_project_write_cache() {
    local cache_dir="$1" cache_file="$2" key="$3"
    local p_owner="$4" p_num="$5" p_id="$6" p_field="$7"

    if ! mkdir -p "$cache_dir" 2>/dev/null; then
        echo "warn: resolve-project: cache write failed (mkdir $cache_dir)" >&2
        return 1
    fi

    local tmp
    tmp=$(mktemp "$cache_dir/.project-resolve.XXXXXX" 2>/dev/null) || {
        echo "warn: resolve-project: cache write failed (mktemp)" >&2
        return 1
    }

    if [ -f "$cache_file" ]; then
        awk -F'\t' -v key="$key" 'BEGIN{OFS="\t"} $1!=key {print}' "$cache_file" > "$tmp" 2>/dev/null || true
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$p_owner" "$p_num" "$p_id" "$p_field" >> "$tmp"

    if ! mv "$tmp" "$cache_file" 2>/dev/null; then
        echo "warn: resolve-project: cache write failed (mv)" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}
