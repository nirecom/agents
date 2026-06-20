#!/bin/bash
# Aggregate WIP check for workflow-init Step WI-5 (formerly Step 3(a)).
# Usage: aggregate-wip-check.sh [--session-id <SID>] <N1> [N2 ...]
# Outputs one of: ALL_SAME <wip> | ALL_NONE | MIXED_SAME_NONE | ANY_OTHER <N,...> | ERROR <N,...>
set -uo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR required}"

WIP_SCRIPT="$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh"

SID_ARG=""
SID_SET=0
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
        --) shift; while [ $# -gt 0 ]; do ISSUES+=("$1"); shift; done ;;
        -*) echo "Error: unknown option: $1" >&2; exit 2 ;;
        *) ISSUES+=("$1"); shift ;;
    esac
done

if [ "$SID_SET" -eq 1 ] && [ -z "$SID_ARG" ]; then
    echo "Error: --session-id received an empty value" >&2; exit 2
fi

if [ "$SID_SET" -eq 0 ]; then
    if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -r "${CLAUDE_ENV_FILE}" ]; then
        CANDIDATE=$(grep -E '^CLAUDE_SESSION_ID=' "$CLAUDE_ENV_FILE" 2>/dev/null \
                    | head -1 | cut -d= -f2- | tr -d '\r"')
        if [ -n "$CANDIDATE" ]; then SID_ARG="$CANDIDATE"; SID_SET=1; fi
    fi
    if [ "$SID_SET" -eq 0 ] && [ -n "${CLAUDE_SESSION_ID:-}" ]; then
        SID_ARG=$(printf '%s' "$CLAUDE_SESSION_ID" | tr -d '\r"')
        [ -n "$SID_ARG" ] && SID_SET=1
    fi
fi

wip_results=()
wip_rcs=()
error_ns=()
other_ns=()
all_same=1
all_none=1
any_other=0

for N in ${ISSUES[@]:+"${ISSUES[@]}"}; do
    CHECK_ARGS=(check "$N")
    if [ "$SID_SET" -eq 1 ]; then
        CHECK_ARGS+=(--session-id "$SID_ARG")
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
