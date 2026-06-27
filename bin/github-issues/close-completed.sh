#!/bin/bash
# bin/github-issues/close-completed.sh [--repo OWNER/REPO] N
#
# Close issue N with --reason completed.
# --repo  optional OWNER/REPO; if omitted, gh resolves from cwd git context.
#
# Note: gh issue close here is a subprocess of the bash script — enforce-issue-close.js
# (PreToolUse) fires only on the Bash tool command head, not on subprocess calls.
# No ISSUE_CLOSE_SKILL=1 bypass is required here.

set -euo pipefail

REPO=""
N=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --)     shift; N="${1:?issue number required}"; shift ;;
        -*)     echo "Unknown flag: $1" >&2; exit 1 ;;
        *)      N="$1"; shift ;;
    esac
done

[[ -n "$N" ]] || { echo "Usage: close-completed.sh [--repo OWNER/REPO] N" >&2; exit 1; }

# Export GH_REPO so gh CLI targets the correct repository regardless of cwd.
[[ -n "$REPO" ]] && export GH_REPO="$REPO"

STATE=$(gh issue view "$N" --json state --jq .state 2>/dev/null) || {
    echo "Error: cannot view issue #$N" >&2; exit 1
}
if [[ "$STATE" != "OPEN" ]]; then
    echo "Error: issue #$N is not OPEN (current state: $STATE)" >&2
    exit 1
fi

gh issue close "$N" --reason completed
