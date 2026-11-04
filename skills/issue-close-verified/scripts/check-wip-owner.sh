#!/usr/bin/env bash
# skills/issue-close-verified/scripts/check-wip-owner.sh <N>... — ICV-1 WIP owner check.
# Runs `wip-state check` on each issue and warns when another session holds its WIP mark
# (`other`); `none` and `same` print nothing. Always exits 0: a warning never blocks ICV-2.
# WIP_STATE_SH overrides the wip-state entrypoint (tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIP_STATE_SH="${WIP_STATE_SH:-$SCRIPT_DIR/../../../bin/github-issues/wip-state.sh}"

for n in "$@"; do
    if ! owner="$(bash "$WIP_STATE_SH" check "$n" 2>/dev/null)"; then
        echo "warn: #$n — wip-state check failed; WIP owner unknown"
        continue
    fi
    if [ "${owner%$'\r'}" = "other" ]; then
        echo "warn: #$n — another session holds the WIP mark; confirm with its owner before closing"
    fi
done
exit 0
