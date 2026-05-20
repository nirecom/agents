#!/bin/bash
# parent-all-closed-check.sh <owner/repo> <N>
#
# Check whether all sub-issues of issue <N> are closed.
#
# Exit 0: all sub-issues are closed.
# Exit 1: one or more sub-issues are open.
# Exit 2: issue <N> has no sub-issues (0 children).
# Exit 3: validation error or gh API failure.

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Error: usage: parent-all-closed-check.sh <owner/repo> <N>" >&2
    exit 3
fi

REPO="$1"
N="$2"

if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: repo must be in owner/name format, got: $REPO" >&2
    exit 3
fi

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $N" >&2
    exit 3
fi

# Fetch open count and total count in a single paginated pass.
# --paginate emits one JSON object per page; awk sums them.
if ! RAW=$(gh api "repos/$REPO/issues/$N/sub_issues" --paginate \
        --jq '{open: [.[] | select(.state=="open")] | length, total: length}' 2>/dev/null); then
    echo "Error: gh api failed for repos/$REPO/issues/$N/sub_issues" >&2
    exit 3
fi

OPEN=$(printf '%s' "$RAW" | awk -F'"open":' '{print $2}' | awk '{s+=$1} END {print s+0}')
TOTAL=$(printf '%s' "$RAW" | awk -F'"total":' '{print $2}' | awk '{s+=$1} END {print s+0}')

if [ "${TOTAL:-0}" -eq 0 ] 2>/dev/null; then
    exit 2
fi

if [ "${OPEN:-0}" -gt 0 ] 2>/dev/null; then
    exit 1
fi

exit 0
