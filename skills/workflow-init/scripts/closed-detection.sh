#!/bin/bash
# Per-issue CLOSED detection for workflow-init Step WI-6 (formerly Step 3(c)).
# Usage: closed-detection.sh [--repo-map IDX:owner/repo ...] <N1> [N2 ...]
# For each N: outputs "<N> closed" or "<N> open" or "<N> error"
set -uo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

STATE_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/issue-state-check.sh"

declare -A REPO_OF
ISSUES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --repo-map)
            [ $# -lt 2 ] && { echo "Error: --repo-map requires a value" >&2; exit 2; }
            KEY="${2%%:*}"; VAL="${2#*:}"; REPO_OF["$KEY"]="$VAL"; shift 2
            ;;
        --repo-map=*)
            PAIR="${1#--repo-map=}"; KEY="${PAIR%%:*}"; VAL="${PAIR#*:}"; REPO_OF["$KEY"]="$VAL"; shift
            ;;
        --) shift; while [ $# -gt 0 ]; do ISSUES+=("$1"); shift; done ;;
        -*) echo "Error: unknown option: $1" >&2; exit 2 ;;
        *) ISSUES+=("$1"); shift ;;
    esac
done

for i in "${!ISSUES[@]}"; do
    N="${ISSUES[$i]}"
    if STATE=$(bash "$STATE_SCRIPT" ${REPO_OF[$i]:+--repo "${REPO_OF[$i]}"} "$N" 2>/dev/null); then
        echo "$N $STATE"
    else
        echo "$N error"
    fi
done
