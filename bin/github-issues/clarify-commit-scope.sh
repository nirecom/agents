#!/usr/bin/env bash
# clarify-commit-scope.sh — GH reconcile extraction for clarify-intent (#513)
# Args: --session-id <sid> --plans-dir <dir> --issues <csv> [--non-github] [--repo <slug>]
# stdout: CREATED:<N> | CLOSED:<N> | RC2
# exit: 0 success, 1 gh failure, 2 CLOSED entry or WIP RC2, 2 bad plans-dir
#
# Path B (non-empty --issues): CLOSED pre-scan first (no side effects until all clear),
#   then per-N: gh issue edit --add-label → wip-set-single.sh → ensure-board-card.sh.
# Path C (empty --issues): gh issue create --label intent:clarified → CREATED:<N>.
# --non-github: skip all gh calls, exit 0.
set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

SESSION_ID=""
PLANS_DIR_ARG=""
ISSUES_CSV=""
ISSUES_SET=0
NON_GITHUB=0
REPO_SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)  SESSION_ID="${2:-}"; shift 2 ;;
        --plans-dir)   PLANS_DIR_ARG="${2:-}"; shift 2 ;;
        --issues)      ISSUES_CSV="${2:-}"; ISSUES_SET=1; shift 2 ;;
        --non-github)  NON_GITHUB=1; shift ;;
        --repo)        REPO_SLUG="${2:-}"; shift 2 ;;
        *) echo "[clarify-commit-scope] unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Hard-validate plans-dir: normalize and prefix-check against expected base.
REAL_PLANS_DIR=$(cd "$PLANS_DIR_ARG" 2>/dev/null && pwd) || {
    echo "[clarify-commit-scope] plans-dir does not exist or is inaccessible: $PLANS_DIR_ARG" >&2
    exit 2
}
EXPECTED_BASE="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
REAL_EXPECTED_BASE=$(cd "$EXPECTED_BASE" 2>/dev/null && pwd) || REAL_EXPECTED_BASE="$EXPECTED_BASE"
case "$REAL_PLANS_DIR" in
    "$REAL_EXPECTED_BASE" | "$REAL_EXPECTED_BASE"/*) ;;
    *)
        echo "[clarify-commit-scope] plans-dir '$PLANS_DIR_ARG' is outside expected base '$EXPECTED_BASE'" >&2
        exit 2
        ;;
esac

# --non-github: skip all gh calls
if [[ "$NON_GITHUB" -eq 1 ]]; then
    exit 0
fi

REPO_ARGS=()
if [[ -n "$REPO_SLUG" ]]; then
    REPO_ARGS+=("--repo" "$REPO_SLUG")
fi

# Path C: empty --issues
if [[ "$ISSUES_SET" -eq 1 && -z "$ISSUES_CSV" ]]; then
    GH_OUT=""
    if ! GH_OUT=$(gh issue create \
            --title "Tracking issue" \
            --body "Auto-created by clarify-intent" \
            --label "intent:clarified" \
            "${REPO_ARGS[@]}" 2>/dev/null); then
        echo "[clarify-commit-scope] gh issue create failed" >&2
        exit 1
    fi
    # Extract issue number from URL (last path component)
    ISSUE_NUM="${GH_OUT##*/}"
    echo "CREATED:${ISSUE_NUM}"
    exit 0
fi

# Path B: non-empty --issues
# Split CSV into array
IFS=',' read -ra ISSUE_LIST <<< "$ISSUES_CSV"

# CLOSED pre-scan FIRST — before any side effects
for N in "${ISSUE_LIST[@]}"; do
    N="${N// /}"
    [[ -z "$N" ]] && continue
    # issue-state-check.sh accepts [--repo slug] <N>; found via PATH or AGENTS_CONFIG_DIR
    STATE_OUT=""
    STATE_RC=0
    STATE_OUT=$(issue-state-check.sh "${REPO_ARGS[@]}" "$N" 2>/dev/null) || STATE_RC=$?
    if [[ "$STATE_OUT" = "closed" ]]; then
        echo "CLOSED:${N}"
        exit 2
    fi
done

# Per-N side effects: label → wip → board
for N in "${ISSUE_LIST[@]}"; do
    N="${N// /}"
    [[ -z "$N" ]] && continue
    gh issue edit "$N" --add-label "intent:clarified" "${REPO_ARGS[@]}" 2>/dev/null || true
    WIP_RC=0
    WIP_OUT=$(wip-set-single.sh set "$N" 2>/dev/null) || WIP_RC=$?
    if [[ "$WIP_RC" -eq 2 ]]; then
        echo "RC2"
        exit 2
    fi
    ensure-board-card.sh "$N" 2>/dev/null || true
done

exit 0
