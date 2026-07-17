#!/usr/bin/env bash
# Determine whether $PWD is a linked worktree, the main worktree, or not in a git repo.
# stdout: linked | main | unknown
# exit: always 0
set -uo pipefail

# Not in a git repo
git rev-parse --git-dir >/dev/null 2>&1 || { echo "unknown"; exit 0; }

PWD_REAL=$(cd -P "$PWD" 2>/dev/null && pwd -P || pwd)

MAIN_WORKTREE=""
CURRENT_WORKTREE=""
STATE=""   # "main" or "linked" for current stanza
STANZA_PATH=""

while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      STANZA_PATH="${line#worktree }"
      # First stanza is always the main worktree
      if [[ -z "$MAIN_WORKTREE" ]]; then
        STATE="main"
        MAIN_WORKTREE="$STANZA_PATH"
      else
        STATE="linked"
      fi
      ;;
    "")
      # End of stanza — check if this stanza matches PWD
      if [[ -n "$STANZA_PATH" ]]; then
        STANZA_REAL=$(cd -P "$STANZA_PATH" 2>/dev/null && pwd -P 2>/dev/null || echo "")
        if [[ -n "$STANZA_REAL" && "$STANZA_REAL" == "$PWD_REAL" ]]; then
          CURRENT_WORKTREE="$STATE"
        fi
      fi
      STATE=""
      STANZA_PATH=""
      ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)

# Handle last stanza (no trailing blank line in some git versions)
if [[ -n "$STANZA_PATH" && -n "$STATE" ]]; then
  STANZA_REAL=$(cd -P "$STANZA_PATH" 2>/dev/null && pwd -P 2>/dev/null || echo "")
  if [[ -n "$STANZA_REAL" && "$STANZA_REAL" == "$PWD_REAL" ]]; then
    CURRENT_WORKTREE="$STATE"
  fi
fi

echo "${CURRENT_WORKTREE:-unknown}"
exit 0
