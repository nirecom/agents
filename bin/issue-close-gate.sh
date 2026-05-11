#!/bin/bash
# Block /issue-close when the parent issue has any open sub-issues.
#
# Usage: bin/issue-close-gate.sh <owner/repo> <issue-number>
#
# Exit 0  — no open sub-issues; the parent may be closed.
# Exit 1  — one or more open sub-issues, or an internal error. Open sub-issues
#           are listed on stderr in best-effort form.
#
# Uses `gh api ... --paginate` so issues with more than the default 30
# sub-issues are handled correctly.

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <owner/repo> <issue-number>" >&2
    exit 1
fi

REPO="$1"
ISSUE="$2"

# Validate repo format: owner/name where each segment is alphanum + dash/underscore/dot.
if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: repo must be in owner/name format, got: $REPO" >&2
    exit 1
fi

if ! printf '%s' "$ISSUE" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $ISSUE" >&2
    exit 1
fi

# Count open sub-issues (paginated).
if ! COUNT_RAW=$(gh api "repos/$REPO/issues/$ISSUE/sub_issues" --paginate \
        --jq '[.[] | select(.state=="open")] | length' 2>/dev/null); then
    echo "Error: gh api failed for repos/$REPO/issues/$ISSUE/sub_issues" >&2
    exit 1
fi

# `--paginate` may emit one length-per-page; sum them defensively.
COUNT=$(printf '%s' "$COUNT_RAW" | awk '{s+=$1} END {print s+0}')

if [ "${COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo "BLOCK: issue #$ISSUE has $COUNT open sub-issue(s). Close them first." >&2
    # Best-effort listing — mock fixtures may return a raw JSON array here.
    gh api "repos/$REPO/issues/$ISSUE/sub_issues" --paginate \
        --jq '.[] | select(.state=="open") | "  - #\(.number): \(.title)"' >&2 \
        || true
    exit 1
fi

exit 0
