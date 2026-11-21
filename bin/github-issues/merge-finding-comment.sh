#!/usr/bin/env bash
# merge-finding-comment.sh <TARGET> <FILE> — add FILE as one comment on issue #TARGET (#2019).
# Used by issue-create-dispatch.sh after a reopen that absorbs a worktree-notes finding: the
# finding is appended as a comment, never merged into the issue body. Behind gh_outbound_guard
# and gh_user_block_guard. Exit: 0 commented; 2 bad arguments; 1 a guard stop or gh failure.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Error: usage: merge-finding-comment.sh <TARGET> <FILE>" >&2
    exit 2
fi
TARGET="$1"
FILE="$2"
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    echo "Error: TARGET must be digits only (got: ${TARGET})" >&2
    exit 2
fi
if [[ ! -f "$FILE" || ! -s "$FILE" ]]; then
    echo "Error: finding file missing or empty: ${FILE}" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 1
fi

# shellcheck source=../lib/gh-outbound-guard.sh
. "$(dirname "$0")/../lib/gh-outbound-guard.sh"
# shellcheck source=../lib/native-path.sh
. "$(dirname "$0")/../lib/native-path.sh"
# shellcheck source=../lib/gh-user-block-guard.sh
. "$(dirname "$0")/../lib/gh-user-block-guard.sh"

REPO_SLUG="$(MSYS_NO_PATHCONV=1 gh repo view --json nameWithOwner --jq .nameWithOwner | tr -d '\r')"
if ! [[ "$REPO_SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Error: could not determine valid REPO_SLUG (got: '${REPO_SLUG}')" >&2
    exit 1
fi

gh_outbound_guard "merge-finding-comment:#$TARGET" < "$FILE" || exit 1
gh_user_block_guard "merge-finding-comment:#$TARGET" --op comment-create --issue "$TARGET" \
    --repo "$REPO_SLUG" --new-body-file "$(native_path "$FILE")" || exit 1

if ! MSYS_NO_PATHCONV=1 gh issue comment "$TARGET" --body-file "$(native_path "$FILE")"; then
    echo "Error: gh issue comment ${TARGET} failed" >&2
    exit 1
fi
