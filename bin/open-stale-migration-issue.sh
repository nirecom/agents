#!/usr/bin/env bash
# bin/open-stale-migration-issue.sh
# Opens one GitHub issue when temporary migration blocks outlive 90 days (#2434 D9).
# Driven by the sweep.yml stale-migration-issue job. Dedup is an exact open-title match;
# every scan or gh failure exits non-zero so the scheduled job surfaces it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TITLE="Stale temporary migration blocks (>90 days)"

report="$(node "$SCRIPT_DIR/lib/check-migration-blocks.js" --stale-report "$ROOT")"
if [[ -z "$report" ]]; then
  echo "open-stale-migration-issue: no stale migration blocks"
  exit 0
fi

open_titles="$(gh issue list --state open --search "$TITLE in:title" --json title --jq '.[].title')"
if printf '%s\n' "$open_titles" | grep -Fxq -- "$TITLE"; then
  echo "open-stale-migration-issue: an open issue already tracks the stale blocks"
  exit 0
fi

fence='```'
body="$(printf 'Temporary migration blocks older than 90 days (path:line:added):\n\n%s\n%s\n%s\n\nRemove each block together with the code its deletion-condition names.\n' "$fence" "$report" "$fence")"
gh issue create --title "$TITLE" --label type:task --body "$body"
