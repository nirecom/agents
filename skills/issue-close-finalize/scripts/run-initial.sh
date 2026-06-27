#!/bin/bash
# run-initial.sh — phase=initial orchestration for issue-close-finalize-worker
# Steps 1-6 only; caller writes the JSON state file.
# Usage: bash run-initial.sh <issue_number> <root_issue_number> [issue_repo]
# Env:   AGENTS_CONFIG_DIR  FINALIZE_SCRIPTS_DIR  MAIN_WORKTREE_PATH
# Stdout (eval-able KEY=VALUE):
#   STATUS  SUMMARY  OWNER_REPO  TRIAGE_ACTION  NEXT_STEPS
#   PR_NUMBER  MERGE_COMMIT  PROPOSAL_STATUS  PROPOSAL_PARENT
# Exit 0 always; check STATUS.
set -euo pipefail

ISSUE_NUMBER="${1:?issue_number required}"
ROOT_ISSUE_NUMBER="${2:?root_issue_number required}"
ISSUE_REPO="${3:-}"
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${FINALIZE_SCRIPTS_DIR:?FINALIZE_SCRIPTS_DIR not set}"
: "${MAIN_WORKTREE_PATH:?MAIN_WORKTREE_PATH not set}"

# Step 1: pre-flight — sets OWNER_REPO
rc=0
eval "$(AGENTS_CONFIG_DIR="$AGENTS_CONFIG_DIR" bash "$FINALIZE_SCRIPTS_DIR/pre-flight.sh")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    printf 'STATUS=failed\nSUMMARY=pre-flight failed\n'
    exit 0
fi

# Step 2: ICF-A triage — sets STATE SENTINEL ACTION NEXT_STEPS
rc=0
eval "$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-close-finalize-triage.sh" "$ISSUE_NUMBER")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    printf 'STATUS=failed\nSUMMARY=triage failed for #%s\n' "$ISSUE_NUMBER"
    exit 0
fi

PR_NUMBER=""
MERGE_COMMIT=""
PROPOSAL_STATUS="none"
PROPOSAL_PARENT=""

# Step 3: ICF-B PR/SHA resolution — when J in NEXT_STEPS AND ACTION != admin_close_path
if [[ ",${NEXT_STEPS}," == *",J,"* ]] && [[ "$ACTION" != "admin_close_path" ]]; then
    REPO_FLAG=""
    [[ -n "$ISSUE_REPO" ]] && REPO_FLAG="--repo $ISSUE_REPO"
    rc=0
    eval "$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/find-pr-by-marker.sh" \
        ${REPO_FLAG:+$REPO_FLAG} "$ISSUE_NUMBER")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=PR marker lookup failed for #%s\n' "$ISSUE_NUMBER"
        exit 0
    fi
fi

# Step 4: ICF-C sub-issue gate — when B in NEXT_STEPS
if [[ ",${NEXT_STEPS}," == *",B,"* ]]; then
    rc=0
    bash "$AGENTS_CONFIG_DIR/bin/issue-close-gate.sh" "$OWNER_REPO" "$ISSUE_NUMBER" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=sub-issue gate blocked #%s\n' "$ISSUE_NUMBER"
        exit 0
    fi
fi

# Step 5: ICF-D parent body update — when G in NEXT_STEPS (non-fatal)
if [[ ",${NEXT_STEPS}," == *",G,"* ]]; then
    bash "$AGENTS_CONFIG_DIR/bin/github-issues/parent-body-update.sh" \
        "$OWNER_REPO" "$ISSUE_NUMBER" || true
fi

# Step 6: ICF-E g5 prepare — when G in NEXT_STEPS
if [[ ",${NEXT_STEPS}," == *",G,"* ]]; then
    rc=0
    eval "$(OWNER_REPO="$OWNER_REPO" bash "$FINALIZE_SCRIPTS_DIR/step-g5-loop.sh" \
        prepare "$ISSUE_NUMBER")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=ICF-E prepare failed for #%s\n' "$ISSUE_NUMBER"
        exit 0
    fi
fi

printf 'STATUS=init_done\nOWNER_REPO=%s\nTRIAGE_ACTION=%s\nNEXT_STEPS=%s\n' \
    "$OWNER_REPO" "$ACTION" "$NEXT_STEPS"
printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "${PR_NUMBER:-}" "${MERGE_COMMIT:-}"
printf 'PROPOSAL_STATUS=%s\nPROPOSAL_PARENT=%s\n' \
    "${PROPOSAL_STATUS:-none}" "${PROPOSAL_PARENT:-}"
printf 'SUMMARY=init_done for #%s\n' "$ISSUE_NUMBER"
