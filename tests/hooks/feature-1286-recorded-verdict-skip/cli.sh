#!/bin/bash
# shellcheck shell=bash
# feature-1286 CLI cases: bin/workflow/record-skip-judgment, end-state (#2460) argv:
# --cond k=v (repeated, exact schema key set), --source jev|subagent|mixed and
# --ticket <16-hex>, both required. The retired --c1/--c2/--c3 are unknown args.
# Relies on helpers.sh being sourced by the dispatcher.

T1="0123456789abcdef"
RSJ_OUT=""; RSJ_RC=0
rsj() {
  RSJ_RC=0
  RSJ_OUT="$(run_with_timeout node "$RECORD_CLI_N" "$@" 2>&1)" || RSJ_RC=$?
}
# expect_rejected <desc> <want-rc|nonzero> <sid> <target> -- <argv...>
# Asserts the exit code AND that no skip_judgment was persisted for <sid>/<target>.
expect_rejected() {
  local desc="$1" want="$2" sid="$3" target="$4"
  shift 5
  rsj "$@"
  if [ "$want" = "nonzero" ]; then
    if [ "$RSJ_RC" -ne 0 ]; then pass "$desc: exits non-zero"
    else fail "$desc: expected non-zero exit, got 0 -- $RSJ_OUT"; fi
  else
    check "$desc: exit $want" "$want" "$RSJ_RC"
  fi
  check "$desc: nothing persisted" "null" "$(read_skip_judgment_raw "$sid" "$target")"
  check_not_contains "$desc: no RECORDED= success line" "RECORDED=$target" "$RSJ_OUT"
}

echo ""
echo "=== RV-6 / RV-18: record-skip-judgment new-form CLI ==="
SD_OK='{"sd_single_approach":true,"sd_no_open_decision":true}'
ticketed rv6a outline "$T1" '{"so_c1":true,"so_c2":true}' subagent
rsj --session rv6a --target outline --cond so_c1=true --cond so_c2=true --source subagent --ticket "$T1"
check "RV-6a: valid outline → exit 0" "0" "$RSJ_RC"
check_contains "RV-6a: valid outline → RECORDED=outline all_conditions_met=true" \
  "RECORDED=outline all_conditions_met=true" "$RSJ_OUT"
RV6A_SJ="$(read_skip_judgment_raw rv6a outline)"
check_contains "RV-6a: --source value persisted as judgment_source" '"judgment_source":"subagent"' "$RV6A_SJ"
check_contains "RV-6a: --ticket value persisted" "\"ticket\":\"$T1\"" "$RV6A_SJ"
check_contains "RV-6a: so_c2 persisted true" '"so_c2":true' "$RV6A_SJ"

expect_rejected "RV-6b: invalid --target" nonzero rv6b badvalue -- \
  --session rv6b --target badvalue --cond so_c1=true --cond so_c2=true --source jev --ticket "$T1"
expect_rejected "RV-6c: detail with sd_no_open_decision missing" 2 rv6c detail -- \
  --session rv6c --target detail --cond sd_single_approach=true --source jev --ticket "$T1"
expect_rejected "RV-6d: outline given the detail key set" 2 rv6d outline -- \
  --session rv6d --target outline --cond sd_single_approach=true --cond sd_no_open_decision=true --source jev --ticket "$T1"
expect_rejected "RV-6e: outline with an excess key" 2 rv6e outline -- \
  --session rv6e --target outline --cond so_c1=true --cond so_c2=true --cond so_c3=true --source jev --ticket "$T1"
expect_rejected "RV-6f: detail given the retired sd_c1..sd_c3 keys" 2 rv6f detail -- \
  --session rv6f --target detail --cond sd_c1=true --cond sd_c2=true --cond sd_c3=true --source jev --ticket "$T1"

ticketed rv18 detail "$T1" "$SD_OK" jev
ticketed rv18f detail "$T1" '{"sd_single_approach":false,"sd_no_open_decision":true}' mixed
rsj --session rv18 --target detail --cond sd_single_approach=true --cond sd_no_open_decision=true --source jev --ticket "$T1"
check "RV-18a: valid detail → exit 0" "0" "$RSJ_RC"
check_contains "RV-18b: valid detail → RECORDED=detail all_conditions_met=true" \
  "RECORDED=detail all_conditions_met=true" "$RSJ_OUT"
check_contains "RV-18c: detail persisted with source jev" '"judgment_source":"jev"' "$(read_skip_judgment_raw rv18 detail)"
rsj --session rv18f --target detail --cond sd_single_approach=false --cond sd_no_open_decision=true --source mixed --ticket "$T1"
check "RV-18d: a false value is a valid recording → exit 0" "0" "$RSJ_RC"
check_contains "RV-18d: false value → all_conditions_met=false" "RECORDED=detail all_conditions_met=false" "$RSJ_OUT"

echo ""
echo "=== RV-40: retired --c1/--c2/--c3 are unknown args (exit 2), mixing is exit 2 ==="
expect_rejected "RV-40a: old outline form --c1/--c2" 2 rv40a outline -- \
  --session rv40a --target outline --c1 true --c2 true
expect_rejected "RV-40b: old detail form --c1/--c2/--c3" 2 rv40b detail -- \
  --session rv40b --target detail --c1 true --c2 true --c3 true
expect_rejected "RV-40c: old form even with --source/--ticket" 2 rv40c outline -- \
  --session rv40c --target outline --c1 true --c2 true --source jev --ticket "$T1"
expect_rejected "RV-40d: new and old args mixed" 2 rv40d outline -- \
  --session rv40d --target outline --cond so_c1=true --cond so_c2=true --c1 true --source jev --ticket "$T1"
expect_rejected "RV-40e: bare old flag (no value) beside the new form" 2 rv40e outline -- \
  --session rv40e --target outline --cond so_c1=true --cond so_c2=true --source jev --ticket "$T1" --c2

echo ""
echo "=== RV-41: --source and --ticket are required ==="
expect_rejected "RV-41a: --source missing" nonzero rv41a outline -- \
  --session rv41a --target outline --cond so_c1=true --cond so_c2=true --ticket "$T1"
expect_rejected "RV-41b: --ticket missing" nonzero rv41b outline -- \
  --session rv41b --target outline --cond so_c1=true --cond so_c2=true --source jev
expect_rejected "RV-41c: --source with no value" nonzero rv41c outline -- \
  --session rv41c --target outline --cond so_c1=true --cond so_c2=true --ticket "$T1" --source
expect_rejected "RV-41d: --cond missing entirely" nonzero rv41d outline -- \
  --session rv41d --target outline --source jev --ticket "$T1"

echo ""
echo "=== RV-42: untrusted --source / --cond / --ticket values are rejected, never persisted ==="
PWNED="$TMPDIR_BASE/pwned-marker"
PWNED_N="$(cygpath -m "$PWNED" 2>/dev/null || echo "$PWNED")"
n=0
while IFS='|' read -r v_flag v_value v_label; do
  [ -z "$v_flag" ] && continue
  n=$((n + 1)); sid="rv42-$n"
  v_value="${v_value//@PWNED@/$PWNED_N}"
  case "$v_flag" in
    source) set -- --cond so_c1=true --cond so_c2=true --source "$v_value" --ticket "$T1" ;;
    ticket) set -- --cond so_c1=true --cond so_c2=true --source jev --ticket "$v_value" ;;
    cond)   set -- --cond so_c1=true --cond "$v_value" --source jev --ticket "$T1" ;;
  esac
  expect_rejected "RV-42 [$v_label]" nonzero "$sid" outline -- --session "$sid" --target outline "$@"
done <<'UNTRUSTED'
source|orchestrator|retired source orchestrator
source|user|source outside JUDGMENT_SOURCES
source|JEV|source case variant
source|jev;touch @PWNED@|source with a command separator
source|$(touch @PWNED@)|source with command substitution
source|jev subagent|source with whitespace
ticket|0123456789abcde|ticket of 15 hex chars
ticket|0123456789abcdeg|ticket with a non-hex char
ticket|0123456789abcdef;touch @PWNED@|ticket with a command separator
ticket|$(touch @PWNED@)|ticket with command substitution
cond|so_c2=maybe|cond value not true/false
cond|so_c2=|cond with an empty value
cond|so_c2|cond without =
cond|so_c2=true;touch @PWNED@|cond value with a command separator
cond|so_c2=$(touch @PWNED@)|cond value with command substitution
cond|__proto__=true|cond key __proto__
cond|constructor=true|cond key constructor
UNTRUSTED
set --
if [ -e "$PWNED" ]; then fail "RV-42z: an injected command ran (marker file exists)"
else pass "RV-42z: no injected command ran"; fi

# ---------------------------------------------------------------------------
# RV-33: write failure (WORKFLOW_STATE_DIR points at a regular file, so mkdir
# fails with ENOTDIR) → non-zero exit + "write verification failed".
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-33: CLI write failure → exit non-zero + 'write verification failed' ==="
RV33_BLOCK="$TMPDIR_BASE/wfblock"
touch "$RV33_BLOCK"
RV33_BLOCK_N="$(cygpath -m "$RV33_BLOCK" 2>/dev/null || echo "$RV33_BLOCK")"
RV33_RC=0
ticketed rv33cli outline "$T1" '{"so_c1":true,"so_c2":true}' jev
RV33_OUT="$(WORKFLOW_STATE_DIR="$RV33_BLOCK_N" run_with_timeout node "$RECORD_CLI_N" \
  --session rv33cli --target outline --cond so_c1=true --cond so_c2=true --source jev --ticket "$T1" 2>&1)" || RV33_RC=$?
if [ "$RV33_RC" -ne 0 ]; then pass "RV-33a: write failure → exit non-zero"
else fail "RV-33a: expected exit non-zero on write failure, got exit 0"; fi
check_contains "RV-33b: stderr contains 'write verification failed'" "write verification failed" "$RV33_OUT"

# ---------------------------------------------------------------------------
# RV-34: an older record must not be reported as success when the current
# write fails (read-back must match the CURRENT source/ticket/conditions).
# ---------------------------------------------------------------------------
echo ""
echo "=== RV-34: stale record must not be reported as success ==="
ticketed rv34cli outline "$T1" '{"so_c1":true,"so_c2":true}' jev
ticketed rv34cli outline fedcba9876543210 '{"so_c1":true,"so_c2":false}' subagent
run_with_timeout node "$RECORD_CLI_N" --session rv34cli --target outline \
  --cond so_c1=true --cond so_c2=true --source jev --ticket "$T1" >/dev/null 2>&1 || true
check_contains "RV-34 setup: the older record exists" '"judgment_source":"jev"' "$(read_skip_judgment_raw rv34cli outline)"
RV34_RC=0
RV34_OUT="$(WORKFLOW_STATE_DIR="$RV33_BLOCK_N" run_with_timeout node "$RECORD_CLI_N" \
  --session rv34cli --target outline --cond so_c1=true --cond so_c2=false --source subagent --ticket fedcba9876543210 2>&1)" || RV34_RC=$?
if [ "$RV34_RC" -ne 0 ]; then pass "RV-34a: stale record → exit non-zero (no false success)"
else fail "RV-34a: expected exit non-zero for stale record, got exit 0"; fi
check_not_contains "RV-34b: stale record → no RECORDED=outline in stdout" "RECORDED=outline" "$RV34_OUT"
check_contains "RV-34c: the refusal is the write check, not the ticket check" "write verification failed" "$RV34_OUT"
