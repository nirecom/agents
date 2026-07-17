#!/bin/bash
# bin/github-issues/wip-state/cmd-abandon.sh — Verb: abandon <N>.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, WIP_STATE_* (env).
# Functions consumed: validate_n, preflight_field_ids, ensure_resolved,
#   resolve_item_id, delete_lock_file.

# ---------------------------------------------------------------------------
# Verb: abandon <N>
#   Status=Todo + clear fingerprint + delete lock. HARD failure on gh errors.
#   Only operates on OPEN issues; closed/error state exits 1.
# ---------------------------------------------------------------------------
cmd_abandon() {
    local n="$1"
    validate_n "$n"
    local _abandon_dir
    _abandon_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _issue_state
    if _issue_state=$(bash "$_abandon_dir/../issue-state-check.sh" ${REPO_OVERRIDE:+--repo "$REPO_OVERRIDE"} "$n" 2>/dev/null); then
        :
    else
        _issue_state="error"
    fi
    if [ "$_issue_state" = "closed" ]; then
        echo "[wip-state: abandon on CLOSED issue #$n — skipping (use clear instead)]" >&2
        exit 1
    fi
    if [ "$_issue_state" = "error" ]; then
        echo "[wip-state: cannot determine state for #$n — skipping abandon]" >&2
        exit 1
    fi
    ensure_wip_field_ids
    preflight_field_ids
    if ! ensure_resolved; then
        echo "[wip-state: project not resolved for #$n — abandon failed]" >&2
        exit 1
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
            --single-select-option-id "$WIP_STATE_TODO_OPTION_ID" >/dev/null 2>&1; then
        echo "[wip-state: Status=Todo set failed for #$n]" >&2
        exit 1
    fi
    local fp_clear_err
    fp_clear_err=$(gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_FINGERPRINT_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --text "" 2>&1 >/dev/null)
    local fp_clear_rc=$?
    if [ "$fp_clear_rc" -eq 0 ]; then
        :
    elif printf '%s' "$fp_clear_err" | grep -q "no changes to make"; then
        :
    else
        echo "[wip-state: fingerprint clear failed for #$n]" >&2
        exit 1
    fi
    delete_lock_file "$n"
    exit 0
}
