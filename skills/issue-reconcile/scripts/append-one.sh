#!/usr/bin/env bash
# Append one closed issue's history entry to docs/history.md on the default
# branch, via the GitHub Contents API (#672 removed the ISSUE_CLOSE_SKILL=1
# bypass, so the write must go through the API path).
#
# Usage: append-one.sh <issue-number>
# Extracted from skills/issue-reconcile/SKILL.md IRC-3 so the prompt issues one
# standalone command instead of a multi-line snippet (#2132).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
NUM="${1:?issue number required}"

STAGING_DIR="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/workflow-plans-dir")"
STAGE="$STAGING_DIR/reconcile-${NUM}-history.md"
OWNER_REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')"
DEF="$(gh api "repos/$OWNER_REPO" --jq '.default_branch')"

cleanup() { rm -f "$STAGE"; }
trap cleanup EXIT

gh api "repos/$OWNER_REPO/contents/docs/history.md?ref=$DEF" \
    | jq -r '.content' | tr -d '\r\n' | base64 -d > "$STAGE"

# --allow-backdate is mandatory: every reconcile entry is older than the stream
# tail, which doc-append rejects by default.
bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-to-history.sh" "$NUM" --target "$STAGE" --allow-backdate

bash "$SCRIPT_CHECKOUT_ROOT/bin/lib/github-contents-write.sh" \
    --owner "${OWNER_REPO%%/*}" --repo "${OWNER_REPO#*/}" \
    --path docs/history.md --file "$STAGE" \
    --message "docs(history): record issue #$NUM" --branch "$DEF"
