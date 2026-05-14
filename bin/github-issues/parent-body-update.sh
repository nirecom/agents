#!/bin/bash
# parent-body-update.sh <owner/repo> <N>
#
# If issue <N> has a parent issue, flip `- [ ] #<N>` to `- [x] #<N>` in the
# parent's body. No-op when there is no parent.
#
# Security notes:
# - <N> must be digits-only (validated by /issue-close before calling).
# - PARENT_BODY is treated as opaque text and passed as a single argv to
#   `gh issue edit --body` — it cannot escape into the shell.
# - The match uses a word boundary (`\b`) so `#42` does not match `#420`.
#
# Concurrency caveat: read-modify-write is not atomic. A concurrent edit to
# the parent body between fetch and write will be lost. Acceptable for
# single-user, low-churn use.

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Error: usage: parent-body-update.sh <owner/repo> <N>" >&2
    exit 1
fi

REPO="$1"
N="$2"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only (got: $N)" >&2
    exit 1
fi

PARENT=$(gh api "repos/${REPO}/issues/${N}" --jq '.parent.number // empty')
if [ -z "$PARENT" ]; then
    exit 0
fi

PARENT_BODY=$(gh issue view "$PARENT" --json body --jq .body)
NEW_BODY=$(printf '%s' "$PARENT_BODY" \
    | perl -pe "s/- \\[ \\] #${N}\\b/- [x] #${N}/g")
ISSUE_CLOSE_SKILL=1 gh issue edit "$PARENT" --body "$NEW_BODY"
