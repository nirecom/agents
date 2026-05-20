#!/bin/bash
# parent-ancestor-reopen.sh <owner/repo> <N>
#
# Starting from issue <N>, traverse .parent.number up the chain and reopen
# every CLOSED ancestor. No-op when the issue has no parent.
#
# Exit 0: success (including 0 reopens).
# Exit 1: validation/API error, or at least one reopen failed (loop continues).

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Error: usage: parent-ancestor-reopen.sh <owner/repo> <N>" >&2
    exit 1
fi

REPO="$1"
N="$2"

if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: repo must be in owner/name format, got: $REPO" >&2
    exit 1
fi

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: invalid issue number (must be digits only), got: $N" >&2
    exit 1
fi

FAIL=0
DEPTH=0
CURRENT="$N"

while true; do
    if [ "$DEPTH" -gt 50 ]; then
        echo "WARN: ancestor chain depth limit reached at depth $DEPTH (stopped at #${CURRENT})" >&2
        break
    fi

    PARENT_NUM=$(gh api "repos/$REPO/issues/$CURRENT" --jq '.parent.number // empty' 2>/dev/null)
    if [ -z "$PARENT_NUM" ]; then
        break
    fi

    PARENT_STATE=$(gh issue view "$PARENT_NUM" --json state --jq '.state' 2>/dev/null)
    if [ "$PARENT_STATE" = "CLOSED" ]; then
        if ! gh issue reopen "$PARENT_NUM" 2>/dev/null; then
            echo "WARN: failed to reopen issue #${PARENT_NUM}" >&2
            FAIL=1
        fi
    fi

    CURRENT="$PARENT_NUM"
    DEPTH=$((DEPTH + 1))
done

exit "$FAIL"
