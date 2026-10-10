#!/bin/bash
# run-initial.sh — phase=initial orchestration for the issue-close-finalize worker
# Phases 1-6 only; caller writes the JSON state file.
# Usage: bash run-initial.sh --target-main-root <dir> <issue_number> <root_issue_number> [issue_repo]
# Env:   FINALIZE_SCRIPTS_DIR
# Stdout (eval-able KEY=VALUE):
#   STATUS  SUMMARY  OWNER_REPO  TRIAGE_ACTION  NEXT_STEPS
#   PR_NUMBER  MERGE_COMMIT  PROPOSAL_STATUS  PROPOSAL_PARENT
# Exit 0 always; check STATUS.
set -euo pipefail

TARGET_MAIN_ROOT=""
if [[ "${1:-}" == "--target-main-root" ]]; then
    TARGET_MAIN_ROOT="${2:?--target-main-root <dir> required}"
    shift 2
fi
ISSUE_NUMBER="${1:?issue_number required}"
ROOT_ISSUE_NUMBER="${2:?root_issue_number required}"
ISSUE_REPO="${3:-}"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
: "${FINALIZE_SCRIPTS_DIR:?FINALIZE_SCRIPTS_DIR not set}"
: "${TARGET_MAIN_ROOT:?--target-main-root <dir> required}"

cd "$TARGET_MAIN_ROOT"

# Each child's KEY=VALUE output is captured first and evaluated only after its exit code is
# checked: `eval "$(child)" || rc=$?` reports eval's status, so a failed child read as success.

# Phase 1: pre-flight — sets OWNER_REPO
rc=0
PREFLIGHT_KV="$(bash "$FINALIZE_SCRIPTS_DIR/pre-flight.sh")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    printf 'STATUS=failed\nSUMMARY=pre-flight failed\n'
    exit 0
fi
eval "$PREFLIGHT_KV"

# Phase 2: ICF-A triage — sets STATE SENTINEL ACTION NEXT_STEPS
rc=0
TRIAGE_KV="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-close-finalize-triage.sh" "$ISSUE_NUMBER")" || rc=$?
if [[ "$rc" -ne 0 ]]; then
    printf 'STATUS=failed\nSUMMARY=triage failed for #%s\n' "$ISSUE_NUMBER"
    exit 0
fi
eval "$TRIAGE_KV"

PR_NUMBER=""
MERGE_COMMIT=""
PROPOSAL_STATUS="none"
PROPOSAL_PARENT=""

# Phase 3: ICF-B PR/SHA resolution — when J in NEXT_STEPS AND ACTION != admin_close_path
if [[ ",${NEXT_STEPS}," == *",J,"* ]] && [[ "$ACTION" != "admin_close_path" ]]; then
    REPO_FLAG=""
    [[ -n "$ISSUE_REPO" ]] && REPO_FLAG="--repo $ISSUE_REPO"
    rc=0
    PR_KV="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/find-pr-by-marker.sh" \
        ${REPO_FLAG:+$REPO_FLAG} "$ISSUE_NUMBER")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=PR marker lookup failed for #%s\n' "$ISSUE_NUMBER"
        exit 0
    fi
    eval "$PR_KV"
fi

# Phase 4: ICF-C sub-issue gate — when B in NEXT_STEPS
if [[ ",${NEXT_STEPS}," == *",B,"* ]]; then
    rc=0
    bash "$SCRIPT_CHECKOUT_ROOT/bin/issue-close-gate.sh" "$OWNER_REPO" "$ISSUE_NUMBER" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=sub-issue gate blocked #%s\n' "$ISSUE_NUMBER"
        exit 0
    fi
fi

# Phase 5: ICF-D parent body update — when G in NEXT_STEPS (non-fatal)
if [[ ",${NEXT_STEPS}," == *",G,"* ]]; then
    bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/parent-body-update.sh" \
        "$OWNER_REPO" "$ISSUE_NUMBER" || true
fi

# Phase 6: ICF-E g5 prepare — when G in NEXT_STEPS
if [[ ",${NEXT_STEPS}," == *",G,"* ]]; then
    rc=0
    PROPOSAL_KV="$(OWNER_REPO="$OWNER_REPO" bash "$FINALIZE_SCRIPTS_DIR/step-g5-loop.sh" \
        prepare "$ISSUE_NUMBER")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf 'STATUS=failed\nSUMMARY=ICF-E prepare failed for #%s\n' "$ISSUE_NUMBER"
        exit 0
    fi
    eval "$PROPOSAL_KV"
fi

printf 'STATUS=init_done\nOWNER_REPO=%s\nTRIAGE_ACTION=%s\nNEXT_STEPS=%s\n' \
    "$OWNER_REPO" "$ACTION" "$NEXT_STEPS"
printf 'PR_NUMBER=%s\nMERGE_COMMIT=%s\n' "${PR_NUMBER:-}" "${MERGE_COMMIT:-}"
printf 'PROPOSAL_STATUS=%s\nPROPOSAL_PARENT=%s\n' \
    "${PROPOSAL_STATUS:-none}" "${PROPOSAL_PARENT:-}"
printf 'SUMMARY=init_done for #%s\n' "$ISSUE_NUMBER"
