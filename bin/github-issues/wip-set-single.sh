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

N=""
SID_ARG=""
SID_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id)
            [ $# -lt 2 ] && { echo "Error: --session-id requires a value" >&2; exit 2; }
            SID_ARG="$2"; SID_SET=1; shift 2
            ;;
        --session-id=*)
            SID_ARG="${1#--session-id=}"; SID_SET=1; shift
            ;;
        --) shift; break ;;
        -*)
            echo "Error: unknown option: $1" >&2; exit 2
            ;;
        *)
            if [ -z "$N" ]; then N="$1"; else
                echo "Error: extra positional argument: $1" >&2; exit 2
            fi
            shift
            ;;
    esac
done
[ -n "$N" ] || { echo "usage: wip-set-single.sh [--session-id <SID>] <issue-number>" >&2; exit 2; }

if [ "$SID_SET" -eq 1 ] && [ -z "$SID_ARG" ]; then
    echo "Error: --session-id received an empty value" >&2; exit 2
fi

WIP_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh"

LABELS_JSON=$(gh issue view "$N" --json labels --jq '[.labels[].name]' 2>/dev/null) || LABELS_JSON=""

if [ -n "$LABELS_JSON" ] && printf '%s' "$LABELS_JSON" | grep -q '"meta"'; then
    echo "META_SKIP"
    exit 0
fi

WIP_ARGS=(set "$N")
if [ "$SID_SET" -eq 1 ]; then
    WIP_ARGS+=(--session-id "$SID_ARG")
fi
RC=0
bash "$WIP_SCRIPT" "${WIP_ARGS[@]}" || RC=$?

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
