#!/bin/bash
# parent-close-proposal-execute.sh <N>
#
# Pre-close issue <N> so that issue-close-finalize-triage.sh reads CLOSED and
# routes to auto_close_path (Step ICF-D,ICF-I,ICF-J — Step E removed in #690), bypassing Phase 1.
#
# Exit 0: success.
# Exit 1: gh issue close failed.

set -uo pipefail

if [ $# -lt 1 ]; then
    echo "Error: usage: parent-close-proposal-execute.sh <N>" >&2
    exit 1
fi

N="$1"

if ! printf '%s' "$N" | grep -qE '^[0-9]+$'; then
    echo "Error: issue number must be digits only, got: $N" >&2
    exit 1
fi

ISSUE_CLOSE_SKILL=1 gh issue close "$N" --reason completed
