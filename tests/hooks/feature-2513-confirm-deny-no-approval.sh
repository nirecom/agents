#!/usr/bin/env bash
# tests/hooks/feature-2513-confirm-deny-no-approval.sh
# Tests: hooks/confirm-checkpoint.js, hooks/workflow-mark/confirm-approval-handler.js
# Tags: confirm-checkpoint, plan-approval, confirm-sentinel, deny, pretooluse, posttooluse, hook-order, TL2, scope:issue-specific, same-turn-continuation
# #2513: a CONFIRM_<STAGE> echo that confirm-checkpoint denies never reaches the PostToolUse
# approval handler, so it leaves no plan_approvals record and nothing downstream (the Skill gate,
# next-step --advance) can complete the stage. The allowed control records the approval bound to
# the plan hash. The driver runs the real hook scripts in the host's order.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# TL3 gap (what this test does NOT catch):
# - that the real Claude Code host skips PostToolUse after a PreToolUse deny; the driver replays
#   that order itself. Real-host registration of the Skill gate: tests/hooks/TL3-hook-gate-plan-skill-advance.sh.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

CDN_TMP="$(make_tmp)"
readonly CDN_TMP
trap 'rm -rf "$CDN_TMP"' EXIT
export WORKFLOW_STATE_DIR="$CDN_TMP/workflow-state" WORKFLOW_PLANS_DIR="$CDN_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CDN_TMP/no-transcripts" "$CDN_TMP/cases" "$CDN_TMP/repo"
unset CLAUDE_CODE_SESSION_ID PLAN_LANG CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$CDN_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
# Every gate armed: the off waiver is read from this config FILE, so no stage is waived.
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\nPLAN_LANG=english\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
git init -q "$CDN_TMP/repo" >/dev/null 2>&1
git -C "$CDN_TMP/repo" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR CDN_TDIR
CLAUDE_PROJECT_DIR="$(np "$CDN_TMP/repo")"
CDN_TDIR="$(np "$CDN_TMP/cases")"
cd "$CDN_TMP/repo" || exit 1
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-confirm-deny-no-approval/pipeline-driver.js"

# cdn_report <driver-output> — one pass/fail per PASS|name / FAIL|name|detail line.
cdn_report() {
  local line rest name
  [[ -z "$1" ]] && { fail "driver produced no assertions"; return; }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$1"
}

cdn_run() {
  cdn_report "$(run_with_timeout 120 node "$DRIVER" "$@" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$*" "$?")"
}

# #2650: same-turn continuation (valid mark) -> ask dialog -> Deny -> no PostToolUse.
SAMTURN_DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-confirm-deny-no-approval/samturn-deny-driver.js"
cdn_run_samturn() {
  cdn_report "$(run_with_timeout 120 node "$SAMTURN_DRIVER" "$@" 2>&1 || printf 'FAIL|samturn driver %s|exit=%s\n' "$*" "$?")"
}

case_begin "denied-echo-records-nothing-intent" "hooks/confirm-checkpoint.js"
cdn_run intent
case_end

case_begin "denied-echo-records-nothing-outline" "hooks/workflow-mark/confirm-approval-handler.js"
cdn_run outline
case_end

case_begin "denied-echo-records-nothing-detail" "hooks/workflow-mark/confirm-approval-handler.js"
cdn_run detail
case_end

case_begin "same-turn-continuation-deny-records-nothing-intent" "hooks/confirm-checkpoint.js"
cdn_run_samturn intent
case_end

case_begin "same-turn-continuation-deny-records-nothing-outline" "hooks/confirm-checkpoint.js"
cdn_run_samturn outline
case_end

case_begin "same-turn-continuation-deny-records-nothing-detail" "hooks/confirm-checkpoint.js"
cdn_run_samturn detail
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
