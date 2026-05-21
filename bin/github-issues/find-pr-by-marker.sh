#!/bin/bash
# find-pr-by-marker.sh <N>
#
# Resolve issue #<N> → (PR_NUMBER, MERGE_COMMIT) using two strategies:
#
#   primary  : `gh issue view --json closedByPullRequestsReferences` (GitHub
#              SSOT). Only meaningful when the issue is CLOSED. Picks the most
#              recently merged PR via `sort_by(.mergedAt) | last` to handle
#              multi-close/reopen scenarios.
#
#   fallback : PR body contains the literal marker `<!-- issue-close-pr-of: <N> -->`.
#              Used when the issue is OPEN (no closing PR yet) or when the
#              primary returns empty (closedByPullRequestsReferences missing
#              the mergeCommit.oid). When multiple merged PRs match, also picks
#              by `sort_by(.mergedAt) | last`.
#
# Output on success (stdout):
#     PR_NUMBER=<n>
#     MERGE_COMMIT=<sha>
# Exit 1 on failure with a diagnostic on stderr.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "Error: issue number required" >&2
    exit 1
fi

N="$1"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only (got: $N)" >&2
    exit 1
fi

# Primary: closedByPullRequestsReferences (GitHub SSOT — #418 fix).
# Only meaningful when CLOSED. Pre-jq'd output: `<number>\t<sha>`.
PR_NUM=""
MERGE_SHA=""
STATE=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null) || STATE=""
if [ "$STATE" = "CLOSED" ]; then
    PRIMARY_LINE=$(gh issue view "$N" --json closedByPullRequestsReferences \
        --jq '[.closedByPullRequestsReferences[]] | sort_by(.mergedAt) | last | "\(.number)\t\(.mergeCommit.oid // "")"' \
        2>/dev/null) || PRIMARY_LINE=""
    if [ -n "$PRIMARY_LINE" ]; then
        PR_NUM=$(printf '%s' "$PRIMARY_LINE" | cut -f1)
        MERGE_SHA=$(printf '%s' "$PRIMARY_LINE" | cut -f2)
    fi
fi

if [ -n "$PR_NUM" ] && [ -n "$MERGE_SHA" ]; then
    printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$PR_NUM" "$MERGE_SHA"
    exit 0
fi

# Fallback: marker-based PR search across merged PRs. Pre-jq'd output:
# `<number>\t<sha>`. When there are multiple matches, `sort_by(.mergedAt) | last`
# keeps the most recent merge.
PR_LINE=$(gh pr list \
    --search "in:body \"<!-- issue-close-pr-of: ${N} -->\"" \
    --state merged --json number,mergedAt,mergeCommit \
    --jq '[.[]] | sort_by(.mergedAt) | last | "\(.number)\t\(.mergeCommit.oid // "")"' \
    2>/dev/null) || PR_LINE=""

if [ -n "$PR_LINE" ] && [ "$(printf '%s' "$PR_LINE" | cut -f2)" != "" ]; then
    PR_NUM=$(printf '%s' "$PR_LINE" | cut -f1)
    MERGE_SHA=$(printf '%s' "$PR_LINE" | cut -f2)
    printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$PR_NUM" "$MERGE_SHA"
    exit 0
fi

echo "Error: no PR found for #${N} (closedByPullRequestsReferences empty and marker absent)" >&2
exit 1
