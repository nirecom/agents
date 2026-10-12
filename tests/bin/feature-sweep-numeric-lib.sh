#!/usr/bin/env bash
# tests/bin/feature-sweep-numeric-lib.sh
# Tests: bin/lib/sweep-numeric.sh
# Tags: scope:common, TL1, sweep-plans, sweep-branches, sweep-worktrees, numeric, validation, table-driven, pwsh-not-required
# sweep_validate_uint <name> <value> <min> <multiplier> <exit_code>, sourced in a
# child bash: accepted values return, rejected ones print one ERROR line and exit
# with the caller's code; a malformed min/multiplier/exit_code is a caller bug (2).

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

readonly T_ROOT="$(make_tmp)"
trap 'rm -rf "$T_ROOT"' EXIT
harness_isolate "$T_ROOT/wf"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/sweep-numeric.sh"

# run_v <name> <value> <min> <multiplier> <exit_code> -> V_RC, V_OUT, V_ERR
run_v() {
  local errf="$T_ROOT/err"
  V_RC=0
  V_OUT="$(bash -c 'source "$1" || exit 99; shift; sweep_validate_uint "$@"; echo ACCEPTED' _ "$LIB" "$@" 2>"$errf")" || V_RC=$?
  V_ERR="$(tr -d '\r' < "$errf")"
}

# expect_ok <label> <args...>
expect_ok() {
  local label="$1"; shift
  run_v "$@"
  if [ "$V_RC" -eq 0 ] && [ "$V_OUT" = "ACCEPTED" ] && [ -z "$V_ERR" ]; then
    pass "$label"
  else
    fail "$label" "rc=$V_RC out=$(printf '%q' "$V_OUT") err=$(printf '%q' "$V_ERR")"
  fi
}

# expect_reject <label> <want_rc> <want_msg_fragment> <args...>
expect_reject() {
  local label="$1" want_rc="$2" want_msg="$3"; shift 3
  run_v "$@"
  local lines
  lines="$(printf '%s\n' "$V_ERR" | grep -c .)"
  if [ "$V_RC" -eq "$want_rc" ] && [ "$V_OUT" != "ACCEPTED" ] && [ "$lines" -eq 1 ] \
     && printf '%s' "$V_ERR" | grep -qF "ERROR: $1 " \
     && printf '%s' "$V_ERR" | grep -qF "$want_msg"; then
    pass "$label"
  else
    fail "$label" "want rc=$want_rc msg~'$want_msg' got rc=$V_RC out=$(printf '%q' "$V_OUT") err=$(printf '%q' "$V_ERR")"
  fi
}

case_begin "N0-lib-present" "bin/lib/sweep-numeric.sh"
if [ -f "$LIB" ]; then pass "N0 bin/lib/sweep-numeric.sh exists"; else fail "N0 bin/lib/sweep-numeric.sh exists" "missing (not yet implemented)"; fi
case_end

case_begin "N1-accepts-valid" "bin/lib/sweep-numeric.sh"
expect_ok "N1 SWEEP_AGE_DAYS=1 (min) is accepted" SWEEP_AGE_DAYS 1 1 86400 2
expect_ok "N1 SWEEP_AGE_DAYS=7 is accepted" SWEEP_AGE_DAYS 7 1 86400 2
expect_ok "N1 SWEEP_AGE_DAYS at the safe max 106751991167300 is accepted" SWEEP_AGE_DAYS 106751991167300 1 86400 2
expect_ok "N1 --min-age-hours 0 is accepted when min is 0" --min-age-hours 0 0 3600 1
expect_ok "N1 --min-age-hours at the safe max 2562047788015215 is accepted" --min-age-hours 2562047788015215 0 3600 1
expect_ok "N1 --timeout-seconds 1 (min) is accepted" --timeout-seconds 1 1 1 1
expect_ok "N1 --timeout-seconds with 18 digits is accepted" --timeout-seconds 999999999999999999 1 1 1
case_end

case_begin "N2-non-integer" "bin/lib/sweep-numeric.sh"
for v in "" "abc" "+5" "-5" "1a" " 5" "1.5"; do
  expect_reject "N2 SWEEP_AGE_DAYS=$(printf '%q' "$v") is not a non-negative integer (exit 2)" 2 \
    "must be a non-negative integer" SWEEP_AGE_DAYS "$v" 1 86400 2
done
case_end

case_begin "N3-leading-zero" "bin/lib/sweep-numeric.sh"
for v in 010 08 00 0001; do
  expect_reject "N3 SWEEP_AGE_DAYS=$v has a leading zero (exit 2)" 2 \
    "must not have a leading zero" SWEEP_AGE_DAYS "$v" 1 86400 2
done
expect_reject "N3 --min-age-hours 00 has a leading zero even when min is 0 (exit 1)" 1 \
  "must not have a leading zero" --min-age-hours 00 0 3600 1
expect_reject "N3 --timeout-seconds 010 has a leading zero (exit 1)" 1 \
  "must not have a leading zero" --timeout-seconds 010 1 1 1
case_end

case_begin "N4-too-large" "bin/lib/sweep-numeric.sh"
expect_reject "N4 a 19-digit SWEEP_AGE_DAYS is too large (exit 2)" 2 \
  "is too large" SWEEP_AGE_DAYS 1000000000000000000 1 86400 2
expect_reject "N4 a 19-digit --timeout-seconds is too large (exit 1)" 1 \
  "is too large" --timeout-seconds 9223372036854775807 1 1 1
expect_reject "N4 a 25-digit --min-age-hours is too large (exit 1)" 1 \
  "is too large" --min-age-hours 9999999999999999999999999 0 3600 1
case_end

case_begin "N5-below-min" "bin/lib/sweep-numeric.sh"
expect_reject "N5 SWEEP_AGE_DAYS=0 is below min 1 (exit 2)" 2 \
  "must be at least 1" SWEEP_AGE_DAYS 0 1 86400 2
expect_reject "N5 --timeout-seconds 0 is below min 1 (exit 1)" 1 \
  "must be at least 1" --timeout-seconds 0 1 1 1
case_end

case_begin "N6-above-safe-max" "bin/lib/sweep-numeric.sh"
expect_reject "N6 SWEEP_AGE_DAYS safe max + 1 is rejected (exit 2)" 2 \
  "must be at most 106751991167300" SWEEP_AGE_DAYS 106751991167301 1 86400 2
expect_reject "N6 --min-age-hours safe max + 1 is rejected (exit 1)" 1 \
  "must be at most 2562047788015215" --min-age-hours 2562047788015216 0 3600 1
expect_reject "N6 SWEEP_AGE_DAYS 9999999999999999 (16 digits) is rejected by the safe max" 2 \
  "must be at most 106751991167300" SWEEP_AGE_DAYS 9999999999999999 1 86400 2
case_end

case_begin "N7-exit-code-follows-argument" "bin/lib/sweep-numeric.sh"
expect_reject "N7 the same rejection exits with the caller's code 3" 3 \
  "must not have a leading zero" X 010 1 1 3
expect_reject "N7 the same rejection exits with the caller's code 1" 1 \
  "must not have a leading zero" X 010 1 1 1
case_end

case_begin "N8-caller-bug" "bin/lib/sweep-numeric.sh"
# A malformed min, multiplier or exit_code is the caller's bug: exit 2 regardless.
for args in "X 5 abc 1 1" "X 5 1 0 1" "X 5 1 x 1" "X 5 1 1 abc" "X 5 1 1 "; do
  # shellcheck disable=SC2086
  set -- $args
  [ "$#" -eq 4 ] && set -- "$@" ""
  run_v "$@"
  if [ "$V_RC" -eq 2 ] && [ "$V_OUT" != "ACCEPTED" ]; then
    pass "N8 caller bug ($(printf '%q ' "$@")) exits 2"
  else
    fail "N8 caller bug ($(printf '%q ' "$@")) exits 2" "rc=$V_RC out=$(printf '%q' "$V_OUT") err=$(printf '%q' "$V_ERR")"
  fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
