#!/bin/bash
# bin/github-issues/wip-state/cmd-set.sh — Verb: set <N>.
# Sourced by ../wip-state.sh; not executable standalone.
# Writes the raw session id to the session-id field, then Status=In Progress (that order; both
#   hard-fail with exit 1). The lock file is warn-and-continue. The only verb that may recover
#   (rename or create) the session-id field: docs/architecture/wip-signaling.md.

# _set_write_session_id <item-id> <sid> — one --text write to WIP_STATE_SESSION_ID_FIELD_ID.
_set_write_session_id() {
    gh project item-edit --id "$1" \
        --field-id "$WIP_STATE_SESSION_ID_FIELD_ID" \
        --project-id "$PROJECT_ID" \
        --text "$2" >/dev/null 2>&1
}

# _set_session_id_unavailable — the exit for a project whose field cannot be obtained.
_set_session_id_unavailable() {
    echo "Error: session-id field unavailable for this project" >&2
    echo "Hint: grant project scope ('gh auth refresh -s project') or run /issue-setup; WIP for this issue is skipped (rc=1, workflow continues)" >&2
    exit 1
}
cmd_set() {
    local n="$1"
    validate_n "$n"
    ensure_wip_field_ids
    preflight_field_ids

    if ! ensure_resolved; then
        echo "Error: cannot resolve Projects v2 config for this repo (no linked project, or 'gh repo view' failed)" >&2
        echo "Hint: link a Projects v2 to this repo at github.com (Settings → Projects)" >&2
        # Without a project the session-id field cannot be recovered either; say so when it is missing.
        [ -n "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ] || _set_session_id_unavailable
        exit 1
    fi

    local sid
    if ! sid=$(effective_session_id); then
        exit 2
    fi

    if [ -z "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ]; then
        if ! wip_recover_session_id_field; then
            _set_session_id_unavailable
        fi
    fi

    local item_id
    item_id=$(resolve_item_id "$n") || item_id=""

    if [ -z "$item_id" ]; then
        # Issue not in project — add it.
        local url
        if ! url=$(gh issue view "$n" ${REPO_OVERRIDE:+--repo "$REPO_OVERRIDE"} --json url --jq '.url' 2>/dev/null); then
            echo "Error: cannot resolve URL for issue #$n (check repo context / gh auth)" >&2
            exit 1
        fi
        url=$(printf '%s' "$url" | tr -d '\r' | head -1)
        if [ -z "$url" ]; then
            echo "Error: gh issue view returned empty URL for #$n" >&2
            exit 1
        fi
        local add_out
        if add_out=$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$url" \
                --format json --jq '.id' 2>&1); then
            item_id="$add_out"
        else
            # Duplicate-add race: refetch once.
            item_id=$(resolve_item_id "$n") || item_id=""
            if [ -z "$item_id" ]; then
                echo "Error: project item-add failed and refetch empty for #$n" >&2
                exit 1
            fi
        fi
    fi

    # Session-id write (hard-fail; precedes Status). A write to a field that no longer exists is
    # re-resolved (recovering when the fresh id is empty) and retried exactly once.
    if ! _set_write_session_id "$item_id" "$sid"; then
        local retried=0
        if wip_reresolve_session_id_field_if_missing "$WIP_STATE_SESSION_ID_FIELD_ID"; then
            if [ -z "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ]; then
                wip_recover_session_id_field || _set_session_id_unavailable
            fi
            _set_write_session_id "$item_id" "$sid" && retried=1
        fi
        if [ "$retried" -ne 1 ]; then
            echo "[wip-state: session-id write failed for #$n]" >&2
            exit 1
        fi
    fi

    # Status set (hard-fail).
    if ! gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_STATUS_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --single-select-option-id "$WIP_STATE_IN_PROGRESS_OPTION_ID" >/dev/null 2>&1; then
        echo "[wip-state: Status set failed for #$n]" >&2
        exit 1
    fi

    # Lock file (warn-and-continue — non-canonical per intent.md §1a).
    if ! write_lock_file "$n" "$sid"; then
        echo "[wip-state: lock-file write failed for #$n (continuing)]" >&2
    fi

    exit 0
}
