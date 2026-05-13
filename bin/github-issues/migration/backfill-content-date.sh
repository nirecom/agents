#!/usr/bin/env bash
# Backfill Projects v2 "Content Date" field for a range of Issues.
# Extracts YYYY-MM-DD from each issue's first body line (the migrated heading).
# Halts on first error.
#
# Usage:
#   bin/github-issues/migration/backfill-content-date.sh <from> <to>
#   bin/github-issues/migration/backfill-content-date.sh 68 221    # remaining history entries
set -euo pipefail

OWNER=nirecom
REPO=nirecom/agents
PROJECT_NUM=1
PROJECT_ID=PVT_kwHOAMF_jc4BXf9E
FIELD_ID=PVTF_lAHOAMF_jc4BXf9EzhSsYwA

FROM="${1:?from issue number}"
TO="${2:?to issue number}"

for n in $(seq "$FROM" "$TO"); do
  body=$(gh issue view "$n" --repo "$REPO" --json body --jq '.body' 2>&1)
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

  item_id=$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" \
    --url "https://github.com/$REPO/issues/$n" --format json --jq '.id' 2>&1)

  if [[ -z "$item_id" ]] || [[ "$item_id" == *"error"* ]]; then
    echo "FAILED #$n: item-add returned: $item_id"
    exit 1
  fi

  gh project item-edit --id "$item_id" --field-id "$FIELD_ID" \
    --project-id "$PROJECT_ID" --date "$date" >/dev/null 2>&1

  echo "OK #$n date=$date"
done

echo ""
echo "Done: backfilled $((TO - FROM + 1)) issues"
