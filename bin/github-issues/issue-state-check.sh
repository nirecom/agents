#!/usr/bin/env bash
# issue-state-check.sh <issue-number>
#
# Check whether a GitHub issue is OPEN, CLOSED, or unreachable.
#
# stdout: exactly one of `open`, `closed`, or `error` (newline-terminated).
# Exit 0: state determined (open or closed).
# Exit 1: gh failed or unexpected state.
# Exit 2: bad arguments.
#
# Dependencies: `gh` CLI only. Does NOT require AGENTS_CONFIG_DIR.
set -euo pipefail

# Validate arg: must be a single numeric issue number
if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Usage: issue-state-check.sh <issue-number>" >&2
    exit 2
fi

N="$1"

# Call gh in an if-block to avoid set -e abort on failure
if RAW=$(gh issue view "$N" --json state --jq '.state' 2>/dev/null); then
    case "$RAW" in
        OPEN)   echo "open";   exit 0 ;;
        CLOSED) echo "closed"; exit 0 ;;
        *)      echo "[issue-state-check] unexpected state '$RAW' for #$N" >&2
                echo "error"
                exit 1 ;;
    esac
else
    echo "[issue-state-check] gh call failed for #$N" >&2
    echo "error"
    exit 1
fi
