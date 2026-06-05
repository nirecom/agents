#!/bin/bash
# rename-meta-issues-to-group-prefix.sh
# Rename OPEN meta-labeled issues whose title lacks "Group: " prefix.
# Canary mode: rename one → user confirms → rename remaining.
#
# Usage:
#   rename-meta-issues-to-group-prefix.sh --dry-run   # list candidates only
#   rename-meta-issues-to-group-prefix.sh --canary    # rename FIRST candidate only
#   rename-meta-issues-to-group-prefix.sh --all       # rename all candidates

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    --dry-run|--canary|--all) ;;
    "") echo "Usage: $0 --dry-run|--canary|--all" >&2; exit 2 ;;
    *) echo "Error: unknown flag '$MODE'. Use --dry-run|--canary|--all." >&2; exit 2 ;;
esac

CANDIDATES=$(gh issue list --state open --label meta --limit 100 \
    --json number,title \
    --jq '.[] | select(.title | startswith("Group: ") | not) | "\(.number)\t\(.title)"')

if [ -z "$CANDIDATES" ]; then
    echo "No candidates."
    exit 0
fi

TOTAL=$(printf '%s\n' "$CANDIDATES" | wc -l | tr -d ' ')
echo "Found $TOTAL candidate(s):"
printf '%s\n' "$CANDIDATES" | sed 's/^/  /'

if [ "$MODE" = "--dry-run" ]; then
    exit 0
fi

rename_one() {
    local num="$1" old="$2"
    local stripped
    stripped=$(printf '%s' "$old" | sed -E 's/^(umbrella|tracking|meta|Umbrella|Tracking|Meta|UMBRELLA|TRACKING|META):[[:space:]]+//')
    local new="Group: $stripped"
    echo "  #$num: $old"
    echo "       → $new"
    gh issue edit "$num" --title "$new"
}

if [ "$MODE" = "--canary" ]; then
    FIRST=$(printf '%s\n' "$CANDIDATES" | head -n 1)
    num=$(printf '%s' "$FIRST" | cut -f1)
    title=$(printf '%s' "$FIRST" | cut -f2-)
    rename_one "$num" "$title"
    echo "Canary done (1 of $TOTAL). Verify, then re-run with --all."
    exit 0
fi

COUNT=0
while IFS=$'\t' read -r num title; do
    rename_one "$num" "$title"
    COUNT=$((COUNT + 1))
done <<< "$CANDIDATES"
echo "Renamed $COUNT of $TOTAL issues."
