#!/bin/bash
# Aggregate WIP check for workflow-init Step WI-5 (formerly Step 3(a)).
# Usage: aggregate-wip-check.sh <N1> [N2 ...]
# Outputs one of: ALL_SAME <wip> | ALL_NONE | MIXED_SAME_NONE | ANY_OTHER <N,...> | ERROR <N,...>
set -uo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

WIP_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh"
wip_results=()
wip_rcs=()
error_ns=()
other_ns=()
all_same=1
all_none=1
any_other=0

for N in "$@"; do
    WIP_OUT=$(bash "$WIP_SCRIPT" check "$N" 2>/dev/null) || WIP_RC=$?
    WIP_RC=${WIP_RC:-0}
    wip_results+=("$WIP_OUT")
    wip_rcs+=("$WIP_RC")
    if [[ "$WIP_RC" -ne 0 || -z "$WIP_OUT" ]]; then
        error_ns+=("$N")
    fi
    if [[ "$WIP_OUT" == "other" ]]; then
        any_other=1
        other_ns+=("$N")
    fi
    if [[ "$WIP_OUT" != "${wip_results[0]}" ]]; then
        all_same=0
    fi
    if [[ "$WIP_OUT" != "none" ]]; then
        all_none=0
    fi
done

joined_others=$(IFS=,; echo "${other_ns[*]:-}")
joined_errors=$(IFS=,; echo "${error_ns[*]:-}")

if [[ ${#error_ns[@]} -gt 0 ]]; then
    echo "ERROR $joined_errors"
elif [[ "$any_other" -eq 1 ]]; then
    echo "ANY_OTHER $joined_others"
elif [[ "$all_same" -eq 1 ]]; then
    echo "ALL_SAME ${wip_results[0]:-none}"
elif [[ "$all_none" -eq 1 ]]; then
    echo "ALL_NONE"
else
    echo "MIXED_SAME_NONE"
fi
