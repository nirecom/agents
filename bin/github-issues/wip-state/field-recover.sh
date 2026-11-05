# wip-state/field-recover.sh — session-id field recovery for wip-state.sh verbs (sourced).
# Contract (tests/bin/feature-2925-wip-session-id-recover.sh G5-*):
#   - wip_recover_session_id_field (rename legacy, else create) is called only from cmd-set.sh;
#   - _wip_rename_legacy_session_field is called only inside wip_recover_session_id_field;
#   - wip_reresolve_session_id_field_if_missing never creates or renames (every verb may call it).
# Not sourced by lib/resolve-project.sh, so no other consumer can reach the recover path.
# Design: docs/architecture/wip-signaling.md.

# _wip_rename_legacy_session_field <pid> — prints the session-id field id.
# rc 0: session-id already present (no rename), or the legacy field renamed in place.
# rc 1: field list or rename failed. rc 3: neither field exists.
_wip_rename_legacy_session_field() {
    local pid="$1" id rc
    id="$(session_id_field_find "$pid" "$SESSION_ID_FIELD_NAME")"; rc=$?
    [ "$rc" -eq 2 ] && return 1
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$id"
        return 0
    fi
    id="$(session_id_field_find "$pid" "$LEGACY_SESSION_FIELD_NAME")"; rc=$?
    [ "$rc" -eq 2 ] && return 1
    [ "$rc" -eq 0 ] || return 3
    if ! gh api graphql -f fieldId="$id" -f name="$SESSION_ID_FIELD_NAME" \
            -f query='mutation($fieldId:ID!,$name:String!){updateProjectV2Field(input:{fieldId:$fieldId,name:$name}){projectV2Field{...on ProjectV2FieldCommon{id}}}}' \
            >/dev/null 2>&1; then
        echo "warn: wip-state: renaming field '$LEGACY_SESSION_FIELD_NAME' to '$SESSION_ID_FIELD_NAME' failed" >&2
        return 1
    fi
    echo "info: wip-state: renamed field '$LEGACY_SESSION_FIELD_NAME' to '$SESSION_ID_FIELD_NAME' ($id)" >&2
    printf '%s\n' "$id"
    return 0
}

# wip_recover_session_id_field — `set` only. Find, rename, or create the session-id field on
# RESOLVED_PROJECT_ID; on rc 0 sets WIP_STATE_/RESOLVED_SESSION_ID_FIELD_ID and rewrites the
# cache row (warn-only). rc 1 when no field id could be obtained.
wip_recover_session_id_field() {
    local pid="${RESOLVED_PROJECT_ID:-${PROJECT_ID:-}}" id rc
    [ -n "$pid" ] || return 1
    id="$(_wip_rename_legacy_session_field "$pid")"; rc=$?
    if [ "$rc" -eq 3 ]; then
        session_id_field_create_if_absent "$pid" || return 1
        id="$SESSION_ID_FIELD_ENSURED_ID"
    elif [ "$rc" -ne 0 ]; then
        return 1
    fi
    id="$(printf '%s' "$id" | tr -d '\r' | head -1)"
    [ -n "$id" ] || return 1
    WIP_STATE_SESSION_ID_FIELD_ID="$id"
    RESOLVED_SESSION_ID_FIELD_ID="$id"
    if [ -n "${RESOLVED_CACHE_KEY:-}" ]; then
        local cache_file
        if cache_file="$(_resolve_project_cache_file)"; then
            _resolve_project_write_cache "$(dirname "$cache_file")" "$cache_file" "$RESOLVED_CACHE_KEY" \
                "$RESOLVED_OWNER" "$RESOLVED_PROJECT_NUM" "$RESOLVED_PROJECT_ID" \
                "$RESOLVED_CONTENT_DATE_FIELD_ID" "$RESOLVED_STATUS_FIELD_ID" \
                "$RESOLVED_TODO_OPTION_ID" "$RESOLVED_IN_PROGRESS_OPTION_ID" \
                "$RESOLVED_DONE_OPTION_ID" "$id" || true
        fi
    fi
    return 0
}

# wip_reresolve_session_id_field_if_missing <fid> — after a failed write to <fid>: when the field
# no longer exists, drop the cache row (warn-only), fetch fresh, and replace
# WIP_STATE_SESSION_ID_FIELD_ID with the resolver's id (may be empty; env override ignored). rc 0.
# rc 1 (no retry): the field exists, the existence query failed, or the re-resolve failed.
wip_reresolve_session_id_field_if_missing() {
    local fid="$1" pid="${PROJECT_ID:-${RESOLVED_PROJECT_ID:-}}"
    [ -n "$fid" ] && [ -n "$pid" ] || return 1
    project_field_id_exists "$pid" "$fid"
    [ $? -eq 1 ] || return 1
    if [ -n "${RESOLVED_CACHE_KEY:-}" ]; then
        resolve_project_drop_cache_row "$RESOLVED_CACHE_KEY" \
            || echo "warn: wip-state: could not drop the stale cache row; fetching fresh anyway" >&2
    fi
    resolve_project_for_repo --require-wip-fields --no-cache-read || return 1
    WIP_STATE_SESSION_ID_FIELD_ID="$RESOLVED_SESSION_ID_FIELD_ID"
    echo "info: wip-state: session-id field $fid is gone; re-resolved to '${WIP_STATE_SESSION_ID_FIELD_ID:-<none>}'" >&2
    return 0
}

# _wip_clear_text_once <item-id> — rc 0 cleared or already empty (gh's "no changes to make"), 1 failed.
_wip_clear_text_once() {
    local err rc
    err=$(gh project item-edit --id "$1" \
            --field-id "$WIP_STATE_SESSION_ID_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --text "" 2>&1 >/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    printf '%s' "$err" | grep -q "no changes to make" && return 0
    return 1
}

# wip_clear_session_id_text <item-id> — clear/abandon: empty the session-id value. rc 0 when cleared,
# already empty, or no field exists (before or after a re-resolve); one retry after a re-resolve.
# rc 1 when the value could not be cleared. Never creates or renames the field.
wip_clear_session_id_text() {
    local item="$1"
    [ -n "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ] || return 0
    _wip_clear_text_once "$item" && return 0
    wip_reresolve_session_id_field_if_missing "$WIP_STATE_SESSION_ID_FIELD_ID" || return 1
    [ -n "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ] || return 0
    _wip_clear_text_once "$item"
}
