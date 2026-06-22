#!/bin/bash
# bin/github-issues/close-not-planned.sh --type migrated|cancelled [--into M] N
#
# Apply status label, post a comment, and close issue N with --reason not_planned.
# --into M  required when --type migrated; prohibited when --type cancelled.
#
# Exit 0: success.
# Exit 1: pre-condition failure or gh error.
#
# Note: gh issue close here is a subprocess of the bash script — enforce-issue-close.js
# (PreToolUse) fires only on the Bash tool command head, not on subprocess calls.
# No ISSUE_CLOSE_SKILL=1 bypass is required here.

set -euo pipefail

TYPE=""
INTO=""
N=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --into) INTO="$2"; shift 2 ;;
        --)     shift; N="${1:?issue number required}"; shift ;;
        -*)     echo "Unknown flag: $1" >&2; exit 1 ;;
        *)      N="$1"; shift ;;
    esac
done

[[ -n "$N" ]] || { echo "Usage: close-not-planned.sh --type migrated|cancelled [--into M] N" >&2; exit 1; }
[[ "$TYPE" == "migrated" || "$TYPE" == "cancelled" ]] || { echo "Error: --type must be migrated or cancelled, got: $TYPE" >&2; exit 1; }

if [[ "$TYPE" == "migrated" ]]; then
    [[ -n "$INTO" ]] || { echo "Error: --into <M> is required for --type migrated" >&2; exit 1; }
else
    [[ -z "$INTO" ]] || { echo "Error: --into is not allowed for --type cancelled" >&2; exit 1; }
fi

STATE=$(gh issue view "$N" --json state --jq .state 2>/dev/null) || { echo "Error: cannot view issue #$N" >&2; exit 1; }
if [[ "$STATE" != "OPEN" ]]; then
    echo "Error: issue #$N is not OPEN (current state: $STATE)" >&2
    exit 1
fi

if [[ "$TYPE" == "migrated" ]]; then
    DEST_STATE=$(gh issue view "$INTO" --json state --jq .state 2>/dev/null) || { echo "Error: cannot view destination #$INTO" >&2; exit 1; }
    if [[ "$DEST_STATE" != "OPEN" ]]; then
        echo "Error: destination issue #$INTO is not OPEN (current state: $DEST_STATE)" >&2
        exit 1
    fi
fi

LABEL="status:$TYPE"
gh issue edit "$N" --add-label "$LABEL"

if [[ "$TYPE" == "migrated" ]]; then
    COMMENT="Closing as migrated — work continues in #${INTO}."
else
    COMMENT="Closing as cancelled."
fi
gh issue comment "$N" --body "$COMMENT"

gh issue close "$N" --reason not_planned
