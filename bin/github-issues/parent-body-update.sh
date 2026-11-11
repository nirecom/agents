#!/bin/bash
# parent-body-update.sh <owner/repo> <N>
#
# If issue <N> has a parent issue, flip `- [ ] #<N>` to `- [x] #<N>` in the
# parent's body. No-op when there is no parent.
#
# Security: <N> is digits-only; PARENT_BODY is opaque text passed as one argv to
# `gh issue edit --body`; `\b` keeps `#42` from matching `#420`. A `<user>` diff stops the edit (#2940).
# Read-modify-write is not atomic (a concurrent parent edit is lost); fine for single-user use.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/parent-number.sh"

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

PARENT=$(github_parent_number "$REPO" "$N")
if [ -z "$PARENT" ]; then
    exit 0
fi

# meta parents use GitHub's native sub-issue UI as SSOT; skip body writes (see rules/github-issues.md meta policy)
IS_META=$(gh api "repos/${REPO}/issues/${PARENT}" \
    --jq 'any(.labels[].name; . == "meta")' 2>/dev/null) || IS_META=true
if [ "$IS_META" = "true" ]; then
    exit 0
fi

PARENT_BODY=$(gh issue view "$PARENT" --json body --jq .body)
NEW_BODY=$(printf '%s' "$PARENT_BODY" \
    | perl -pe "s/- \\[ \\] #${N}\\b/- [x] #${N}/g")

# The guard reads the same cwd-resolved parent the edit below writes.
# shellcheck source=../lib/gh-user-block-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/gh-user-block-guard.sh"
# shellcheck source=../lib/native-path.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/native-path.sh"
GUARD_TMPFILE="$(mktemp)"
trap 'rm -f "$GUARD_TMPFILE"' EXIT
printf '%s' "$NEW_BODY" > "$GUARD_TMPFILE"
if ! gh_user_block_guard "parent-body-update:#$PARENT" --op edit --issue "$PARENT" --new-body-file "$(native_path "$GUARD_TMPFILE")"; then
    echo "WARN: parent body update skipped for #${PARENT}" >&2
    exit 1
fi

if ! ISSUE_CLOSE_SKILL=1 gh issue edit "$PARENT" --body "$NEW_BODY" >/dev/null 2>&1; then
    echo "WARN: parent body update failed for #${PARENT}" >&2
    exit 1
fi
