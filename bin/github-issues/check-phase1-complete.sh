#!/bin/bash
# check-phase1-complete.sh <N>
#
# Verify Phase 1 (issue-close-stage) completion for issue #<N>. Called by
# /commit-push as a pre-flight before pushing the PR.
#
# Two conditions must BOTH hold:
#   (a) a sentinel comment (pending or appended) exists on the issue
#   (b) docs/history.md or docs/history/*.md contains a #<N>: entry that is
#       reachable from HEAD (i.e. actually committed, not merely in working tree)
#
# CWD must be a working tree root containing docs/history.md
# (check_history_entry uses CWD-relative paths). /commit-push runs this from
# the worktree root.

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

SENTINEL_RAW=$(gh issue view "$N" --json comments \
    --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | first // ""' \
    2>/dev/null) || SENTINEL_RAW=""

SENTINEL=$(parse_sentinel "$SENTINEL_RAW")
case "$SENTINEL" in
    pending|appended) SENTINEL_OK=1 ;;
    *)                SENTINEL_OK=0 ;;
esac

HIST_OK=0
if check_history_entry "$N"; then
    HIST_OK=1
fi

if [ "$SENTINEL_OK" -eq 1 ] && [ "$HIST_OK" -eq 1 ]; then
    exit 0
fi

if [ "$SENTINEL_OK" -eq 0 ] && [ "$HIST_OK" -eq 0 ]; then
    echo "Error: Phase 1 not started for #${N}. Run /issue-close-stage ${N} from this worktree." >&2
elif [ "$SENTINEL_OK" -eq 0 ]; then
    echo "Error: sentinel missing for #${N} (history entry present). Run /issue-close-stage ${N} to post the sentinel." >&2
else
    echo "Error: history entry missing for #${N} (sentinel present). Re-run /issue-close-stage ${N} to resume Step E." >&2
fi
exit 1
