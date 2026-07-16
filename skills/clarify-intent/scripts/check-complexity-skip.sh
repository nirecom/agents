#!/usr/bin/env bash
# check-complexity-skip.sh — outline-skip sentinel dispatch for clarify-intent (#1465)
# Env: AGENTS_CONFIG_DIR (required), SKIP_MODE (required: auto|judgment)
# Args: --session <sid> [--so-c1 <true|false>] [--so-c2 <true|false>]
# Stdout:
#   - If sentinel: first line "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>", final line "SENTINEL_EMITTED"
#   - No sentinel: only line "NO_SENTINEL"
# Exit: 0 success / 1 invalid args/env
set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"
: "${SKIP_MODE:?SKIP_MODE env var must be set}"

SESSION_ID=""
SO_C1=""
SO_C2=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session)  SESSION_ID="${2:?--session requires a value}"; shift 2 ;;
        --so-c1)    SO_C1="${2:?--so-c1 requires a value}"; shift 2 ;;
        --so-c2)    SO_C2="${2:?--so-c2 requires a value}"; shift 2 ;;
        *) echo "[check-complexity-skip] unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$SESSION_ID" ]] && { echo "[check-complexity-skip] --session is required" >&2; exit 1; }

case "$SKIP_MODE" in
    auto|judgment) ;;
    *) echo "[check-complexity-skip] SKIP_MODE must be 'auto' or 'judgment', got: $SKIP_MODE" >&2; exit 1 ;;
esac

if [[ "$SKIP_MODE" == "auto" ]]; then
    echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: skip-mode=auto all conditions met>>"
    echo "SENTINEL_EMITTED"
    exit 0
fi

# judgment mode
if [[ "$SO_C1" == "true" && "$SO_C2" == "true" ]]; then
    "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" \
        --session "$SESSION_ID" \
        --target outline \
        --c1 true \
        --c2 true \
        >/dev/null 2>&1 || true
    echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: skip-mode=judgment c1=true c2=true>>"
    echo "SENTINEL_EMITTED"
else
    echo "NO_SENTINEL"
fi
exit 0
