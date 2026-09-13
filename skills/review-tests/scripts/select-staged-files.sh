#!/usr/bin/env bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
# --added-only narrows the listing to newly ADDED paths (#2075). review-tests'
# append-vs-new check only ever applies to a test file that was just created: a
# Modified path is the result of an append that already happened, so it carries
# no missed-append signal. Default output is unchanged.
ADDED_ONLY=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --added-only) ADDED_ONLY=1; shift ;;
    *) echo "[review-tests] ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done
DIFF_FILTER=()
if [[ "$ADDED_ONLY" -eq 1 ]]; then
  DIFF_FILTER=(--diff-filter=A)
fi
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
  git diff --cached ${DIFF_FILTER[@]+"${DIFF_FILTER[@]}"} --name-only
  exit 0
elif [[ -z "$WORKTREE" ]]; then
  # Resolution failed (main worktree rejected or session state missing).
  # Do NOT fall back to CWD — emit explicit skip signal.
  exit 3
fi
# Linked worktree resolved: list staged files in that worktree only.
git -C "$WORKTREE" diff --cached ${DIFF_FILTER[@]+"${DIFF_FILTER[@]}"} --name-only
