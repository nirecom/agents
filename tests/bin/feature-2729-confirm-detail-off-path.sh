#!/usr/bin/env bash
# tests/bin/feature-2729-confirm-detail-off-path.sh
# Tests: bin/workflow/lib/next-step/gate-mode.js, hooks/show-plan-link.js, hooks/stop-confirm-plan-guard.js
# Tags: confirm-gate, confirm-detail, off-waiver, next-step, show-plan-link, stop-guard, TL2, scope:issue-specific
# TL3 gap: a real Claude Code session (and the Android app) running the detail step with
# CONFIRM_DETAIL=off; manual check after release (Accepted Tradeoffs in the #2729 plan).
# #2729 Gap 3: CONFIRM_DETAIL=off in $AGENTS_MAIN_ROOT/.env runs the detail step through
# --gate, the plan write, the Stop guard and --advance with no approval wait.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=lib/confirm-env-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"

DO_TMP="$(make_tmp)"
readonly DO_TMP
trap 'rm -rf "$DO_TMP"' EXIT
export WORKFLOW_STATE_DIR="$DO_TMP/workflow-state" WORKFLOW_PLANS_DIR="$DO_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$DO_TMP/no-transcripts" "$DO_TMP/repo"
unset CLAUDE_CODE_SESSION_ID PLAN_LANG 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$DO_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
confirm_env_root "$DO_TMP/cfg" CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on PLAN_LANG=english PLAN_SYNC_REMOTE_URL=
git init -q "$DO_TMP/repo" >/dev/null 2>&1
git -C "$DO_TMP/repo" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR
CLAUDE_PROJECT_DIR="$(np "$DO_TMP/repo")"
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
cd "$DO_TMP/repo" || exit 1

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2729-confirm-detail-off-path/driver.js"

# do_run <mode> — one pass/fail per PASS|name / FAIL|name|detail line.
do_run() {
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

case_begin "detail-off-path-without-a-record" "hooks/stop-confirm-plan-guard.js"
do_run off-none
case_end

case_begin "detail-off-path-with-a-stale-record" "hooks/show-plan-link.js"
do_run off-stale
case_end

case_begin "export-only-off-still-asks" "bin/workflow/lib/next-step/gate-mode.js"
do_run export-only
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
