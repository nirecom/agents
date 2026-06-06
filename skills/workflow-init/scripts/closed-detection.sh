#!/bin/bash
# Per-issue CLOSED detection for workflow-init Step WI-6 (formerly Step 3(c)).
# Usage: closed-detection.sh <N1> [N2 ...]
# For each N: outputs "<N> closed" or "<N> open" or "<N> error"
set -uo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

STATE_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/issue-state-check.sh"

for N in "$@"; do
    if STATE=$(bash "$STATE_SCRIPT" "$N" 2>/dev/null); then
        echo "$N $STATE"
    else
        echo "$N error"
    fi
done
