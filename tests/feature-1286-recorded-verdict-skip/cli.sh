#!/bin/bash
# shellcheck shell=bash
# feature-1286 CLI cases: bin/workflow/record-skip-judgment.
# Relies on helpers.sh being sourced by the dispatcher.

echo ""
echo "=== RV-6 / RV-18: bin/workflow/record-skip-judgment CLI ==="

if [ ! -f "$RECORD_CLI" ]; then
  # Red-phase: CLI not yet implemented.
  fail "RV-6a: valid outline → RECORDED=outline (CLI not yet implemented)"
  fail "RV-6a: valid outline → exit 0 (CLI not yet implemented)"
  fail "RV-6b: invalid --target exits non-zero (CLI not yet implemented)"
  fail "RV-6c: detail without --c3 exits non-zero (CLI not yet implemented)"
  fail "RV-18a: valid detail → RECORDED=detail (CLI not yet implemented)"
  fail "RV-18b: valid detail → all_conditions_met=true (CLI not yet implemented)"
  fail "RV-18c: valid detail → exit 0 (CLI not yet implemented)"
else
  # RV-6a: valid outline args → exit 0 + RECORDED=outline in stdout.
  RV6A_RC=0
  RV6A_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv6a --target outline --c1 --c2 2>&1)" || RV6A_RC=$?
  check_contains "RV-6a: valid outline → stdout contains RECORDED=outline" "RECORDED=outline" "$RV6A_OUT"
  if [ "$RV6A_RC" -eq 0 ]; then pass "RV-6a: valid outline → exit 0"
  else fail "RV-6a: valid outline → expected exit 0, got $RV6A_RC"; fi

  # RV-6b: invalid --target → exit non-zero.
  RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv6b --target badvalue --c1 --c2 >/dev/null 2>&1 || RC=$?
  if [ "$RC" -ne 0 ]; then pass "RV-6b: invalid --target exits non-zero"
  else fail "RV-6b: invalid --target should exit non-zero, got exit 0"; fi

  # RV-6c: detail missing --c3 → exit non-zero.
  RC=0
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv6c --target detail --c1 --c2 >/dev/null 2>&1 || RC=$?
  if [ "$RC" -ne 0 ]; then pass "RV-6c: detail without --c3 exits non-zero"
  else fail "RV-6c: detail without --c3 should exit non-zero, got exit 0"; fi

  # RV-18: valid detail args → exit 0 + RECORDED=detail + all_conditions_met=true.
  RV18_RC=0
  RV18_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$RECORD_CLI_N" \
    --session rv18 --target detail --c1 true --c2 true --c3 true 2>&1)" || RV18_RC=$?
  check_contains "RV-18a: valid detail → stdout contains RECORDED=detail" "RECORDED=detail" "$RV18_OUT"
  check_contains "RV-18b: valid detail → stdout contains all_conditions_met=true" "all_conditions_met=true" "$RV18_OUT"
  if [ "$RV18_RC" -eq 0 ]; then pass "RV-18c: valid detail → exit 0"
  else fail "RV-18c: valid detail → expected exit 0, got $RV18_RC"; fi
fi
