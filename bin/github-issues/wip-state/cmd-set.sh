#!/bin/bash
# bin/github-issues/wip-state/cmd-set.sh — Verb: set <N>.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, OWNER, PROJECT_NUM, WIP_STATE_* (env).
# Functions consumed: validate_n, preflight_field_ids, ensure_resolved,
#   effective_session_id, compute_fingerprint, resolve_item_id, write_lock_file.

# ---------------------------------------------------------------------------
# Verb: set <N>
#   Ordering invariant: fingerprint write BEFORE Status set. Both hard-fail
#   (exit 1) on gh error. Lock file is sync-visibility only — warn-and-continue.
# ---------------------------------------------------------------------------
cmd_set() {
    local n="$1"
    validate_n "$n"
    preflight_field_ids

    if ! ensure_resolved; then
        echo "Error: cannot resolve Projects v2 config for this repo (no linked project, or 'gh repo view' failed)" >&2
        echo "Hint: link a Projects v2 to this repo at github.com (Settings → Projects)" >&2
        exit 1
    fi

    local sid
    if ! sid=$(effective_session_id); then
        exit 2
    fi
    local fp
    fp=$(compute_fingerprint "$sid" "$n")

    local item_id
    item_id=$(resolve_item_id "$n") || item_id=""

    if [ -z "$item_id" ]; then
        # Issue not in project — add it.
        local url
        if ! url=$(gh issue view "$n" --json url --jq '.url' 2>/dev/null); then
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

    # Fingerprint write (hard-fail; precedes Status).
    if ! gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_FINGERPRINT_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --text "$fp" >/dev/null 2>&1; then
        echo "[wip-state: fingerprint write failed for #$n]" >&2
        exit 1
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
