#!/bin/bash
# bin/github-issues/wip-state/cmd-clear.sh — Verb: clear <N>.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, WIP_STATE_* (env).
# Functions consumed: validate_n, preflight_field_ids, ensure_resolved,
#   resolve_item_id, delete_lock_file.

# ---------------------------------------------------------------------------
# Verb: clear <N>
#   Status=Done + clear the session-id value + delete lock. Uniformly warn-and-continue
#   on gh failures (canonical close already happened upstream).
# ---------------------------------------------------------------------------
cmd_clear() {
    local n="$1"
    validate_n "$n"
    # State guard: skip all Projects v2 mutations on OPEN issues (or gh failure).
    # Setting Status=Done on an OPEN issue triggers GitHub's auto-close workflow.
    local _clear_dir
    _clear_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _issue_state
    if _issue_state=$(bash "$_clear_dir/../issue-state-check.sh" "$n" 2>/dev/null); then
        :
    else
        _issue_state="error"
    fi
    if [ "$_issue_state" != "closed" ]; then
        delete_lock_file "$n"
        exit 0
    fi
    ensure_wip_field_ids
    preflight_field_ids

    # clear is non-fatal: when no project is linked, still try to remove the
    # local lock file and exit 0 (the canonical close already happened upstream).
    if ! ensure_resolved; then
        delete_lock_file "$n"
        exit 0
    fi

    local item_id
    if ! item_id=$(resolve_item_id "$n"); then
        item_id=""
    fi
    if [ -z "$item_id" ]; then
        delete_lock_file "$n"
        exit 0
    fi

    if ! gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_STATUS_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --single-select-option-id "$WIP_STATE_DONE_OPTION_ID" >/dev/null 2>&1; then
        echo "[wip-state: Status=Done set failed for #$n (continuing)]" >&2
    fi

    # Empty the session-id value (skipped when no field exists; one re-resolved retry).
    if ! wip_clear_session_id_text "$item_id"; then
        echo "[wip-state: session-id clear failed for #$n (continuing)]" >&2
    fi

    delete_lock_file "$n"
    exit 0
}
