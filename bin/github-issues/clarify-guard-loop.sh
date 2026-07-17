#!/usr/bin/env bash
# clarify-guard-loop.sh — CI-C0 tracking-issue guard wrapper (#513, #1198)
# Args: --session-id <sid> --plans-dir <dir> [--non-github]
# stdout: PROCEED | NEED_ISSUE | RETRY_EXHAUSTED | CLOSED_ENTRY
# exit: 0 on success, 2 on bad plans-dir or missing required arg
#
# Wraps check-closes-issues-nonempty.sh (SSOT for closes_issues parsing).
# Manages GUARD_ATTEMPT counter file: <plans-dir>/<sid>-guard-attempt.tmp
set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

SESSION_ID=""
PLANS_DIR_ARG=""
NON_GITHUB=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)  SESSION_ID="${2:-}"; shift 2 ;;
        --plans-dir)   PLANS_DIR_ARG="${2:-}"; shift 2 ;;
        --non-github)  NON_GITHUB=1; shift ;;
        *) echo "[clarify-guard-loop] unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$SESSION_ID" ]]; then
    echo "[clarify-guard-loop] --session-id required" >&2
    exit 2
fi
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "[clarify-guard-loop] --session-id must match [A-Za-z0-9_-]+" >&2
    exit 2
fi
if [[ -z "$PLANS_DIR_ARG" ]]; then
    echo "[clarify-guard-loop] --plans-dir required" >&2
    exit 2
fi

# Hard-validate plans-dir: normalize and prefix-check against expected base.
REAL_PLANS_DIR=$(cd "$PLANS_DIR_ARG" 2>/dev/null && pwd) || {
    echo "[clarify-guard-loop] plans-dir does not exist or is inaccessible: $PLANS_DIR_ARG" >&2
    exit 2
}
EXPECTED_BASE="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
REAL_EXPECTED_BASE=$(cd "$EXPECTED_BASE" 2>/dev/null && pwd) || REAL_EXPECTED_BASE="$EXPECTED_BASE"
case "$REAL_PLANS_DIR" in
    "$REAL_EXPECTED_BASE" | "$REAL_EXPECTED_BASE"/*) ;;
    *)
        echo "[clarify-guard-loop] plans-dir '$PLANS_DIR_ARG' is outside expected base '$EXPECTED_BASE'" >&2
        exit 2
        ;;
esac

COUNTER_FILE="${REAL_PLANS_DIR}/${SESSION_ID}-guard-attempt.tmp"
GUARD_ATTEMPT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)

GUARD_FLAG=""
if [[ "$NON_GITHUB" -eq 1 ]]; then
    GUARD_FLAG="--non-github"
fi

INTENT_FILE="${REAL_PLANS_DIR}/${SESSION_ID}-intent.md"
CHECK_RC=0
bash "$AGENTS_CONFIG_DIR/bin/github-issues/check-closes-issues-nonempty.sh" \
    "$INTENT_FILE" $GUARD_FLAG >/dev/null 2>&1 || CHECK_RC=$?

if [[ "$CHECK_RC" -eq 0 ]]; then
    rm -f "$COUNTER_FILE"
    echo "PROCEED"
    exit 0
elif [[ "$CHECK_RC" -eq 2 ]]; then
    echo "CLOSED_ENTRY"
    exit 0
else
    # CHECK_RC is 1 (empty closes_issues)
    if [[ "$GUARD_ATTEMPT" -ge 2 ]]; then
        echo "RETRY_EXHAUSTED"
        exit 0
    else
        GUARD_ATTEMPT=$(( GUARD_ATTEMPT + 1 ))
        echo "$GUARD_ATTEMPT" > "$COUNTER_FILE"
        echo "NEED_ISSUE"
        exit 0
    fi
fi
