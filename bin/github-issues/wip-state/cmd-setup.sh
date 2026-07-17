#!/bin/bash
# bin/github-issues/wip-state/cmd-setup.sh — Verb: setup (DEPRECATED).
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, OWNER, PROJECT_NUM, WIP_STATE_*.
# Functions consumed: ensure_resolved, ensure_wip_field_ids.

# ---------------------------------------------------------------------------
# Verb: setup (DEPRECATED)
#   Field IDs are now resolved on demand by resolve-project.sh and cached per
#   repo — no longer persisted to .env. This verb only reports the IDs the
#   resolver discovers (informational); it never writes .env.
# ---------------------------------------------------------------------------
cmd_setup() {
    echo "warn: 'wip-state.sh setup' is deprecated." >&2
    echo "warn: Field IDs are now resolved and cached on demand by resolve-project.sh." >&2
    echo "warn: No .env write is performed. The following is informational only." >&2

    if ensure_resolved; then
        ensure_wip_field_ids
        cat <<EOF
WIP_STATE_STATUS_FIELD_ID=${WIP_STATE_STATUS_FIELD_ID:-}
WIP_STATE_TODO_OPTION_ID=${WIP_STATE_TODO_OPTION_ID:-}
WIP_STATE_IN_PROGRESS_OPTION_ID=${WIP_STATE_IN_PROGRESS_OPTION_ID:-}
WIP_STATE_DONE_OPTION_ID=${WIP_STATE_DONE_OPTION_ID:-}
WIP_STATE_FINGERPRINT_FIELD_ID=${WIP_STATE_FINGERPRINT_FIELD_ID:-}
EOF
    fi
    exit 0
}
