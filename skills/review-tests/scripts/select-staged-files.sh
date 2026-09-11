#!/usr/bin/env bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
# Resolve the CC session id explicitly (SSOT: bin/resolve-session-id), then hand it
# to the worktree resolver via --session. Only rc 2 means "no session" and omits the
# flag; any other rc is a bridge fault and halts with exit 4 (distinct from the
# exit 3 "worktree unresolvable" path below).
BRIDGE_RC=0
CC_SID="$("$AGENTS_CONFIG_DIR/bin/resolve-session-id")" || BRIDGE_RC=$?
case "$BRIDGE_RC" in
  0) ;;
  2) CC_SID="" ;;
  *) echo "[review-tests] ERROR: bin/resolve-session-id failed (rc $BRIDGE_RC)" >&2; exit 4 ;;
esac
WORKTREE="$("$AGENTS_CONFIG_DIR/bin/resolve-worktree-path" ${CC_SID:+--session "$CC_SID"})"
if [[ "$WORKTREE" == "NOSTATE" ]]; then
  # Test fixture / first-run: no session state. Use CWD as fallback.
  git diff --cached --name-only
  exit 0
elif [[ -z "$WORKTREE" ]]; then
  # Resolution failed (main worktree rejected or session state missing).
  # Do NOT fall back to CWD — emit explicit skip signal.
  exit 3
fi
# Linked worktree resolved: list staged files in that worktree only.
git -C "$WORKTREE" diff --cached --name-only
