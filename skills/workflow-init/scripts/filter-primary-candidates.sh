#!/bin/bash
# skills/workflow-init/scripts/filter-primary-candidates.sh
#
# WI-3 primary candidate filter. Takes candidate issue numbers as positional args.
# Emits surviving candidates one per line in input order, exit 0 always.
#
# Two exclusion axes:
#   - CLOSED: issue-state-check.sh reports "closed" → excluded
#   - parent-of-candidate: candidate A is the parentIssue of another candidate B
#     (i.e. A is excluded when any B in the set has parentIssue == A).
#     Only intra-candidate-set parents are excluded; external parents are ignored.
#
# Fallback: if all candidates are excluded, emit the full original list (fail-open).
#
# Usage: filter-primary-candidates.sh [N...]
# Env:   AGENTS_CONFIG_DIR (required)

set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

ISSUE_STATE_CHECK="$AGENTS_CONFIG_DIR/bin/github-issues/issue-state-check.sh"

CANDIDATES=("$@")
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    exit 0
fi

# Pass A: collect parentIssue numbers for each candidate via gh.
# Build parent-exclude set: parents that are themselves candidates.
declare -A CANDIDATE_SET
for N in "${CANDIDATES[@]}"; do
    CANDIDATE_SET["$N"]=1
done

declare -A PARENT_EXCLUDE
for N in "${CANDIDATES[@]}"; do
    PARENT_NUM=""
    RAW_PARENT=$(gh issue view "$N" --json parent 2>/dev/null) || RAW_PARENT=""
    if [ -n "$RAW_PARENT" ]; then
        PARENT_NUM=$(printf '%s' "$RAW_PARENT" | jq -r '.parent.number // empty' 2>/dev/null) || PARENT_NUM=""
    fi
    if [ -n "$PARENT_NUM" ] && [ -n "${CANDIDATE_SET[$PARENT_NUM]:-}" ]; then
        PARENT_EXCLUDE["$PARENT_NUM"]=1
    fi
done

# Pass B: emit surviving candidates in input order.
SURVIVORS=()
for N in "${CANDIDATES[@]}"; do
    # parent-exclude axis
    if [ -n "${PARENT_EXCLUDE[$N]:-}" ]; then
        continue
    fi
    # CLOSED axis (fail-open on error)
    STATE=""
    STATE=$(bash "$ISSUE_STATE_CHECK" "$N" 2>/dev/null) || STATE=""
    if [ "$STATE" = "closed" ]; then
        continue
    fi
    SURVIVORS+=("$N")
done

# Fallback: if nothing survived, emit originals.
if [ "${#SURVIVORS[@]}" -eq 0 ]; then
    for N in "${CANDIDATES[@]}"; do
        echo "$N"
    done
    exit 0
fi

for N in "${SURVIVORS[@]}"; do
    echo "$N"
done
exit 0
