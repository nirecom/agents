#!/bin/bash
# bin/github-issues/wip-state/cmd-clear.sh — Verb: clear <N>.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, WIP_STATE_* (env).
# Functions consumed: validate_n, preflight_field_ids, ensure_resolved,
#   resolve_item_id, delete_lock_file.

# ---------------------------------------------------------------------------
# Verb: clear <N>
#   Status=Done + clear fingerprint + delete lock. Uniformly warn-and-continue
#   on gh failures (canonical close already happened upstream).
# ---------------------------------------------------------------------------
cmd_clear() {
    local n="$1"
    validate_n "$n"
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

    # When the fingerprint field is already empty, gh project item-edit
    # --text "" returns rc=1 with stderr "no changes to make for the
    # item-edit". That is the expected no-op outcome — suppress the warning.
    # Success path (rc=0) is the normal case (field had a fingerprint to
    # clear) and falls through silently.
    local fp_clear_err
    fp_clear_err=$(gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_FINGERPRINT_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --text "" 2>&1 >/dev/null)
    local fp_clear_rc=$?
    if [ "$fp_clear_rc" -eq 0 ]; then
        : # fingerprint cleared successfully (normal path)
    elif printf '%s' "$fp_clear_err" | grep -q "no changes to make"; then
        : # field was already empty — canonical gh no-op signal
    else
        echo "[wip-state: fingerprint clear failed for #$n (continuing)]" >&2
    fi

    delete_lock_file "$n"
    exit 0
}
