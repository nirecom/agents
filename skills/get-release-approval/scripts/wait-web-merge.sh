#!/usr/bin/env bash
# get-release-approval web-merge poller (#2527 4-5): waits, in the background, for the human
# to merge (or close) the pull request on the web.
# Usage: bash wait-web-merge.sh --session <sid> --repo <worktree> [--interval s] [--max-failures N] [--deadline s]
# Stdout: exactly one WEB_MERGE=merged|closed|error|timeout|already-running line; always exit 0
#   (a usage error too, as WEB_MERGE=error with the reason on stderr).
# One poller per session: $WORKFLOW_STATE_DIR/web-merge-poller-<sid>.pid holds the live pid.
# It runs outside the worktree so worktree-end can remove that directory while it waits.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SID=""
REPO=""
INTERVAL=30        # seconds between polls
MAX_FAILURES=10    # consecutive unreadable answers before giving up
DEADLINE=3600      # seconds before giving up on the human
BACKOFF_CAP=300    # a rate-limited interval doubles up to this many seconds

finish() {
  printf 'WEB_MERGE=%s\n' "$1"
  exit 0
}
fail_usage() {
  printf 'wait-web-merge: %s\n' "$1" >&2
  finish error
}
is_count() { [[ "$1" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session|--repo|--interval|--max-failures|--deadline)
      [[ $# -ge 2 ]] || fail_usage "$1 requires a value"
      case "$1" in
        --session) SID="$2" ;;
        --repo) REPO="$2" ;;
        --interval) INTERVAL="$2" ;;
        --max-failures) MAX_FAILURES="$2" ;;
        --deadline) DEADLINE="$2" ;;
      esac
      shift 2 ;;
    *) fail_usage "unknown argument $1" ;;
  esac
done
[[ "$SID" =~ ^[A-Za-z0-9_-]+$ ]] || fail_usage "--session is required and must match ^[A-Za-z0-9_-]+$"
[[ -n "$REPO" ]] || fail_usage "--repo is required"
is_count "$INTERVAL" || fail_usage "--interval must be a non-negative integer"
[[ "$MAX_FAILURES" =~ ^[1-9][0-9]*$ ]] || fail_usage "--max-failures must be a positive integer"
is_count "$DEADLINE" || fail_usage "--deadline must be a non-negative integer"
[[ -d "$REPO" ]] || fail_usage "--repo directory does not exist: $REPO"

STATE_DIR="${WORKFLOW_STATE_DIR:-$HOME/.workflow-state}"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/web-merge-poller-$SID.pid"
if [[ -s "$PID_FILE" ]]; then
  OLD_PID="$(head -n 1 "$PID_FILE" 2>/dev/null || true)"
  if [[ "$OLD_PID" =~ ^[0-9]+$ && "$OLD_PID" != "$$" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    finish already-running
  fi
fi
printf '%s\n' "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# Off the worktree: a cwd inside it would keep worktree-end from removing the directory.
cd "$HOME" 2>/dev/null || cd /

ERR_FILE="$(mktemp)"
trap 'rm -f "$PID_FILE" "$ERR_FILE"' EXIT

START=$SECONDS
CUR_INTERVAL="$INTERVAL"
FAILURES=0
LAST_ERR=""
while :; do
  OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/pr-state" --repo "$REPO" --merge-state 2>"$ERR_FILE" || true)"
  STATE="$(printf '%s\n' "$OUT" | sed -n 's/^PR_STATE=//p' | head -n 1)"
  case "$STATE" in
    MERGED) finish merged ;;
    CLOSED) finish closed ;;
    OPEN)
      FAILURES=0
      CUR_INTERVAL="$INTERVAL" ;;
    *)
      FAILURES=$((FAILURES + 1))
      LAST_ERR="$(cat "$ERR_FILE" 2>/dev/null || true)"
      [[ -n "$LAST_ERR" ]] || LAST_ERR="pr-state answered PR_STATE=${STATE:-<none>}"
      if [[ "$FAILURES" -ge "$MAX_FAILURES" ]]; then
        printf 'wait-web-merge: %s consecutive failed PR reads; last: %s\n' "$FAILURES" "$LAST_ERR" >&2
        finish error
      fi
      if printf '%s' "$LAST_ERR" | grep -Eiq 'rate limit|403|429'; then
        CUR_INTERVAL=$((CUR_INTERVAL * 2))
        [[ "$CUR_INTERVAL" -ge 1 ]] || CUR_INTERVAL=1
        [[ "$CUR_INTERVAL" -le "$BACKOFF_CAP" ]] || CUR_INTERVAL="$BACKOFF_CAP"
      fi ;;
  esac
  [[ $((SECONDS - START)) -lt "$DEADLINE" ]] || finish timeout
  sleep "$CUR_INTERVAL"
done
