#!/bin/bash
# bin/github-issues/wip-set-single.sh — probe meta label + set WIP for one issue.
#
# Usage: wip-set-single.sh <issue-number>
# Env:   AGENTS_CONFIG_DIR (required)
#
# Exit 0 + stdout "META_SKIP" : meta label detected, WIP set skipped
# Exit 0 + stdout "SET_OK"    : WIP set successfully
# Exit 1 + stderr warn        : wip-state.sh rc=1 (warn-continue)
# Exit 2 + stdout "RC2"       : wip-state.sh rc=2 (env/session-id failure)
#
# Label-probe failure is fail-open — proceeds to WIP set as if non-meta.

set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

N="${1:?usage: wip-set-single.sh <issue-number>}"

WIP_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh"

LABELS_JSON=$(gh issue view "$N" --json labels --jq '[.labels[].name]' 2>/dev/null) || LABELS_JSON=""

if [ -n "$LABELS_JSON" ] && printf '%s' "$LABELS_JSON" | grep -q '"meta"'; then
    echo "META_SKIP"
    exit 0
fi

RC=0
bash "$WIP_SCRIPT" set "$N" || RC=$?

case "$RC" in
    0)
        echo "SET_OK"
        exit 0
        ;;
    2)
        echo "RC2"
        exit 2
        ;;
    *)
        echo "warn: wip-state set failed for #$N (rc=$RC)" >&2
        exit 1
        ;;
esac
