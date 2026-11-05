# session-id-field.sh — the one place that names the WIP session-id Projects v2 field (sourced).
# The field holds the raw session id of the session working an issue (docs/architecture/wip-signaling.md).
# Callers: lib/resolve-project.sh (name only), lib/ensure-project-ready.sh (create + views),
#   wip-state/field-recover.sh (set-only recover). Every field list walks all pages, so a field
#   past the 50th is still seen. Set-safety: every gh call is guarded; nothing aborts a `set -e` caller.

if [ -n "${_SESSION_ID_FIELD_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_SESSION_ID_FIELD_SOURCED=1

SESSION_ID_FIELD_NAME="session-id"
# Retired name (#2925). Only the `set` recover in wip-state/field-recover.sh may look for it.
LEGACY_SESSION_FIELD_NAME="session-fingerprint"

# _sif_list_fields <pid> — one "id<TAB>name" line per field across every page (guard: 20 pages).
# rc 2 when any page query fails (the caller must not act on a partial list).
_sif_list_fields() {
    local pid="$1" cursor="" guard=0 out line has_next next
    local query='query($projectId: ID!, $after: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 50, after: $after) {
        nodes { ... on ProjectV2FieldCommon { id name } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'
    local jq_page='(.data.node.fields.nodes[]? | select(.id != null) | "F\t\(.id)\t\(.name)"), "P\t\(.data.node.fields.pageInfo.hasNextPage // false)\t\(.data.node.fields.pageInfo.endCursor // "")"'
    while [ "$guard" -lt 20 ]; do
        guard=$((guard + 1))
        if [ -z "$cursor" ]; then
            out=$(gh api graphql -F projectId="$pid" --jq "$jq_page" -f query="$query" 2>/dev/null) || return 2
        else
            out=$(gh api graphql -F projectId="$pid" -f after="$cursor" --jq "$jq_page" -f query="$query" 2>/dev/null) || return 2
        fi
        has_next="false" next=""
        while IFS= read -r line; do
            line="${line%$'\r'}"
            case "$line" in
                F$'\t'*) printf '%s\n' "${line#F$'\t'}" ;;
                P$'\t'*) line="${line#P$'\t'}"; has_next="${line%%$'\t'*}"; next="${line#*$'\t'}" ;;
            esac
        done <<<"$out"
        if [ "$has_next" != "true" ] || [ -z "$next" ] || [ "$next" = "$cursor" ]; then
            return 0
        fi
        cursor="$next"
    done
    return 0
}

# session_id_field_find <pid> <name> — prints the first field id named <name>.
# rc 0 found, 1 not found, 2 field list failed.
session_id_field_find() {
    local list id name
    list="$(_sif_list_fields "$1")" || return 2
    while IFS=$'\t' read -r id name; do
        if [ -n "$id" ] && [ "$name" = "$2" ]; then
            printf '%s\n' "$id"
            return 0
        fi
    done <<<"$list"
    return 1
}

# project_field_id_exists <pid> <fid> — rc 0 the field exists, 1 it does not, 2 the query failed.
project_field_id_exists() {
    local list id name
    list="$(_sif_list_fields "$1")" || return 2
    while IFS=$'\t' read -r id name; do
        [ -n "$id" ] && [ "$id" = "$2" ] && return 0
    done <<<"$list"
    return 1
}

# session_id_field_create_if_absent <pid> — reuse or create the session-id TEXT field.
# Sets SESSION_ID_FIELD_ENSURED_ID, rc 0. rc 1 with an `error:` line otherwise. Never creates when
# the field list cannot be read (a blind create could duplicate). The retired name is never consulted.
session_id_field_create_if_absent() {
    local pid="$1" id rc
    SESSION_ID_FIELD_ENSURED_ID=""
    id="$(session_id_field_find "$pid" "$SESSION_ID_FIELD_NAME")"; rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "error: session-id-field: field list query failed; not creating '$SESSION_ID_FIELD_NAME'" >&2
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        if ! id=$(gh api graphql -F projectId="$pid" -f name="$SESSION_ID_FIELD_NAME" \
                -f query='mutation($projectId:ID!,$name:String!){createProjectV2Field(input:{projectId:$projectId,name:$name,dataType:TEXT}){projectV2Field{...on ProjectV2FieldCommon{id name}}}}' \
                --jq '.data.createProjectV2Field.projectV2Field.id // ""' 2>/dev/null); then
            echo "error: session-id-field: createProjectV2Field ($SESSION_ID_FIELD_NAME TEXT) failed" >&2
            return 1
        fi
        id="$(printf '%s' "$id" | tr -d '\r' | head -1)"
        # The create answered without an id: read the list again.
        [ -n "$id" ] || id="$(session_id_field_find "$pid" "$SESSION_ID_FIELD_NAME")" || id=""
    fi
    id="$(printf '%s' "$id" | tr -d '\r' | head -1)"
    if [ -z "$id" ]; then
        echo "error: session-id-field: '$SESSION_ID_FIELD_NAME' field id unresolved after create" >&2
        return 1
    fi
    SESSION_ID_FIELD_ENSURED_ID="$id"
    return 0
}

# session_id_field_show_in_views <pid> <fid> — best-effort: add <fid> to every BOARD view that does
# not show it, passing the view's full visible list plus <fid> (replace-vs-append is undocumented).
# Each view's original visibleFieldIds is logged first so it can be restored by hand. A BOARD view
# whose visible fields exceed one page (100) is skipped with a warn: sending its truncated list
# would hide the rest. Always rc 0.
session_id_field_show_in_views() {
    local pid="$1" fid="$2" cursor="" guard=0 out line has_next next vid layout truncated ids
    local -a updates=()
    local query='query($projectId: ID!, $after: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      views(first: 20, after: $after) {
        nodes { id layout fields(first: 100) { nodes { ... on ProjectV2FieldCommon { id } } pageInfo { hasNextPage } } }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'
    local jq_page='(.data.node.views.nodes[]? | "V\t\(.id)\t\(.layout)\t\(.fields.pageInfo.hasNextPage // false)\t\([.fields.nodes[]?.id | select(. != null)] | join(","))"), "P\t\(.data.node.views.pageInfo.hasNextPage // false)\t\(.data.node.views.pageInfo.endCursor // "")"'
    while [ "$guard" -lt 20 ]; do
        guard=$((guard + 1))
        if [ -z "$cursor" ]; then
            out=$(gh api graphql -F projectId="$pid" --jq "$jq_page" -f query="$query" 2>/dev/null)
        else
            out=$(gh api graphql -F projectId="$pid" -f after="$cursor" --jq "$jq_page" -f query="$query" 2>/dev/null)
        fi || { echo "warn: session-id-field: view list failed; add '$SESSION_ID_FIELD_NAME' to board views by hand" >&2; return 0; }
        has_next="false" next=""
        while IFS= read -r line; do
            line="${line%$'\r'}"
            case "$line" in
                V$'\t'*) updates+=("${line#V$'\t'}") ;;
                P$'\t'*) line="${line#P$'\t'}"; has_next="${line%%$'\t'*}"; next="${line#*$'\t'}" ;;
            esac
        done <<<"$out"
        if [ "$has_next" != "true" ] || [ -z "$next" ] || [ "$next" = "$cursor" ]; then break; fi
        cursor="$next"
    done
    local entry id
    local -a args
    for entry in ${updates[@]+"${updates[@]}"}; do
        IFS=$'\t' read -r vid layout truncated ids <<<"$entry"
        [ "$layout" = "BOARD_LAYOUT" ] || continue
        case ",$ids," in *",$fid,"*) continue ;; esac
        if [ "$truncated" = "true" ]; then
            echo "warn: session-id-field: view $vid shows more than one page of fields; not updated, add '$SESSION_ID_FIELD_NAME' to it by hand" >&2
            continue
        fi
        echo "info: session-id-field: view $vid visibleFieldIds before update: ${ids:-<none>}" >&2
        args=()
        if [ -n "$ids" ]; then
            while IFS= read -r id; do [ -n "$id" ] && args+=(-f "ids[]=$id"); done <<<"${ids//,/$'\n'}"
        fi
        args+=(-f "ids[]=$fid")
        if ! gh api graphql -f viewId="$vid" "${args[@]}" \
                -f query='mutation($viewId:ID!,$ids:[ID!]!){updateProjectV2View(input:{viewId:$viewId,configuration:{visibleFieldIds:$ids}}){projectV2View{id}}}' \
                >/dev/null 2>&1; then
            echo "warn: session-id-field: could not show '$SESSION_ID_FIELD_NAME' in view $vid; add it by hand" >&2
        fi
    done
    return 0
}
