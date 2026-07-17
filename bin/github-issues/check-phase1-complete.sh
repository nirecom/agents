#!/bin/bash
# check-phase1-complete.sh <N>
#
# Verify Phase 1 (issue-close-stage) completion for issue #<N>. Called by
# /commit-push as a pre-flight before pushing the PR.
#
# Condition: a sentinel comment (pending or appended) exists on the issue.
# (History entry check removed — doc-append now runs in Phase 2 from main.)
#
# /commit-push runs this from the worktree root.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "Error: issue number required" >&2
    exit 1
fi

N="$1"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only (got: $N)" >&2
    exit 1
fi

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR not set" >&2
    exit 1
fi

# shellcheck source=./issue-close-triage-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/issue-close-triage-lib.sh"

STATE=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null) || STATE=""
if [ "$STATE" = "CLOSED" ]; then
    echo "[check-phase1-complete] #$N already CLOSED — Phase 1 skipped, auto_close_path will handle it (issue-close-finalize-triage.sh)"
    exit 0
fi

SENTINEL_RAW=$(gh issue view "$N" --json comments \
    --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | first // ""' \
    2>/dev/null) || SENTINEL_RAW=""

SENTINEL=$(parse_sentinel "$SENTINEL_RAW")
case "$SENTINEL" in
    pending|appended)
        exit 0
        ;;
    *)
        echo "Error: Phase 1 not started for #${N}. Run /issue-close-stage ${N} from this worktree." >&2
        exit 1
        ;;
esac
