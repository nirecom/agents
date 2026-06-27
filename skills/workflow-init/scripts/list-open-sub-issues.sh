#!/bin/bash
# list-open-sub-issues.sh <owner/repo> <meta-N>
#
# Fetches open sub-issues for a meta issue and returns status via stdout + exit code.
#
# Stdout contract:
#   HAS_OPEN            (line 1) + "#N: title" lines (one per open sub-issue) → exit 0
#   NO_OPEN             (line 1, no open sub-issues including closed-only case) → exit 1
#   ERROR               (line 1) + error detail (line 2)                       → exit 2
#
# Pattern reference: bin/github-issues/parent-all-closed-check.sh, bin/issue-close-gate.sh

set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "ERROR"
    echo "usage: list-open-sub-issues.sh <owner/repo> <meta-N>"
    exit 2
fi

REPO="$1"
N="$2"

if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "ERROR"
    echo "owner/repo must be in owner/name format, got: $REPO"
    exit 2
fi

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "ERROR"
    echo "issue number must be digits only, got: $N"
    exit 2
fi

if ! RAW=$(gh api "repos/$REPO/issues/$N/sub_issues" --paginate 2>/dev/null); then
    echo "ERROR"
    echo "gh api failed for sub-issues of #$N"
    exit 2
fi

OPEN_LINES=$(printf '%s' "$RAW" | \
    jq -r '.[] | select(.state=="open") | "#\(.number): \(.title)"' 2>/dev/null)

if [[ -z "$OPEN_LINES" ]]; then
    echo "NO_OPEN"
    exit 1
fi

echo "HAS_OPEN"
printf '%s\n' "$OPEN_LINES"
exit 0
