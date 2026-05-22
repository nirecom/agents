#!/bin/bash
# check-closes-issues-nonempty.sh [--non-github] <intent.md path>
#
# Guard: verify closes_issues is non-empty before emitting
# <<WORKFLOW_CLARIFY_INTENT_COMPLETE>>. Called by clarify-intent Completion.
#
# Exit 0: closes_issues has at least one issue, or --non-github flag passed.
# Exit 1: closes_issues is empty (on a GitHub remote) — instructs caller to
#         run /issue-create first.
#
# SSOT: closes_issues parsing delegates to hooks/lib/parse-closes-issues.js.
#       Do not reimplement — see core-principles.md §4.

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

COUNT=$(node -e '
  const { parseClosesIssues } = require(process.env.AGENTS_CONFIG_DIR + "/hooks/lib/parse-closes-issues.js");
  console.log(parseClosesIssues(process.argv[1]).length);
' "$INTENT_PATH") || { echo "Error: parser invocation failed" >&2; exit 1; }

if [ "$COUNT" -gt 0 ]; then
    exit 0
fi

echo "Error: closes_issues is empty — Run /issue-create to create a tracking issue, then re-run /clarify-intent Completion from the Reconcile-with-GitHub step." >&2
exit 1
