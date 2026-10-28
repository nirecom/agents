#!/usr/bin/env bash
# migrate-own-session-chain.sh — SC-10: fold every orphan progress file of this session chain into the
# first generation's progress file (bin/migrate-orphan-progress-files --session).
#
# Usage: migrate-own-session-chain.sh <session-id>
# Advisory: always exits 0; a failure is one stderr line. No CLI (already deleted): does nothing.
# --- BEGIN temporary: orphan progress file -> first_session_id progress file migration added 2026-10-24 ---
# deletion-condition: remove after 2026-11-22 (plans retention 30 days) together with bin/migrate-orphan-progress-files, hooks/lib/temporary-migrations/orphan-progress-file/, skills/session-close/scripts/migrate-own-session-chain.sh, skills/session-close SC-10, tests/bin/fix-2748-orphan-progress-migration-{merge,session,failure}.js and tests/bin/fix-2748-orphan-progress-migration/
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLI="$SCRIPT_CHECKOUT_ROOT/bin/migrate-orphan-progress-files"
SESSION_ID="${1-}"

[[ -f "$CLI" ]] || exit 0
if [[ -z "$SESSION_ID" ]]; then
  echo "migrate-own-session-chain: session-id required" >&2
  exit 0
fi

RC=0
OUT="$(node "$CLI" --apply --include-active --session "$SESSION_ID" 2>&1)" || RC=$?
if [[ "$RC" -eq 0 ]]; then
  [[ -z "$OUT" ]] || printf '%s\n' "$OUT"
else
  LAST="$(printf '%s\n' "$OUT" | tail -n 1)"
  echo "migrate-own-session-chain: migration failed (exit $RC)${LAST:+: $LAST}" >&2
fi
exit 0
# --- END temporary: orphan progress file -> first_session_id progress file migration ---
