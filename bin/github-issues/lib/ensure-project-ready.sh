# ensure-project-ready.sh — reuse-or-create a Projects v2 board for a repo and
# ensure the fields /issue-setup needs (Content Date, Status + Todo/In Progress/
# Done options, session-fingerprint). Extracted from migration/create-project.sh
# with all .migration-state.json dependencies removed.
#
# Sourced (not executed): . "/path/to/lib/ensure-project-ready.sh"
# Entry point: ensure_project_ready <owner/repo>   (e.g. nirecom/ds4-ops)
#
# Requires: gh CLI with `project` scope; network access.
#
# On success (rc=0) sets caller-scope variables:
#   EPR_PROJECT_ID              project GraphQL node id
#   EPR_PROJECT_NUM             project number (integer)
#   EPR_PROJECT_OWNER           project owner login (owner half of owner/repo)
#   EPR_CONTENT_DATE_FIELD_ID   Content Date field id (may be empty)
#   EPR_STATUS_FIELD_ID         Status single-select field id
#   EPR_TODO_OPTION_ID          Status "Todo" option id
#   EPR_IN_PROGRESS_OPTION_ID   Status "In Progress" option id
#   EPR_DONE_OPTION_ID          Status "Done" option id
#   EPR_FINGERPRINT_FIELD_ID    session-fingerprint text field id
#
# On failure (rc=1) prints an `error:`-prefixed line to stderr; the caller
# decides fatality. Hard-fail conditions: gh lacks `project` scope, generic
# graphql API error, or gh project list failure. Malformed/injection owner/repo
# is rejected before any gh call.
#
# Never writes .env or the TSV cache — cache writes are the caller's job
# (run-issue-setup.sh --step ensure-project).

# Idempotent — guard against double-sourcing.
if [ -n "${_ENSURE_PROJECT_READY_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_ENSURE_PROJECT_READY_SOURCED=1

# Strip a trailing CR and keep the first line of gh/jq output.
_epr_clean() { printf '%s' "$1" | tr -d '\r' | head -1; }

ensure_project_ready() {
    EPR_PROJECT_ID=""
    EPR_PROJECT_NUM=""
    EPR_PROJECT_OWNER=""
    EPR_CONTENT_DATE_FIELD_ID=""
    EPR_STATUS_FIELD_ID=""
    EPR_TODO_OPTION_ID=""
    EPR_IN_PROGRESS_OPTION_ID=""
    EPR_DONE_OPTION_ID=""
    EPR_FINGERPRINT_FIELD_ID=""

    local owner_repo="${1:-}"
    # Reject malformed/injection input before any gh call. Exactly two segments,
    # each ASCII [A-Za-z0-9_.-], neither leading with '-' (option-injection) nor
    # equal to a path-traversal token ('.' / '..').
    if ! [[ "$owner_repo" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]]; then
        echo "error: ensure-project-ready: invalid owner/repo: '$owner_repo'" >&2
        return 1
    fi
    local owner="${owner_repo%/*}"
    local repo="${owner_repo#*/}"
    case "$owner" in .|..) owner=""; esac
    case "$repo"  in .|..) repo="";  esac
    if [ -z "$owner" ] || [ -z "$repo" ]; then
        echo "error: ensure-project-ready: invalid owner/repo: '$owner_repo'" >&2
        return 1
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "error: ensure-project-ready: gh CLI not found" >&2
        return 1
    fi

    # Hard-fail: gh token must carry the `project` scope.
    if ! gh auth status 2>&1 | grep -q "'project'"; then
        echo "error: ensure-project-ready: gh token lacks 'project' scope — run: gh auth refresh -s project" >&2
        return 1
    fi

    local project_title="$owner_repo — Issue Timeline"

    # ---- Reuse-or-create the board ----
    local list_json existing_num=""
    if ! list_json=$(gh project list --owner "$owner" --format json 2>/dev/null); then
        echo "error: ensure-project-ready: gh project list failed for owner '$owner'" >&2
        return 1
    fi
    existing_num=$(printf '%s' "$list_json" \
        | jq -r --arg t "$project_title" '[.projects[]? | select(.title==$t) | .number] | .[0] // empty' 2>/dev/null)
    existing_num=$(_epr_clean "$existing_num")

    local pid pnum
    if [ -n "$existing_num" ]; then
        pnum="$existing_num"
        pid=$(printf '%s' "$list_json" \
            | jq -r --arg t "$project_title" '[.projects[]? | select(.title==$t) | .id] | .[0] // empty' 2>/dev/null)
        pid=$(_epr_clean "$pid")
        if [ -z "$pid" ]; then
            pid=$(gh project view "$existing_num" --owner "$owner" --format json --jq '.id' 2>/dev/null)
            pid=$(_epr_clean "$pid")
        fi
    else
        local owner_id
        owner_id=$(gh api graphql -f query="{viewer{id}}" --jq '.data.viewer.id' 2>/dev/null \
            || gh api graphql -f query="{user(login:\"$owner\"){id}}" --jq '.data.user.id' 2>/dev/null \
            || gh api graphql -f query="{organization(login:\"$owner\"){id}}" --jq '.data.organization.id' 2>/dev/null)
        owner_id=$(_epr_clean "$owner_id")
        if [ -z "$owner_id" ]; then
            echo "error: ensure-project-ready: could not resolve owner id for '$owner'" >&2
            return 1
        fi
        local create_json
        if ! create_json=$(gh api graphql \
                -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number}}}' \
                -f o="$owner_id" -f t="$project_title" 2>/dev/null); then
            echo "error: ensure-project-ready: createProjectV2 mutation failed" >&2
            return 1
        fi
        pid=$(printf '%s' "$create_json" | jq -r '.data.createProjectV2.projectV2.id // empty' 2>/dev/null)
        pnum=$(printf '%s' "$create_json" | jq -r '.data.createProjectV2.projectV2.number // empty' 2>/dev/null)
        pid=$(_epr_clean "$pid")
        pnum=$(_epr_clean "$pnum")
        if [ -z "$pid" ] || [ -z "$pnum" ]; then
            echo "error: ensure-project-ready: createProjectV2 returned no id/number" >&2
            return 1
        fi
    fi

    EPR_PROJECT_ID="$pid"
    EPR_PROJECT_NUM="$pnum"
    EPR_PROJECT_OWNER="$owner"

    # ---- Content Date field (best-effort ensure) ----
    _epr_ensure_content_date "$pid" || true

    # ---- Discover existing fields ----
    if ! _epr_ensure_status_field "$pid"; then
        return 1
    fi
    if ! _epr_ensure_fingerprint_field "$pid"; then
        return 1
    fi

    return 0
}

# Discovery query (shared by field-ensure helpers). Same shape as cmd-setup.sh.
_epr_field_query='query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 50) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField {
            id name
            options { id name }
          }
        }
      }
    }
  }
}'

# Ensure Content Date DATE field exists (create-if-missing). Best-effort.
_epr_ensure_content_date() {
    local pid="$1"
    local fields_json existing
    fields_json=$(gh api graphql -F projectId="$pid" -f query="$_epr_field_query" 2>/dev/null) || fields_json=""
    existing=$(printf '%s' "$fields_json" | jq -r '[.data.node.fields.nodes[]? | select(.name == "Content Date" and .dataType == "DATE") | .id] | first // ""' 2>/dev/null)
    existing=$(_epr_clean "$existing")
    if [ -n "$existing" ]; then
        EPR_CONTENT_DATE_FIELD_ID="$existing"
        return 0
    fi
    local created
    created=$(gh api graphql \
        -f query='mutation($p:ID!){createProjectV2Field(input:{projectId:$p,dataType:DATE,name:"Content Date"}){projectV2Field{... on ProjectV2FieldCommon{id}}}}' \
        -f p="$pid" 2>/dev/null) || created=""
    created=$(printf '%s' "$created" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null)
    EPR_CONTENT_DATE_FIELD_ID=$(_epr_clean "$created")
    return 0
}

# Ensure the Status single-select field + Todo/In Progress/Done options.
_epr_ensure_status_field() {
    local pid="$1"
    local fields_json
    if ! fields_json=$(gh api graphql -F projectId="$pid" -f query="$_epr_field_query" 2>/dev/null); then
        echo "error: ensure-project-ready: field discovery query failed" >&2
        return 1
    fi

    # Match on name (+ SINGLE_SELECT/options presence) rather than __typename:
    # discovery payloads expose name/dataType/options but not always __typename.
    local status_id
    status_id=$(printf '%s' "$fields_json" \
        | jq -r '[.data.node.fields.nodes[]? | select(.name == "Status" and (.dataType == "SINGLE_SELECT" or (.options | type) == "array")) | .id] | first // ""' 2>/dev/null)
    status_id=$(_epr_clean "$status_id")

    if [ -n "$status_id" ]; then
        # Existing field — read options from the discovery result.
        EPR_STATUS_FIELD_ID="$status_id"
        _epr_extract_status_options "$fields_json"
        return 0
    fi

    # Create the SINGLE_SELECT field (options are added by a follow-up update).
    local create_json new_id
    create_json=$(gh api graphql \
        -F projectId="$pid" -F name="Status" \
        -f query='mutation($projectId:ID!,$name:String!){createProjectV2Field(input:{projectId:$projectId,name:$name,dataType:SINGLE_SELECT}){projectV2Field{...on ProjectV2SingleSelectField{id}}}}' \
        2>/dev/null) || create_json=""
    new_id=$(printf '%s' "$create_json" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null)
    new_id=$(_epr_clean "$new_id")
    if [ -z "$new_id" ]; then
        echo "error: ensure-project-ready: createProjectV2Field (Status) produced no id" >&2
        return 1
    fi

    # Add the three options in one update mutation and read their ids back.
    local update_json
    if ! update_json=$(gh api graphql \
            -F projectId="$pid" -F fieldId="$new_id" \
            -f opts='[{"name":"Todo","color":"GRAY","description":""},{"name":"In Progress","color":"YELLOW","description":""},{"name":"Done","color":"GREEN","description":""}]' \
            -f query='mutation($projectId:ID!,$fieldId:ID!,$opts:[ProjectV2SingleSelectFieldOptionInput!]!){updateProjectV2Field(input:{projectId:$projectId,fieldId:$fieldId,singleSelectOptions:$opts}){projectV2Field{...on ProjectV2SingleSelectField{id options{id name}}}}}' \
            2>/dev/null); then
        echo "error: ensure-project-ready: updateProjectV2Field (Status options) failed" >&2
        return 1
    fi
    EPR_STATUS_FIELD_ID="$new_id"
    _epr_extract_status_options_from_update "$update_json"
    return 0
}

# Parse Todo/In Progress/Done option ids from a discovery-query result.
_epr_extract_status_options() {
    local json="$1"
    EPR_TODO_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "Todo") | .id] | first // ""' 2>/dev/null)")
    EPR_IN_PROGRESS_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "In Progress") | .id] | first // ""' 2>/dev/null)")
    EPR_DONE_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "Done") | .id] | first // ""' 2>/dev/null)")
}

# Parse Todo/In Progress/Done option ids from an updateProjectV2Field result.
_epr_extract_status_options_from_update() {
    local json="$1"
    EPR_TODO_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.updateProjectV2Field.projectV2Field.options[]? | select(.name == "Todo") | .id] | first // ""' 2>/dev/null)")
    EPR_IN_PROGRESS_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.updateProjectV2Field.projectV2Field.options[]? | select(.name == "In Progress") | .id] | first // ""' 2>/dev/null)")
    EPR_DONE_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.updateProjectV2Field.projectV2Field.options[]? | select(.name == "Done") | .id] | first // ""' 2>/dev/null)")
}

# Ensure the session-fingerprint TEXT field (create-if-missing).
_epr_ensure_fingerprint_field() {
    local pid="$1"
    local fields_json
    if ! fields_json=$(gh api graphql -F projectId="$pid" -f query="$_epr_field_query" 2>/dev/null); then
        echo "error: ensure-project-ready: fingerprint discovery query failed" >&2
        return 1
    fi
    local fp_id
    fp_id=$(printf '%s' "$fields_json" \
        | jq -r '[.data.node.fields.nodes[]? | select(.name == "session-fingerprint") | .id] | first // ""' 2>/dev/null)
    fp_id=$(_epr_clean "$fp_id")
    if [ -n "$fp_id" ]; then
        EPR_FINGERPRINT_FIELD_ID="$fp_id"
        return 0
    fi

    local create_json created
    if ! create_json=$(gh api graphql \
            -F projectId="$pid" -F name="session-fingerprint" \
            -f query='mutation($projectId:ID!,$name:String!){createProjectV2Field(input:{projectId:$projectId,name:$name,dataType:TEXT}){projectV2Field{...on ProjectV2FieldCommon{id name}}}}' \
            2>/dev/null); then
        echo "error: ensure-project-ready: createProjectV2Field (session-fingerprint TEXT) failed" >&2
        return 1
    fi
    created=$(printf '%s' "$create_json" | jq -r '.data.createProjectV2Field.projectV2Field.id // empty' 2>/dev/null)
    created=$(_epr_clean "$created")
    if [ -z "$created" ]; then
        # Re-discover in case the mutation id was not returned directly.
        local redis
        redis=$(gh api graphql -F projectId="$pid" -f query="$_epr_field_query" 2>/dev/null) || redis=""
        redis=$(printf '%s' "$redis" | jq -r '[.data.node.fields.nodes[]? | select(.name == "session-fingerprint") | .id] | first // ""' 2>/dev/null)
        created=$(_epr_clean "$redis")
    fi
    if [ -z "$created" ]; then
        echo "error: ensure-project-ready: session-fingerprint field id unresolved after create" >&2
        return 1
    fi
    EPR_FINGERPRINT_FIELD_ID="$created"
    return 0
}
