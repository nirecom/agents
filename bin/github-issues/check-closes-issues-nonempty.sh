#!/bin/bash
# check-closes-issues-nonempty.sh [--non-github] <intent.md path>
#
# Guard: verify closes_issues is non-empty before emitting
# <<WORKFLOW_CLARIFY_INTENT_COMPLETE>>. Called by clarify-intent Completion.
#
# Exit 0: closes_issues has at least one issue (all OPEN), or --non-github flag passed.
# Exit 1: closes_issues is empty (on a GitHub remote) — instructs caller to
#         run /issue-create first.
# Exit 2: closes_issues non-empty but at least one entry is CLOSED — instructs
#         caller to reopen the issue or remove it from the session.
#
# SSOT: closes_issues parsing delegates to hooks/lib/parse-closes-issues.js.
#       Do not reimplement — see core-principles.md §2.

set -uo pipefail

NON_GITHUB_FLAG=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --non-github) NON_GITHUB_FLAG=1; shift ;;
        --*) echo "Usage: check-closes-issues-nonempty.sh [--non-github] <intent.md path>" >&2; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
    echo "Usage: check-closes-issues-nonempty.sh [--non-github] <intent.md path>" >&2
    exit 1
fi

if [ "$NON_GITHUB_FLAG" = "1" ]; then
    exit 0
fi

INTENT_PATH="$1"

if [ ! -f "$INTENT_PATH" ]; then
    echo "Error: intent.md not found: $INTENT_PATH" >&2
    exit 1
fi

: "${AGENTS_CONFIG_DIR:?Error: AGENTS_CONFIG_DIR not set}"

ISSUE_NUMS=$(node -e '
  const { parseClosesIssues } = require(process.env.AGENTS_CONFIG_DIR + "/hooks/lib/parse-closes-issues.js");
  console.log(parseClosesIssues(process.argv[1]).join(" "));
' "$INTENT_PATH") || { echo "Error: parser invocation failed" >&2; exit 1; }

if [ -z "$ISSUE_NUMS" ]; then
    echo "Error: closes_issues is empty — Run /issue-create to create a tracking issue, then re-run /clarify-intent Completion from the Reconcile-with-GitHub step." >&2
    exit 1
fi

# CLOSED-state check (fail-open per N — gh failures warn and continue)
SCRIPT_DIR="$(dirname "$0")"
HAS_CLOSED=0
for N in $ISSUE_NUMS; do
    if STATE=$(bash "$SCRIPT_DIR/issue-state-check.sh" "$N" 2>/dev/null); then
        :
    else
        STATE=error
    fi
    case "$STATE" in
        closed)
            echo "[check-closes-issues-nonempty] Issue #$N is CLOSED — cannot proceed." >&2
            HAS_CLOSED=1
            ;;
        error)
            echo "[check-closes-issues-nonempty] state check failed for #$N — continuing" >&2
            ;;
    esac
done

if [ "$HAS_CLOSED" -eq 1 ]; then
    exit 2
fi

exit 0
