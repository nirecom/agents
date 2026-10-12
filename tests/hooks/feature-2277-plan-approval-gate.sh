#!/usr/bin/env bash
# Tests: hooks/workflow-state/plan-approval-check.js, bin/workflow/check-plan-approval, hooks/gate-plan-skill-advance.js, settings.json
# Tags: plan-approval, completion-approval, skill-gate, pretooluse, confirm-intent, fail-open, TL2, scope:issue-specific
# #2277: one approval verdict (approved / unapproved / skipped / not-applicable / unknown)
# shared by a CLI and a PreToolUse Skill gate that denies only `unapproved`.
#
# TL3 gap (what this test does NOT catch):
# - Whether a live Claude Code session delivers `tool_input.skill` to the PreToolUse Skill
#   matcher and honours the deny (live seam: tests/hooks/TL3-hook-gate-plan-skill-advance.sh).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PAG_TMP="$(make_tmp)"
readonly PAG_TMP
trap 'rm -rf "$PAG_TMP"' EXIT
export WORKFLOW_STATE_DIR="$PAG_TMP/workflow-state" WORKFLOW_PLANS_DIR="$PAG_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$PAG_TMP/no-transcripts"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$PAG_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
# Every gate armed: the off waiver is read from this config FILE only.
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
cd "$PAG_TMP" || exit 1
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2277-plan-approval-gate/gate-driver.js"

# pag_report <driver-output> — one pass/fail per PASS|name / FAIL|name|detail line.
pag_report() {
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

pag_run() {
  pag_report "$(run_with_timeout 120 node "$DRIVER" "$@" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$*" "$?")"
}

case_begin "check-plan-approval-verdicts" "hooks/workflow-state/plan-approval-check.js"
pag_run check
case_end

case_begin "check-plan-approval-cli" "bin/workflow/check-plan-approval"
pag_run cli
case_end

case_begin "skill-gate-deny-only-unapproved" "hooks/gate-plan-skill-advance.js"
pag_run gate
case_end

case_begin "skill-gate-registered" "settings.json"
pag_run settings
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
