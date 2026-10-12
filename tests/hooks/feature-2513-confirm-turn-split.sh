#!/usr/bin/env bash
# tests/hooks/feature-2513-confirm-turn-split.sh
# Tests: hooks/confirm-checkpoint.js, hooks/lib/confirm-sentinel.js, hooks/lib/confirm-deny-counter.js
# Tags: confirm-checkpoint, confirm-sentinel, turn-split, plan-link, deny-cap, fail-open, pretooluse, TL2, scope:issue-specific
# #2513: a CONFIRM_<STAGE> echo is denied unless the previous turn ended its last text block on
# the stage's plan-link line, a real user prompt lies in between, and this turn did not rewrite
# the plan. Two denies in a row, then the third passes with a supervisor finding; fail-open on
# anything unreadable. The backtick-URL rule of shown() is unit-tested in
# feature-plan-url-stop-guard/unit-turn-split.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

CTS_TMP="$(make_tmp)"
readonly CTS_TMP
trap 'rm -rf "$CTS_TMP"' EXIT
export WORKFLOW_STATE_DIR="$CTS_TMP/workflow-state" WORKFLOW_PLANS_DIR="$CTS_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CTS_TMP/no-transcripts" "$CTS_TMP/cases"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR PLAN_LANG 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$CTS_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
printf 'PLAN_LANG=english\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
cd "$CTS_TMP" || exit 1

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-confirm-turn-split/hook-driver.js"
export CC_HOOK CS_LIB CTS_TDIR CTS_PUBLISH_STUB WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR
CC_HOOK="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/confirm-checkpoint.js")"
# Publish-on cases: a preload stubs plan-sync with an example.invalid blob URL (no network).
CTS_PUBLISH_STUB="$(np "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-confirm-turn-split/publish-stub.js")"
CS_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/confirm-sentinel.js")"
CTS_TDIR="$(np "$CTS_TMP/cases")"
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

# cts_report <driver-output> — one pass/fail per PASS|name / FAIL|name|detail line.
cts_report() {
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

# cts_run <mode> [stage] — runs the driver in one mode.
cts_run() {
  cts_report "$(run_with_timeout 120 node "$DRIVER" "$@" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$*" "$?")"
}

case_begin "parse-sentinel-table" "hooks/lib/confirm-sentinel.js"
cts_run sentinel
case_end

case_begin "turn-split-intent" "hooks/confirm-checkpoint.js"
cts_run split intent
case_end

case_begin "turn-split-outline" "hooks/confirm-checkpoint.js"
cts_run split outline
case_end

case_begin "turn-split-detail" "hooks/confirm-checkpoint.js"
cts_run split detail
case_end

case_begin "fenced-link-intent" "hooks/lib/plan-link-turn-check.js"
cts_run fence intent
case_end

case_begin "fenced-link-outline" "hooks/lib/plan-link-turn-check.js"
cts_run fence outline
case_end

case_begin "fenced-link-detail" "hooks/lib/plan-link-turn-check.js"
cts_run fence detail
case_end

case_begin "artifact-write-intent" "hooks/lib/plan-link-turn-check.js"
cts_run write intent
case_end

case_begin "artifact-write-outline" "hooks/lib/plan-link-turn-check.js"
cts_run write outline
case_end

case_begin "artifact-write-detail" "hooks/lib/plan-link-turn-check.js"
cts_run write detail
case_end

case_begin "deny-cap-and-reset" "hooks/lib/confirm-deny-counter.js"
cts_run cap intent
cts_run cap outline
cts_run cap detail
case_end

case_begin "previous-turn-span" "hooks/confirm-checkpoint.js"
cts_run span intent
cts_run span outline
cts_run span detail
case_end

case_begin "deny-cap-per-session-stage" "hooks/lib/confirm-deny-counter.js"
cts_run multi intent
cts_run multi outline
cts_run multi detail
case_end

case_begin "publish-link-intent" "hooks/confirm-checkpoint.js"
cts_run publish intent
case_end

case_begin "publish-link-outline" "hooks/confirm-checkpoint.js"
cts_run publish outline
case_end

case_begin "publish-link-detail" "hooks/confirm-checkpoint.js"
cts_run publish detail
case_end

case_begin "confirm-off-per-stage" "hooks/confirm-checkpoint.js"
cts_run env
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
