# ensure-project-ready.sh — reuse-or-create a repo's Projects v2 board and the fields /migrate-tracker needs
# (Content Date, Status + Todo/In Progress/Done, the WIP session-id field). Sourced, not executed.
# ensure_project_ready <owner/repo> (gh with `project` scope) sets on rc 0: EPR_PROJECT_{ID,NUM,OWNER},
#   EPR_CONTENT_DATE_FIELD_ID (may be empty), EPR_STATUS_FIELD_ID, EPR_{TODO,IN_PROGRESS,DONE}_OPTION_ID,
#   EPR_SESSION_ID_FIELD_ID and EPR_PM_FIELD_ID (TEXT fields via lib/session-id-field.sh; shown in board views, best-effort).
# The board is the repo's only open linked board (resolve-project.sh, no cache read/write), else a new linked one.
# rc 1 + an `error:` line: bad owner/repo, missing scope, a failed or ambiguous lookup, a same-titled unlinked
#   board (all: nothing created; the last prints the `gh project link` to run), a graphql failure, or a failed link (board deleted).
# Never writes .env or the TSV cache: run-issue-setup.sh --step ensure-project does.

# Idempotent — guard against double-sourcing.
if [ -n "${_ENSURE_PROJECT_READY_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_ENSURE_PROJECT_READY_SOURCED=1

# Reuse the canonical repo-link helper. This file is always sourced, never
# executed, so resolve the sibling relative to BASH_SOURCE (not $0).
_EPR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../migration/link-project.sh
. "$_EPR_LIB_DIR/../migration/link-project.sh"
# shellcheck source=session-id-field.sh
. "$_EPR_LIB_DIR/session-id-field.sh"
# shellcheck source=resolve-project.sh
. "$_EPR_LIB_DIR/resolve-project.sh"
# shellcheck source=board-create.sh
. "$_EPR_LIB_DIR/board-create.sh"

# Strip a trailing CR and keep the first line of gh/jq output.
_epr_clean() { printf '%s' "$1" | tr -d '\r' | head -1; }

# _epr_field_names — sets EPR_{CONTENT_DATE,STATUS,PM}_FIELD_NAME from bin/lib/tracker-fields/expected.js,
# the field table the tracker judge also reads (#3135). session-id keeps lib/session-id-field.sh's name
# (its other readers source it without node); a table that names it otherwise fails here instead of drifting.
# rc 1 + an `error:` line when the table cannot be read.
_epr_field_names() {
    local out line
    local -a names=()
    out=$(cd "$_EPR_LIB_DIR/../../lib/tracker-fields" && node expected.js --names 2>/dev/null) || out=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [ -n "$line" ] && names+=("$line")
    done <<<"$out"
    if [ "${#names[@]}" -ne 4 ]; then
        echo "error: ensure-project-ready: cannot read the field names from bin/lib/tracker-fields/expected.js" >&2
        return 1
    fi
    if [ "${names[2]}" != "$SESSION_ID_FIELD_NAME" ]; then
        echo "error: ensure-project-ready: expected.js names the session-id field '${names[2]}' but session-id-field.sh names it '$SESSION_ID_FIELD_NAME'" >&2
        return 1
    fi
    EPR_CONTENT_DATE_FIELD_NAME="${names[0]}"
    EPR_STATUS_FIELD_NAME="${names[1]}"
    PM_FIELD_NAME="${names[3]}"
}

ensure_project_ready() {
    EPR_PROJECT_ID=""
    EPR_PROJECT_NUM=""
    EPR_PROJECT_OWNER=""
    EPR_CONTENT_DATE_FIELD_ID=""
    EPR_STATUS_FIELD_ID=""
    EPR_TODO_OPTION_ID=""
    EPR_IN_PROGRESS_OPTION_ID=""
    EPR_DONE_OPTION_ID=""
    EPR_SESSION_ID_FIELD_ID=""
    EPR_PM_FIELD_ID=""

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
    _epr_field_names || return 1

    # Hard-fail: gh token must carry the `project` scope.
    if ! gh auth status 2>&1 | grep -q "'project'"; then
        echo "error: ensure-project-ready: gh token lacks 'project' scope — run: gh auth refresh -s project" >&2
        return 1
    fi

    # ---- Reuse the repo's only open linked board, or create and link one (never matched by title) ----
    local pid pnum powner rc=0
    resolve_project_for_repo --repo "$owner_repo" --no-cache-read --no-cache-write || rc=$?
    case "${RESOLVED_STATUS:-}" in
        resolved)
            [ "$rc" -eq 0 ] || return 1
            pid="$RESOLVED_PROJECT_ID" pnum="$RESOLVED_PROJECT_NUM" powner="$RESOLVED_OWNER"
            ;;
        no-link)
            _epr_create_linked_board "$owner" "$repo" || return 1
            pid="$_EPR_NEW_PID" pnum="$_EPR_NEW_PNUM" powner="$_EPR_NEW_POWNER"
            ;;
        *)
            echo "error: ensure-project-ready: no board for $owner_repo (${RESOLVED_STATUS:-fetch-failed}); nothing created" >&2
            return 1
            ;;
    esac

    EPR_PROJECT_ID="$pid"
    EPR_PROJECT_NUM="$pnum"
    EPR_PROJECT_OWNER="$powner"

    # ---- Content Date field (best-effort ensure) ----
    _epr_ensure_content_date "$pid" || true

    # ---- Discover existing fields ----
    if ! _epr_ensure_status_field "$pid"; then
        return 1
    fi
    # Only the session-id name is consulted; a legacy field is left for the `set` recover.
    if ! session_id_field_create_if_absent "$pid"; then
        return 1
    fi
    EPR_SESSION_ID_FIELD_ID="$SESSION_ID_FIELD_ENSURED_ID"
    session_id_field_show_in_views "$pid" "$EPR_SESSION_ID_FIELD_ID" || true
    # The PM field (#2942): the PM tag owning the issue. Best-effort: only PM sessions use it, and
    # their writer refuses (fail-closed) while the field is missing, so a failure here only warns.
    if project_text_field_create_if_absent "$pid" "$PM_FIELD_NAME"; then
        EPR_PM_FIELD_ID="$PROJECT_TEXT_FIELD_ENSURED_ID"
        project_text_field_show_in_views "$pid" "$EPR_PM_FIELD_ID" "$PM_FIELD_NAME" || true
    else
        echo "warn: ensure-project-ready: the PM field '$PM_FIELD_NAME' is not ready; PM commands on this board refuse until a rerun creates it" >&2
    fi

    return 0
}

# _epr_create_linked_board <owner> <repo> — create the board and link it; sets _EPR_NEW_{PID,PNUM,POWNER}.
# rc 1 when the create fails or the link fails (the new board is then discarded: board-create.sh).
_epr_create_linked_board() {
    local owner="$1" repo="$2" owner_id create_json
    _EPR_NEW_PID="" _EPR_NEW_PNUM="" _EPR_NEW_POWNER=""
    project_board_refuse_duplicate "$owner" "$owner/$repo" || return 1
    owner_id=$(gh api graphql -f query="{viewer{id}}" --jq '.data.viewer.id' 2>/dev/null \
        || gh api graphql -f query="{user(login:\"$owner\"){id}}" --jq '.data.user.id' 2>/dev/null \
        || gh api graphql -f query="{organization(login:\"$owner\"){id}}" --jq '.data.organization.id' 2>/dev/null)
    owner_id=$(_epr_clean "$owner_id")
    if [ -z "$owner_id" ]; then
        echo "error: ensure-project-ready: could not resolve owner id for '$owner'" >&2
        return 1
    fi
    if ! create_json=$(gh api graphql \
            -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number owner{... on User{login} ... on Organization{login}}}}}' \
            -f o="$owner_id" -f t="$(project_board_title "$owner/$repo")" 2>/dev/null); then
        echo "error: ensure-project-ready: createProjectV2 mutation failed" >&2
        return 1
    fi
    _EPR_NEW_PID=$(_epr_clean "$(printf '%s' "$create_json" | jq -r '.data.createProjectV2.projectV2.id // empty' 2>/dev/null)")
    _EPR_NEW_PNUM=$(_epr_clean "$(printf '%s' "$create_json" | jq -r '.data.createProjectV2.projectV2.number // empty' 2>/dev/null)")
    _EPR_NEW_POWNER=$(_epr_clean "$(printf '%s' "$create_json" | jq -r '.data.createProjectV2.projectV2.owner.login // empty' 2>/dev/null)")
    _EPR_NEW_POWNER="${_EPR_NEW_POWNER:-$owner}"
    if [ -z "$_EPR_NEW_PID" ] || [ -z "$_EPR_NEW_PNUM" ]; then
        echo "error: ensure-project-ready: createProjectV2 returned no id/number" >&2
        return 1
    fi
    if ! link_project_to_repo "$_EPR_NEW_PID" "$owner" "$repo"; then
        project_board_discard_unlinked "$_EPR_NEW_POWNER" "$_EPR_NEW_PNUM" "$owner/$repo" || true
        _EPR_NEW_PID="" _EPR_NEW_PNUM="" _EPR_NEW_POWNER=""
        return 1
    fi
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
    existing=$(printf '%s' "$fields_json" | jq -r --arg n "$EPR_CONTENT_DATE_FIELD_NAME" '[.data.node.fields.nodes[]? | select(.name == $n and .dataType == "DATE") | .id] | first // ""' 2>/dev/null)
    existing=$(_epr_clean "$existing")
    if [ -n "$existing" ]; then
        EPR_CONTENT_DATE_FIELD_ID="$existing"
        return 0
    fi
    local created
    created=$(gh api graphql \
        -f query='mutation($p:ID!,$name:String!){createProjectV2Field(input:{projectId:$p,dataType:DATE,name:$name}){projectV2Field{... on ProjectV2FieldCommon{id}}}}' \
        -f p="$pid" -f name="$EPR_CONTENT_DATE_FIELD_NAME" 2>/dev/null) || created=""
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
        | jq -r --arg n "$EPR_STATUS_FIELD_NAME" '[.data.node.fields.nodes[]? | select(.name == $n and (.dataType == "SINGLE_SELECT" or (.options | type) == "array")) | .id] | first // ""' 2>/dev/null)
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
        -F projectId="$pid" -f name="$EPR_STATUS_FIELD_NAME" \
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
    local n="$EPR_STATUS_FIELD_NAME"
    EPR_TODO_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r --arg n "$n" '[.data.node.fields.nodes[]? | select(.name == $n) | .options[]? | select(.name == "Todo") | .id] | first // ""' 2>/dev/null)")
    EPR_IN_PROGRESS_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r --arg n "$n" '[.data.node.fields.nodes[]? | select(.name == $n) | .options[]? | select(.name == "In Progress") | .id] | first // ""' 2>/dev/null)")
    EPR_DONE_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r --arg n "$n" '[.data.node.fields.nodes[]? | select(.name == $n) | .options[]? | select(.name == "Done") | .id] | first // ""' 2>/dev/null)")
}

# Parse Todo/In Progress/Done option ids from an updateProjectV2Field result.
_epr_extract_status_options_from_update() {
    local json="$1"
    EPR_TODO_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.updateProjectV2Field.projectV2Field.options[]? | select(.name == "Todo") | .id] | first // ""' 2>/dev/null)")
    EPR_IN_PROGRESS_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.updateProjectV2Field.projectV2Field.options[]? | select(.name == "In Progress") | .id] | first // ""' 2>/dev/null)")
    EPR_DONE_OPTION_ID=$(_epr_clean "$(printf '%s' "$json" | jq -r '[.data.updateProjectV2Field.projectV2Field.options[]? | select(.name == "Done") | .id] | first // ""' 2>/dev/null)")
}
