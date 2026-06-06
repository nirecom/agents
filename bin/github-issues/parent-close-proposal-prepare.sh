#!/bin/bash
# parent-close-proposal-prepare.sh <owner/repo> <N>
#
# Pre-check for Step ICF-E..ICF-G parent close proposal: verify that issue <N> has a
# parent and that all of the parent's sub-issues are closed.
#
# Exit 0: proposal may proceed; prints parent issue number on stdout.
# Exit 1: skip (no parent, unclosed siblings, or 0 sub-issues on parent).
# Exit 2: API error (gh call failed); caller should warn and skip.

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Error: usage: parent-close-proposal-prepare.sh <owner/repo> <N>" >&2
    exit 2
fi

REPO="$1"
N="$2"

if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: repo must be in owner/name format, got: $REPO" >&2
    exit 2
fi

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $N" >&2
    exit 2
fi

PARENT=$(gh api "repos/$REPO/issues/$N" --jq '.parent.number // empty' 2>/dev/null)
if [ -z "$PARENT" ]; then
    exit 1
fi

bash "$(dirname "${BASH_SOURCE[0]}")/parent-all-closed-check.sh" "$REPO" "$PARENT"
CHECK_RC=$?

case "$CHECK_RC" in
    0)
        echo "$PARENT"
        exit 0
        ;;
    1|2)
        exit 1
        ;;
    3)
        echo "WARN: parent-all-closed-check.sh failed for #${PARENT}" >&2
        exit 2
        ;;
    *)
        echo "WARN: unexpected exit code $CHECK_RC from parent-all-closed-check.sh" >&2
        exit 2
        ;;
esac
