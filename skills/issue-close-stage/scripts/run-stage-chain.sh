#!/bin/bash
# run-stage-chain.sh — Phase 1 issue-close-stage chain (Steps A, B, D, F, G)
# Usage: bash run-stage-chain.sh <issue_number> <owner_repo>
# Env:   AGENTS_CONFIG_DIR (required), ISSUE_CLOSE_SKILL=1 (set by caller)
# Stdout (eval-able KEY=VALUE): STATUS  SUMMARY  COMMENT_ID
# Exit 0 always; check STATUS for outcome.
set -euo pipefail

ISSUE_NUMBER="${1:?issue_number required}"
OWNER_REPO="${2:?owner_repo required}"
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

export ISSUE_CLOSE_SKILL=1

# Step A: triage
eval "$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-close-stage-triage.sh" "$ISSUE_NUMBER")"
# Sets: STATE SENTINEL ACTION NEXT_STEPS

if [[ "$ACTION" == "phase1_done" ]]; then
    printf 'STATUS=phase1_done\nSUMMARY=Phase 1 already complete for #%s\n' "$ISSUE_NUMBER"
    exit 0
fi

case "$ACTION" in
    error*)
        printf 'STATUS=error\nSUMMARY=triage error for #%s: ACTION=%s\n' "$ISSUE_NUMBER" "$ACTION"
        exit 0
        ;;
esac

COMMENT_ID=""
IFS=',' read -ra STEPS <<< "${NEXT_STEPS:-}"

for STEP in "${STEPS[@]}"; do
    STEP="${STEP// /}"
    case "$STEP" in
        B)
            rc=0
            bash "$AGENTS_CONFIG_DIR/bin/issue-close-gate.sh" "$OWNER_REPO" "$ISSUE_NUMBER" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                printf 'STATUS=blocked_sub_issue\nSUMMARY=sub-issue gate blocked #%s\n' "$ISSUE_NUMBER"
                exit 0
            fi
            ;;
        D)
            COMMENT_URL=$(gh issue comment "$ISSUE_NUMBER" \
                --body "<!-- issue-close-sentinel: pending -->" 2>/dev/null | tail -n 1)
            COMMENT_ID=$(printf '%s' "$COMMENT_URL" | grep -oE '[0-9]+$' || true)
            if [[ -z "$COMMENT_ID" ]]; then
                printf 'STATUS=error\nSUMMARY=Step D: failed to extract comment ID\n'
                exit 0
            fi
            ;;
        F)
            if [[ -z "$COMMENT_ID" ]]; then
                COMMENT_ID=$(gh issue view "$ISSUE_NUMBER" --json comments \
                    --jq '[.comments[] | select(.body | test("^<!-- issue-close-sentinel:"))] | first | .url' \
                    | grep -oE '[0-9]+$' || true)
            fi
            rc=0
            gh api -X PATCH \
                "repos/$OWNER_REPO/issues/comments/$COMMENT_ID" \
                -f body="<!-- issue-close-sentinel: appended -->" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                printf 'STATUS=error\nSUMMARY=Step F: PATCH failed (comment %s)\n' "$COMMENT_ID"
                exit 0
            fi
            ;;
        G)
            bash "$AGENTS_CONFIG_DIR/bin/github-issues/parent-body-update.sh" \
                "$OWNER_REPO" "$ISSUE_NUMBER" || true
            ;;
    esac
done

printf 'STATUS=phase1_done\nSUMMARY=Phase 1 complete for #%s (comment %s)\nCOMMENT_ID=%s\n' \
    "$ISSUE_NUMBER" "$COMMENT_ID" "$COMMENT_ID"
