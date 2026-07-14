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
# Output format (C1): self-describing tokens.
#   - With repo context: "owner/repo#N"
#   - Without repo context: "#N"
#
# Usage: filter-primary-candidates.sh [--repo-map IDX:owner/repo ...] [N...]
# Env:   AGENTS_CONFIG_DIR (required)

set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

ISSUE_STATE_CHECK="$AGENTS_CONFIG_DIR/bin/github-issues/issue-state-check.sh"

# Parse --repo-map options (repeatable). Build associative array keyed by 0-based index.
declare -A REPO_OF
CANDIDATES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-map)
            [ $# -lt 2 ] && { echo "Error: --repo-map requires a value" >&2; exit 2; }
            KEY="${2%%:*}"
            VAL="${2#*:}"
            REPO_OF["$KEY"]="$VAL"
            shift 2
            ;;
        --repo-map=*)
            PAIR="${1#--repo-map=}"
            KEY="${PAIR%%:*}"
            VAL="${PAIR#*:}"
            REPO_OF["$KEY"]="$VAL"
            shift
            ;;
        --) shift; while [ $# -gt 0 ]; do CANDIDATES+=("$1"); shift; done ;;
        -*) echo "Error: unknown option: $1" >&2; exit 2 ;;
        *) CANDIDATES+=("$1"); shift ;;
    esac
done

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
declare -A META_CANDIDATE
for i in "${!CANDIDATES[@]}"; do
    N="${CANDIDATES[$i]}"
    PARENT_NUM=""
    RAW_PARENT=$(gh issue view "$N" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} --json parent,labels 2>/dev/null) || RAW_PARENT=""
    if [ -n "$RAW_PARENT" ]; then
        PARENT_NUM=$(printf '%s' "$RAW_PARENT" | jq -r '.parent.number // empty' 2>/dev/null) || PARENT_NUM=""
        IS_META=0
        HAS_META=$(printf '%s' "$RAW_PARENT" | jq -r '[.labels[]?.name // empty] | any(. == "meta") | if . then "1" else "0" end' 2>/dev/null) || HAS_META=0
        IS_META="${HAS_META:-0}"
        META_CANDIDATE["$i"]="$IS_META"
    fi
    if [ -n "$PARENT_NUM" ] && [ -n "${CANDIDATE_SET[$PARENT_NUM]:-}" ]; then
        PARENT_EXCLUDE["$PARENT_NUM"]=1
    fi
done

# Pass B: emit surviving candidates in input order.
# Phase 1: collect survivors by CLOSED + parent-exclude axes.
SURVIVORS=()
SURVIVOR_IDXS=()
for i in "${!CANDIDATES[@]}"; do
    N="${CANDIDATES[$i]}"
    if [ -n "${PARENT_EXCLUDE[$N]:-}" ]; then continue; fi
    STATE=$(bash "$ISSUE_STATE_CHECK" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} "$N" 2>/dev/null) || STATE=""
    if [ "$STATE" = "closed" ]; then continue; fi
    SURVIVORS+=("$N")
    SURVIVOR_IDXS+=("$i")
done

# Phase 2: meta-exclude axis — strip meta survivors only when at least one non-meta exists.
NON_META_EXISTS=0
for k in "${!SURVIVORS[@]}"; do
    IDX="${SURVIVOR_IDXS[$k]}"
    if [ "${META_CANDIDATE[$IDX]:-0}" != "1" ]; then NON_META_EXISTS=1; break; fi
done

if [ "$NON_META_EXISTS" -eq 1 ]; then
    FILTERED=(); FILTERED_IDXS=()
    for k in "${!SURVIVORS[@]}"; do
        IDX="${SURVIVOR_IDXS[$k]}"
        if [ "${META_CANDIDATE[$IDX]:-0}" = "1" ]; then continue; fi
        FILTERED+=("${SURVIVORS[$k]}"); FILTERED_IDXS+=("$IDX")
    done
    SURVIVORS=("${FILTERED[@]}"); SURVIVOR_IDXS=("${FILTERED_IDXS[@]}")
fi

# Helper: emit token for index i and issue N
emit_token() {
    local idx="$1"
    local n="$2"
    if [ -n "${REPO_OF[$idx]:-}" ]; then
        echo "${REPO_OF[$idx]}#$n"
    else
        echo "#$n"
    fi
}

# Fallback: if nothing survived, emit originals.
if [ "${#SURVIVORS[@]}" -eq 0 ]; then
    for i in "${!CANDIDATES[@]}"; do
        emit_token "$i" "${CANDIDATES[$i]}"
    done
    exit 0
fi

for k in "${!SURVIVORS[@]}"; do
    emit_token "${SURVIVOR_IDXS[$k]}" "${SURVIVORS[$k]}"
done
exit 0
