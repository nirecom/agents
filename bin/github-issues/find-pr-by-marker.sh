#!/bin/bash
# find-pr-by-marker.sh <N>
#
# Resolve issue #<N> → (PR_NUMBER, MERGE_COMMIT) using two strategies:
#
#   primary  : PR body contains the literal marker `<!-- issue-close-pr-of: <N> -->`.
#              Inserted by /commit-push when a PR closes a tracked issue.
#              When multiple merged PRs match (re-open + re-close scenario),
#              pick the LATEST by mergedAt — that is the merge that produced
#              the current CLOSED state, and whose SHA should land in the
#              `resolved-by` sentinel.
#
#   fallback : `gh issue view --json closedByPullRequestsReferences`. Used when
#              the marker is absent (issue closed before the marker scheme
#              existed, or PR body manually edited).
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

# Primary: marker-based search across merged PRs. Pre-jq'd output:
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

# Fallback: closedByPullRequestsReferences. Only meaningful when the issue is
# already CLOSED — otherwise no merge SHA exists yet.
STATE=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null) || STATE=""
if [ "$STATE" != "CLOSED" ]; then
    echo "Error: no PR found for #${N} (marker absent, issue is not CLOSED)" >&2
    exit 1
fi

PR_NUM=$(gh issue view "$N" --json closedByPullRequestsReferences \
    --jq '.closedByPullRequestsReferences[0].number // empty' 2>/dev/null) || PR_NUM=""
if [ -z "$PR_NUM" ]; then
    echo "Error: no PR found for #${N} (marker absent, closedByPullRequestsReferences empty)" >&2
    exit 1
fi

MERGE_SHA=$(gh pr view "$PR_NUM" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null) || MERGE_SHA=""
if [ -z "$MERGE_SHA" ]; then
    echo "Error: no PR found for #${N} (PR #${PR_NUM} has no merge commit)" >&2
    exit 1
fi

printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "$PR_NUM" "$MERGE_SHA"
