#!/bin/bash
# skills/issue-close-migrated/scripts/pre-flight.sh N TYPE INTO
# Validates issue states before close-not-planned.sh runs.
# Exit 0: OK. Exit 1: pre-condition not met.
set -euo pipefail

N="${1:?issue number required}"
TYPE="${2:?type required}"
INTO="${3:-}"

STATE=$(gh issue view "$N" --json state --jq .state 2>/dev/null) || { echo "cannot view #$N" >&2; exit 1; }
if [[ "$STATE" != "OPEN" ]]; then
    echo "Issue #$N is not OPEN (state=$STATE)" >&2; exit 1
fi

if [[ "$TYPE" == "migrated" ]]; then
    [[ -n "$INTO" ]] || { echo "--into required for migrated" >&2; exit 1; }
    DEST=$(gh issue view "$INTO" --json state --jq .state 2>/dev/null) || { echo "cannot view #$INTO" >&2; exit 1; }
    if [[ "$DEST" != "OPEN" ]]; then
        echo "Destination #$INTO is not OPEN (state=$DEST)" >&2; exit 1
    fi
fi
