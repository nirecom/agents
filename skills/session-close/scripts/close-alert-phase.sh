#!/usr/bin/env bash
# close-alert-phase.sh — settle the supervisor alert/audit phase at session close.
#
# Usage: close-alert-phase.sh <session-id> [worktree-notes-backup-path]
# Extracted from skills/session-close/SKILL.md SC-6 so the prompt issues one
# standalone command instead of an awk capture plus an `if` block (#2132).
# Advisory: always exits 0; a refused writer call is reported, never hidden (#2766).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SESSION_ID="${1:?session-id required}"
NOTES_BACKUP="${2-}"

# run_or_report <label> <cmd...> — run cmd; on a non-zero exit say so on stderr and file one report.
run_or_report() {
    local label="$1" rc=0
    shift
    "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "close-alert-phase: $label refused (exit $rc)" >&2
        node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-report" --categories workflow --severity warning \
            --detail "$label refused at session close" --reporter session-close || true
    fi
    return 0
}

run_or_report "alert close" node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-alert" \
    --session-id "$SESSION_ID" --set-alert-phase closed

# The notes backup carries the session id the WORKTREE recorded, which differs
# from the closing session's own id whenever the work spanned two sessions.
WSID=""
if [ -n "$NOTES_BACKUP" ] && [ -f "$NOTES_BACKUP" ]; then
    WSID="$(awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' \
        "$NOTES_BACKUP" 2>/dev/null || true)"
fi
if [ -n "$WSID" ] && [ "$WSID" != "$SESSION_ID" ]; then
    run_or_report "worktree-session alert close" node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-alert" \
        --session-id "$WSID" --set-alert-phase closed --clear-alert-armed-at
fi

run_or_report "audit clear" node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit" \
    --clear-audit-phase --session-id "$SESSION_ID"

exit 0
