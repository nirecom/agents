#!/bin/bash
# post-close-sentinels.sh <N> [<commit-hash>]
#
# Post Step-J comments to issue <N>:
#   J-1 (only when <commit-hash> is supplied): a human-readable resolved-by
#        comment. Idempotent: skipped when an existing `<!-- resolved-by: <hash> -->`
#        comment is already present.
#   J-2: the machine-readable `appended` sentinel. Idempotent: skipped when
#        any `^<!-- issue-close-sentinel: appended` comment is already present.
#
# The `(resolved-by: closes-keyword)` suffix on J-2 is informational only —
# `/issue-reconcile` matches the `^<!-- issue-close-sentinel: appended` prefix.
#
# Uses `gh --jq` (built into the gh CLI) — no external jq dependency.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "Error: usage: post-close-sentinels.sh <N> [<commit-hash>]" >&2
    exit 1
fi

N="$1"
HASH="${2:-}"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only (got: $N)" >&2
    exit 1
fi

if [ -n "$HASH" ] && ! printf '%s' "$HASH" | grep -qE '^[0-9a-f]{7,40}$'; then
    echo "Error: commit hash must be 7-40 hex chars (got: $HASH)" >&2
    exit 1
fi

# J-1: resolved-by hash comment.
if [ -n "$HASH" ]; then
    HAS_RESOLVED=$(gh issue view "$N" --json comments \
        --jq "[.comments[].body | select(test(\"^<!-- resolved-by: ${HASH} -->\"))] | first // \"\"" \
        2>/dev/null) || HAS_RESOLVED=""
    if [ -z "$HAS_RESOLVED" ]; then
        ISSUE_CLOSE_SKILL=1 gh issue comment "$N" \
            --body "<!-- resolved-by: ${HASH} -->
Resolved by commit \`${HASH}\`."
    fi
fi

# J-2: appended sentinel.
HAS_APPENDED=$(gh issue view "$N" --json comments \
    --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel: appended"))] | first // ""' \
    2>/dev/null) || HAS_APPENDED=""
if [ -z "$HAS_APPENDED" ]; then
    ISSUE_CLOSE_SKILL=1 gh issue comment "$N" \
        --body "<!-- issue-close-sentinel: appended (resolved-by: closes-keyword) -->"
fi
