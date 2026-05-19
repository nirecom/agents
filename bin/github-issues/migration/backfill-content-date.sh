#!/usr/bin/env bash
# Backfill Projects v2 "Content Date" field for migrated Issues.
# Extracts YYYY-MM-DD from each issue's first body line (the migrated heading).
# Halts on first error.
#
# Usage:
#   MIGRATE_PROJECT_ID=PVT_... MIGRATE_FIELD_ID=PVTF_... MIGRATE_PROJECT_NUM=N \
#     bin/github-issues/migration/backfill-content-date.sh <repo_dir>
#
# Reads the list of migrated issue numbers from .migration-state.json
# (.history.migrated[].issue_number).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

REPO_DIR="${1:?usage: backfill-content-date.sh <repo_dir>}"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

: "${MIGRATE_PROJECT_ID:?MIGRATE_PROJECT_ID must be set (Projects v2 node id)}"
: "${MIGRATE_FIELD_ID:?MIGRATE_FIELD_ID must be set (Content Date field id)}"
: "${MIGRATE_PROJECT_NUM:?MIGRATE_PROJECT_NUM must be set (project number)}"

state_load "$REPO_DIR"

OWNER=$(cd "$REPO_DIR" && gh repo view --json owner --jq .owner.login)
REPO_NAME=$(cd "$REPO_DIR" && gh repo view --json name --jq .name)
REPO_SLUG="${OWNER}/${REPO_NAME}"

migrated_numbers=$(jq -r '.history.migrated[].issue_number' "$STATE_FILE")
if [ -z "$migrated_numbers" ]; then
  echo "No migrated history entries found in state — nothing to backfill."
  exit 0
fi

count_ok=0
count_total=0
while IFS= read -r n; do
  [ -z "$n" ] && continue
  count_total=$((count_total + 1))
  body=$(gh issue view "$n" --repo "$REPO_SLUG" --json body --jq '.body' 2>&1)
  if [[ -z "$body" ]]; then
    echo "FAILED #$n: empty body"
    exit 1
  fi

  date=$(echo "$body" | head -n1 | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -n1)
  if [[ -z "$date" ]]; then
    echo "FAILED #$n: no YYYY-MM-DD in first body line"
    echo "  first line: $(echo "$body" | head -n1)"
    exit 1
  fi

  item_id=$(gh project item-add "$MIGRATE_PROJECT_NUM" --owner "$OWNER" \
    --url "https://github.com/$REPO_SLUG/issues/$n" --format json --jq '.id' 2>&1)

  if [[ -z "$item_id" ]] || [[ "$item_id" == *"error"* ]]; then
    echo "FAILED #$n: item-add returned: $item_id"
    exit 1
  fi

  gh project item-edit --id "$item_id" --field-id "$MIGRATE_FIELD_ID" \
    --project-id "$MIGRATE_PROJECT_ID" --date "$date" >/dev/null 2>&1

  echo "OK #$n date=$date"
  count_ok=$((count_ok + 1))
done <<< "$migrated_numbers"

echo ""
echo "Done: backfilled $count_ok / $count_total issues"
