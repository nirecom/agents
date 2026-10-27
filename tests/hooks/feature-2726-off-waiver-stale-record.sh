#!/usr/bin/env bash
# tests/hooks/feature-2726-off-waiver-stale-record.sh
# Tests: hooks/workflow-state/completion-approval.js, bin/workflow/lib/next-step/gate-mode.js, hooks/confirm-checkpoint.js
# Tags: confirm-gate, plan-approval, completion-approval, off-waiver, next-step, confirm-checkpoint, TL2, scope:issue-specific
# TL3 gap: a real session that edits an approved plan with CONFIRM_<STAGE>=off in the user's own
# .env and sees no permission dialog; mitigated by bin/check-verification-gate.sh (category: hook-registration).
# #2726: CONFIRM_<STAGE>=off in the config FILE waives outline / detail even with a stale approval
# record on file; the four readers agree; intent has no off waiver.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=lib/confirm-env-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"

OW_TMP="$(make_tmp)"
readonly OW_TMP
trap 'rm -rf "$OW_TMP"' EXIT
export WORKFLOW_STATE_DIR="$OW_TMP/workflow-state" WORKFLOW_PLANS_DIR="$OW_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$OW_TMP/no-transcripts" "$OW_TMP/repo"
unset CLAUDE_CODE_SESSION_ID PLAN_LANG 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$OW_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
confirm_env_root "$OW_TMP/cfg" CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on PLAN_LANG=english PLAN_SYNC_REMOTE_URL=
git init -q "$OW_TMP/repo" >/dev/null 2>&1
git -C "$OW_TMP/repo" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR
CLAUDE_PROJECT_DIR="$(np "$OW_TMP/repo")"
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
cd "$OW_TMP/repo" || exit 1

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2726-off-waiver-stale-record/driver.js"

# ow_run <mode> — one pass/fail per PASS|name / FAIL|name|detail line.
ow_run() {
  local out line rest
  out="$(run_with_timeout 180 node "$DRIVER" "$1" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$1" "$?")"
  [[ -z "$out" ]] && { fail "driver $1 produced no assertions"; return; }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line#*|}"
    case "$line" in
      PASS\|*) pass "$rest" ;;
      FAIL\|*) fail "${rest%%|*}" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$out"
}

case_begin "off-waives-a-stale-record-for-outline-and-detail" "hooks/workflow-state/completion-approval.js"
ow_run off-stale
case_end

case_begin "on-without-record-all-readers-agree-unapproved" "bin/workflow/lib/next-step/gate-mode.js"
ow_run on-none
case_end

case_begin "intent-off-with-stale-record-stays-unapproved" "hooks/confirm-checkpoint.js"
ow_run intent
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
