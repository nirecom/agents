#!/usr/bin/env bash
# tests/hooks/feature-2729-confirm-file-only.sh
# Tests: hooks/lib/config-flag.js, hooks/lib/local-env.js, hooks/lib/plan-confirm-flag.js
# Tags: confirm-gate, config-flag, local-env, plan-confirm-flag, env-file, TL2, scope:issue-specific
# TL3 gap: the user's real ~/.claude settings and a real project .env.local on a live machine;
# mitigated by bin/check-verification-gate.sh (category: hook-registration).
# #2729 Gap 2: CONFIRM_INTENT/OUTLINE/DETAIL come from $AGENTS_MAIN_ROOT/.env only; an export or a
# project .env.local value is ignored by every reader, while other CONFIRM_* keys keep the export.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=lib/confirm-env-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"

FO_TMP="$(make_tmp)"
readonly FO_TMP
trap 'rm -rf "$FO_TMP"' EXIT
export WORKFLOW_STATE_DIR="$FO_TMP/workflow-state" WORKFLOW_PLANS_DIR="$FO_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$FO_TMP/no-transcripts"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR CONFIRM_CODE 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$FO_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
confirm_env_root "$FO_TMP/cfg" CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
cd "$FO_TMP" || exit 1

DRIVER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2729-confirm-file-only/driver.js"

# fo_run <mode> — one pass/fail per PASS|name / FAIL|name|detail line.
fo_run() {
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

case_begin "export-off-ignored-by-every-reader" "hooks/lib/config-flag.js"
fo_run export
case_end

case_begin "env-local-off-ignored-by-every-reader" "hooks/lib/local-env.js"
fo_run local
case_end

case_begin "env-file-off-is-off-everywhere" "hooks/lib/plan-confirm-flag.js"
fo_run file-off
case_end

case_begin "other-confirm-keys-keep-export-and-local" "hooks/lib/config-flag.js"
fo_run control
case_end

case_begin "overlay-blocklist-and-config-flag-exports" "hooks/lib/local-env.js"
fo_run unit
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
