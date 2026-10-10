#!/usr/bin/env bash
# relocate-session-state.sh — SC-9: move this session's legacy state into ~/.workflow-state.
#
# Usage: relocate-session-state.sh <session-id>
# Prints the one bin/state-dir-relocation line. A failure is reported to the supervisor
# only when the mover says report=first, so re-running /session-close warns once per session.
# Advisory: always exits 0.
# --- BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration added 2026-10-04 ---
# deletion-condition: remove when bin/state-dir-relocation remaining exits 0 (no session with a <sid>.json or <sid>.control left in the legacy dir, any sid shape); also delete skills/session-close SC-9; review by 2027-01-04
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SESSION_ID="${1-}"
if [[ -z "$SESSION_ID" ]]; then
  echo "relocate-session-state: session-id required" >&2
  exit 0
fi

RELOCATE_OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/state-dir-relocation" move --session "$SESSION_ID" || true)"
printf '%s\n' "$RELOCATE_OUT"

if [[ "$RELOCATE_OUT" == RELOCATE_FAILED* && "$RELOCATE_OUT" == *report=first* ]]; then
  node "$SCRIPT_CHECKOUT_ROOT/bin/supervisor-report" --categories workflow --severity warning \
    --detail "session state relocation to ~/.workflow-state failed: $RELOCATE_OUT" \
    --reporter session-close --session-id "$SESSION_ID" >/dev/null 2>&1 || true
fi
exit 0
# --- END temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration ---
