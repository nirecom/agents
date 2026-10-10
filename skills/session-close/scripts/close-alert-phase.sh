#!/usr/bin/env bash
# close-alert-phase.sh — settle the supervisor alert/audit phase at session close.
#
# Usage: close-alert-phase.sh <session-id> [worktree-notes-backup-path]
# Extracted from skills/session-close/SKILL.md SC-6 so the prompt issues one
# standalone command instead of an awk capture plus an `if` block (#2132).
# Advisory: always exits 0.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SESSION_ID="${1:?session-id required}"
NOTES_BACKUP="${2-}"

node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-alert" \
    --session-id "$SESSION_ID" --set-alert-phase closed || true

# The notes backup carries the session id the WORKTREE recorded, which differs
# from the closing session's own id whenever the work spanned two sessions.
WSID=""
if [ -n "$NOTES_BACKUP" ] && [ -f "$NOTES_BACKUP" ]; then
    WSID="$(awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' \
        "$NOTES_BACKUP" 2>/dev/null || true)"
fi
if [ -n "$WSID" ] && [ "$WSID" != "$SESSION_ID" ]; then
    node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-alert" \
        --session-id "$WSID" --set-alert-phase closed --clear-alert-armed-at || true
fi

node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-write-audit" \
    --clear-audit-phase --session-id "$SESSION_ID" || true

exit 0
