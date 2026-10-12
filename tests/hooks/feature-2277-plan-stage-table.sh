#!/usr/bin/env bash
# Tests: hooks/workflow-state/plan-stage-table.js, hooks/workflow-state/completion-approval.js, hooks/workflow-mark/confirm-approval-handler.js, hooks/workflow-mark/clarify-intent-complete-handler.js, bin/workflow/next-step
# Tags: plan-approval, completion-approval, plan-stage-table, confirm-intent, digest, confirm-off, TL2, scope:issue-specific
# #2277: the stage table is the SSOT for the 3 approval-gated steps; clarify_intent joins
# outline/detail at the completion boundary (sentinel and --advance), the intent digest skips
# `## Issues`, and only outline/detail keep the CONFIRM_<STAGE>=off waiver.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PST_TMP="$(make_tmp)"
readonly PST_TMP
trap 'rm -rf "$PST_TMP"' EXIT
export WORKFLOW_STATE_DIR="$PST_TMP/workflow-state" WORKFLOW_PLANS_DIR="$PST_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$PST_TMP/no-transcripts" "$PST_TMP/repo"
unset CLAUDE_CODE_SESSION_ID CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$PST_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
# Every gate armed: the off waiver is read from this config FILE only (off cases use their own).
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
git init -q "$PST_TMP/repo" >/dev/null 2>&1
git -C "$PST_TMP/repo" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR
CLAUDE_PROJECT_DIR="$(np "$PST_TMP/repo")"
cd "$PST_TMP/repo" || exit 1
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2277-plan-stage-table/table-driver.js"

# pst_report <driver-output> — one pass/fail per PASS|name / FAIL|name|detail line.
pst_report() {
  local line rest name
  [ -z "$1" ] && { fail "driver produced no assertions"; return; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$1"
}

pst_run() {
  pst_report "$(run_with_timeout 120 node "$DRIVER" "$@" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$*" "$?")"
}

case_begin "stage-table-rows-and-lookups" "hooks/workflow-state/plan-stage-table.js"
pst_run table
case_end

case_begin "completion-matrix-advance-and-sentinel" "bin/workflow/next-step"
pst_run complete
case_end

case_begin "intent-digest-excludes-issues" "hooks/workflow-state/completion-approval.js"
pst_run digest
case_end

case_begin "off-waiver-per-stage" "hooks/workflow-mark/clarify-intent-complete-handler.js"
pst_run off
case_end

case_begin "stored-confirm-flag-off-record-per-stage" "hooks/workflow-state/completion-approval.js"
pst_run storedoff
STORED_OFF_ROOT="$PST_TMP/cfg-stored-off"
mkdir -p "$STORED_OFF_ROOT"
printf 'CONFIRM_INTENT=off\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\nPLAN_SYNC_REMOTE_URL=\n' > "$STORED_OFF_ROOT/.env"
pst_report "$(AGENTS_MAIN_ROOT="$(np "$STORED_OFF_ROOT")" run_with_timeout 120 node "$DRIVER" storedoff pinned 2>&1 || printf 'FAIL|driver storedoff pinned|exit=%s\n' "$?")"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
