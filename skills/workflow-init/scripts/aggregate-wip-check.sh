#!/bin/bash
# Aggregate WIP check for workflow-init Step WI-5 (formerly Step 3(a)).
# Usage: aggregate-wip-check.sh [--session-id <SID>] [--repo-map IDX:owner/repo ...] <N1> [N2 ...]
# Outputs one of: ALL_SAME <wip> | ALL_NONE | MIXED_SAME_NONE | ANY_OTHER <N,...> | ERROR <N,...>
set -uo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

WIP_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh"

_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIDGE="$_dir/../../../bin/resolve-session-id"

SID_ARG=""
SID_SET=0
declare -A REPO_OF
ISSUES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id)
            [ $# -lt 2 ] && { echo "Error: --session-id requires a value" >&2; exit 2; }
            SID_ARG="$2"; SID_SET=1; shift 2
            ;;
        --session-id=*)
            SID_ARG="${1#--session-id=}"; SID_SET=1; shift
            ;;
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

if [ "$SID_SET" -eq 1 ] && [ -z "$SID_ARG" ]; then
    echo "Error: --session-id received an empty value" >&2; exit 2
fi

# No injected --session-id → resolve via the canonical JS resolver bridge
# (issue #1251). On any failure leave SID_SET=0 and continue; never abort.
if [ "$SID_SET" -eq 0 ] && [ -f "$BRIDGE" ]; then
    BRIDGE_RC=0
    CANDIDATE=$(bash "$BRIDGE" 2>/dev/null) || BRIDGE_RC=$?
    if [ "$BRIDGE_RC" -eq 0 ] && [ -n "$CANDIDATE" ]; then
        SID_ARG="$CANDIDATE"; SID_SET=1
    fi
fi

wip_results=()
wip_rcs=()
error_ns=()
other_ns=()
all_same=1
all_none=1
any_other=0

for i in "${!ISSUES[@]}"; do
    N="${ISSUES[$i]}"
    CHECK_ARGS=(check "$N")
    if [ "$SID_SET" -eq 1 ]; then
        CHECK_ARGS+=(--session-id "$SID_ARG")
    fi
    if [ -n "${REPO_OF[$i]:-}" ]; then
        CHECK_ARGS+=(--repo "${REPO_OF[$i]}")
    fi
    WIP_RC=0
    WIP_OUT=$(bash "$WIP_SCRIPT" "${CHECK_ARGS[@]}" 2>/dev/null) || WIP_RC=$?
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
