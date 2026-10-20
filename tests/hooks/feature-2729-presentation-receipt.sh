#!/usr/bin/env bash
# tests/hooks/feature-2729-presentation-receipt.sh
# Tests: hooks/lib/presentation-receipt.js, hooks/stop-confirm-plan-guard.js, hooks/confirm-checkpoint.js, hooks/lib/confirm-continuation.js
# Tags: confirm-checkpoint, confirm-plan, stop-guard, presentation-receipt, plan-link, TL2, scope:issue-specific
# TL3 gap: whether the host shows the Stop-approved last text block to the user before the echo,
# and the real plan-sync publish timing; mitigated by bin/check-verification-gate.sh (category: hook-registration).
# #2729 (Gap 1/4/5) + #2628: Stop writes a presentation receipt only for a non-blocked turn that
# closes on its link-line run; confirm-checkpoint matches path, link and content against it,
# fail-closed, with no cap. Repro drivers (R1, R2, R13) and R3-R12, R14, R15 live in the sibling directory.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=lib/confirm-env-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"

PRR_TMP="$(make_tmp)"
readonly PRR_TMP
trap 'rm -rf "$PRR_TMP"' EXIT
export WORKFLOW_STATE_DIR="$PRR_TMP/workflow-state" WORKFLOW_PLANS_DIR="$PRR_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$PRR_TMP/no-transcripts"
unset CLAUDE_CODE_SESSION_ID PLAN_LANG 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$PRR_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
confirm_env_root "$PRR_TMP/cfg" CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on PLAN_LANG=english PLAN_SYNC_REMOTE_URL=
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
cd "$PRR_TMP" || exit 1

DDIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2729-presentation-receipt"

# prr_run <driver.js> [args...] — one pass/fail per PASS|name / FAIL|name|detail line.
prr_run() {
  local out line rest
  out="$(run_with_timeout 120 node "$DDIR/$1" "${@:2}" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$*" "$?")"
  [[ -z "$out" ]] && { fail "driver $* produced no assertions"; return; }
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

case_begin "receipt-store-unit" "hooks/lib/presentation-receipt.js"
prr_run unit-driver.js
case_end

case_begin "r1-repro-0731580d-dialog-after-task-notification" "hooks/confirm-checkpoint.js"
prr_run repro-0731580d-driver.js
case_end

case_begin "r2-repro-1d12371e-link-then-question-blocks" "hooks/stop-confirm-plan-guard.js"
prr_run repro-1d12371e-driver.js
case_end

case_begin "r13-multi-stage-close-on-link-every-shown-stage" "hooks/stop-confirm-plan-guard.js"
prr_run repro-multi-stage-driver.js
case_end

case_begin "r3-stop-hook-active-writes-receipt" "hooks/stop-confirm-plan-guard.js"
prr_run r-cases-driver.js R3
case_end

case_begin "r4-content-path-link-unpublished-mismatch" "hooks/confirm-checkpoint.js"
prr_run r-cases-driver.js R4
case_end

case_begin "r5-no-receipt-denied-without-cap" "hooks/confirm-checkpoint.js"
prr_run r-cases-driver.js R5
case_end

case_begin "r6-two-stages-two-receipts" "hooks/lib/confirm-continuation.js"
prr_run r-cases-driver.js R6
case_end

case_begin "r7-pass-consumes-receipt" "hooks/confirm-checkpoint.js"
prr_run r-cases-driver.js R7
case_end

case_begin "r8-unverifiable-fails-closed" "hooks/confirm-checkpoint.js"
prr_run r-cases-driver.js R8
case_end

case_begin "r9-gate-off-no-receipt-no-block" "hooks/stop-confirm-plan-guard.js"
prr_run r-cases-driver.js R9
case_end

case_begin "r10-blocked-turn-discards-all-receipts" "hooks/stop-confirm-plan-guard.js"
prr_run r-cases-driver.js R10
case_end

case_begin "r11-unpublishable-path-receipt-and-not-published-block" "hooks/stop-confirm-plan-guard.js"
prr_run r-cases-driver.js R11
case_end

case_begin "r12-exception-discards-receipts" "hooks/stop-confirm-plan-guard.js"
prr_run r-cases-driver.js R12
case_end

case_begin "r14-concurrent-echoes-one-receipt-single-pass" "hooks/confirm-checkpoint.js"
prr_run r-cases-driver.js R14
case_end

case_begin "r15-consumed-presentation-not-reusable-and-detail-symmetry" "hooks/confirm-checkpoint.js"
prr_run r-cases-driver.js R15
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
