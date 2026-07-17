#!/bin/bash
# issue-close-stage-triage.sh <N>
#
# Phase 1 (issue-close-stage) routing. Outputs eval-able shell assignments:
# STATE, SENTINEL, ACTION, NEXT_STEPS. Caller: `eval "$(bash issue-close-stage-triage.sh <N>)"`.
#
# Step letters: B=sub-issue-gate, D=pending-post, F=promote-to-appended,
# G=parent-body-update. (Step E doc-append+commit moved to Phase 2.)
#
# CWD must be a working tree root.

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

STATE=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null) || {
    echo "Error: gh issue view #${N} failed" >&2
    exit 1
}

SENTINEL_RAW=$(gh issue view "$N" --json comments \
    --jq '[.comments[].body | select(test("^<!-- issue-close-sentinel:"))] | last // ""' \
    2>/dev/null) || SENTINEL_RAW=""

SENTINEL=$(parse_sentinel "$SENTINEL_RAW")

case "${STATE}:${SENTINEL}" in
    OPEN:)
        print_triage_output "$STATE" "$SENTINEL" proceed "B,D,F,G"
        ;;
    OPEN:pending)
        # Sentinel posted but F (promote) not yet done.
        print_triage_output "$STATE" "$SENTINEL" resume_f "F,G"
        ;;
    OPEN:appended)
        # Step F already promoted the sentinel; only parent-body-update left.
        print_triage_output "$STATE" "$SENTINEL" resume_g "G"
        ;;
    CLOSED:*)
        echo "Error: issue #${N} is CLOSED — /issue-close-stage cannot run. Use /issue-close-finalize." >&2
        exit 1
        ;;
    *)
        echo "Error: unexpected state=${STATE} sentinel=${SENTINEL}" >&2
        exit 1
        ;;
esac
