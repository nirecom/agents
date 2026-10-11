# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/derive-timeout.sh
# Tests: bin/lib/run-tests-baseline-timeout.sh
# Tags: run-tests, baseline, timeout, ledger, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# #2547: the per-test timeout is derived from the duration ledger, and every timeout (derived or
# explicit) is clamped by one budget. Unit group here (lib functions through dt_eval, plus the static
# SSOT checks); the CLI group lives in derive-timeout-cli.sh.

# isolation (#2512): re-pin to helpers.sh's private dirs (a sibling's pin is invisible to the scanner).
: "${WF_DIR:?helpers.sh must be sourced first}" "${PLANS_DIR:?helpers.sh must be sourced first}"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")" WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
declare -F harness_assert_isolated >/dev/null || . "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_assert_isolated

# dt_eval <script> [VAR=val] — run <script> in a child bash that has loaded the timeout lib and its
# ledger dependencies; sets DT_OUT (stdout+stderr) and DT_RC (98 = a lib or dependency is missing).
# The optional VAR=val reaches the child only.
dt_eval() {
  local script="$1" envv="${2:-DT_UNUSED=1}"
  DT_RC=0
  DT_OUT="$(run_with_timeout 30 env "$envv" bash -c '. "$1" || exit 98; type run_all_dur_lookup run_all_dur_key_into >/dev/null 2>&1 || exit 98; eval "$2"' dt_eval "$TIMEOUT_LIB" "$script" 2>&1)" || DT_RC=$?
}

# dt_expect <label> <want> <script> [VAR=val] — the child's whole output must equal <want>.
dt_expect() {
  dt_eval "$3" "${4:-DT_UNUSED=1}"
  if [ "$DT_RC" -eq 0 ] && [ "$DT_OUT" = "$2" ]; then
    pass "$1: $2"
  else
    fail "$1: want '$2', got '$DT_OUT' (rc=$DT_RC)"
  fi
}

# dt_seed_dur <cache> <root> <rel> <secs> — a finished ledger record, written through the ledger lib
# (the same writer a run-all uses), into the fixture cache only.
dt_seed_dur() {
  run_with_timeout 30 env RUN_ALL_CACHE_DIR="$1" bash -c '. "$1" || exit 98; run_all_dur_key_into "$2/$3" "$2" || exit 97; run_all_dur_writer_init "$2"; run_all_dur_append "$RUN_ALL_DUR_KEY_OUT" "$4"; run_all_dur_close' dt_seed "$LEDGER_LIB" "$2" "$3" "$4" >/dev/null 2>&1
}

# dt_expect_range <label> <min> <max> <script> [VAR=val] — the child's output is an integer in [min, max].
dt_expect_range() {
  dt_eval "$4" "${5:-DT_UNUSED=1}"
  if [ "$DT_RC" -eq 0 ] && [[ "$DT_OUT" =~ ^[0-9]+$ ]] && [ "$DT_OUT" -ge "$2" ] && [ "$DT_OUT" -le "$3" ]; then
    pass "$1: $DT_OUT within [$2, $3]"
  else
    fail "$1: want an integer in [$2, $3], got '$DT_OUT' (rc=$DT_RC)"
  fi
}

dt_expect_derive() { dt_expect "$1" "$2" "rtb_timeout_derive_into '$3'; printf '%s' \"\$RTB_TIMEOUT_DERIVED_OUT\""; }

# dt_expect_slice <label> <want> <wanted-or-secs> <elapsed> <fn> [VAR=val]
dt_expect_slice() {
  dt_expect "$1" "$2" "$5 '$3' $4; printf '%s' \"\$RTB_TIMEOUT_SLICE_OUT\"" "${6:-DT_UNUSED=1}"
}

dt_static_cases() {
  local cli_exec_hits n
  if [ ! -f "$TIMEOUT_LIB" ]; then
    fail "H0: bin/lib/run-tests-baseline-timeout.sh not found (impl pending)"
    return
  fi
  # (h) the default 300 has one owner: the timeout lib.
  n="$(grep -cE 'RTB_TIMEOUT_DEFAULT=300' "$TIMEOUT_LIB")"
  [ "$n" = 1 ] && pass "H1: RTB_TIMEOUT_DEFAULT=300 defined exactly once in the timeout lib" \
    || fail "H1: expected exactly one RTB_TIMEOUT_DEFAULT=300 definition, found $n"
  cli_exec_hits="$(grep -nE '(:-|=)300([^0-9]|$)' "$BASELINE_CLI" "$EXEC_LIB")"
  [ -z "$cli_exec_hits" ] && pass "H2: no numeric 300 default left in bin/run-tests-baseline or run-tests-baseline-exec.sh" \
    || fail "H2: duplicated 300 default remains: $cli_exec_hits"
  grep -qF 'RTB_TIMEOUT_DEFAULT' "$EXEC_LIB" \
    && pass "H3: run-tests-baseline-exec.sh refers to RTB_TIMEOUT_DEFAULT" \
    || fail "H3: run-tests-baseline-exec.sh does not refer to RTB_TIMEOUT_DEFAULT"
  # (h') the dependency order stays owned by the ledger lib.
  if grep -qE '^[[:space:]]*(\.|source)[[:space:]].*run-all-durations\.sh' "$TIMEOUT_LIB"; then
    fail "H4: the timeout lib sources run-all-durations.sh directly (order owner must be the ledger lib)"
  else
    pass "H4: the timeout lib does not source run-all-durations.sh directly"
  fi
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*run-tests-baseline-ledger\.sh' "$TIMEOUT_LIB" \
    && pass "H5: the timeout lib sources run-tests-baseline-ledger.sh" \
    || fail "H5: the timeout lib does not source run-tests-baseline-ledger.sh"
}

run_timeout_unit_cases() {
  local repo="$TMPROOT/repo-dt-unit" cache="$TMPROOT/cache-dt-unit" empty="$TMPROOT/cache-dt-empty"
  local wd="$TMPROOT/dt-unit-wd" t="tests/bin/test-sleep.sh" last

  [ -f "$TIMEOUT_LIB" ] && pass "A0: bin/lib/run-tests-baseline-timeout.sh exists" \
    || fail "A0: bin/lib/run-tests-baseline-timeout.sh not found (impl pending)"

  # constants (SSOT values)
  dt_expect "K1: DEFAULT MARGIN CAP CEIL SAFETY KILL_GRACE MIN_SLICE" "300 2 540 600 45 2 30" \
    'printf "%s %s %s %s %s %s %s" "$RTB_TIMEOUT_DEFAULT" "$RTB_TIMEOUT_MARGIN_FACTOR" "$RTB_TIMEOUT_CAP" "$RTB_BUDGET_CEIL" "$RTB_BUDGET_SAFETY" "$RTB_BUDGET_KILL_GRACE" "$RTB_BUDGET_MIN_SLICE"'

  # (a) a long measured run lifts the timeout above the old 300
  dt_expect_derive "A1: 200s measured" 400 200
  dt_expect_derive "A2: 350s measured (feature-2099)" 540 350
  dt_expect_derive "A3: 271s measured" 540 271

  # (b) unmeasured falls back to 300
  dt_expect_derive "B1: empty" 300 ""
  dt_expect_derive "B2: non-numeric" 300 abc

  # (c) lower bound, upper bound, and the boundaries between
  dt_expect_derive "C1: 0s" 300 0
  dt_expect_derive "C2: 5s" 300 5
  dt_expect_derive "C3: 150s (150*2 = lower bound)" 300 150
  dt_expect_derive "C4: 151s (first value above the floor)" 302 151
  dt_expect_derive "C5: 269s (just below the cap)" 538 269
  dt_expect_derive "C6: 270s (270*2 = cap)" 540 270
  dt_expect_derive "C7: 9999s" 540 9999
  dt_expect_derive "C8: leading zero is decimal, not octal" 400 0200
  dt_expect_derive "C10: negative is not a duration -> 300" 300 -5
  dt_expect_range "C11: 20-digit value stays a sane timeout" 300 540 \
    "rtb_timeout_derive_into '99999999999999999999'; printf '%s' \"\$RTB_TIMEOUT_DERIVED_OUT\""
  dt_eval 'printf "%s" "$RTB_TIMEOUT_CAP"'
  if [ "$DT_RC" -eq 0 ] && [ "$DT_OUT" -lt 600 ] 2>/dev/null; then
    pass "C9: RTB_TIMEOUT_CAP ($DT_OUT) stays below the 600s Bash limit"
  else
    fail "C9: RTB_TIMEOUT_CAP must be a number below 600 (got '$DT_OUT', rc=$DT_RC)"
  fi

  # (a') the ledger path: a seeded 350s record is read back and derives 540
  mkdir -p "$cache" "$empty" "$wd"
  mk_fixture_repo "$repo" >/dev/null
  dt_seed_dur "$cache" "$repo" "$t" 350 || fail "A4: could not seed the duration ledger"
  dt_expect "A4: seeded 350s read via rtb_timeout_load_ledger, derived" "350|unset|540" \
    "rtb_timeout_load_ledger '$repo' '$wd' 0:$t 1:tests/bin/test-skip.sh; rtb_timeout_derive_into \"\${RTB_TIMEOUT_LEDGER[0]:-}\"; printf '%s|%s|%s' \"\${RTB_TIMEOUT_LEDGER[0]:-unset}\" \"\${RTB_TIMEOUT_LEDGER[1]:-unset}\" \"\$RTB_TIMEOUT_DERIVED_OUT\"" \
    "RUN_ALL_CACHE_DIR=$cache"
  # (b) an empty or missing ledger leaves the entry unset and the derivation at 300
  dt_expect "B3: empty ledger -> entry unset, derived 300" "unset|300" \
    "rtb_timeout_load_ledger '$repo' '$wd' 0:$t; rtb_timeout_derive_into \"\${RTB_TIMEOUT_LEDGER[0]:-}\"; printf '%s|%s' \"\${RTB_TIMEOUT_LEDGER[0]:-unset}\" \"\$RTB_TIMEOUT_DERIVED_OUT\"" \
    "RUN_ALL_CACHE_DIR=$empty"
  dt_expect "B4: ledger directory absent -> entry unset" "unset" \
    "rtb_timeout_load_ledger '$repo' '$wd' 0:$t; printf '%s' \"\${RTB_TIMEOUT_LEDGER[0]:-unset}\"" \
    "RUN_ALL_CACHE_DIR=$TMPROOT/cache-dt-never-created"

  # (e) the budget clamp, derived path
  dt_expect_slice "E1: derived 350s at elapsed 0" 540 350 0 rtb_timeout_slice_into
  dt_expect_slice "E2: derived 350s at elapsed 300 (555-300-2)" 253 350 300 rtb_timeout_slice_into
  dt_expect_slice "E3: derived 350s at elapsed 540 (13s left < 30)" 0 350 540 rtb_timeout_slice_into
  dt_expect_slice "E4: derived 350s at elapsed 555" 0 350 555 rtb_timeout_slice_into
  dt_expect_slice "E5: unmeasured at elapsed 0 keeps 300" 300 "" 0 rtb_timeout_slice_into
  # (e) the budget clamp, explicit values (C1 of the plan: the clamp is not waived for them)
  dt_expect_slice "E6: wanted 590 at elapsed 0 is cut to 553" 553 590 0 rtb_timeout_budget_into
  dt_expect_slice "E7: wanted 590 at elapsed 300" 253 590 300 rtb_timeout_budget_into
  dt_expect_slice "E8: wanted 590 at elapsed 540" 0 590 540 rtb_timeout_budget_into
  dt_expect_slice "E9: wanted 10 at elapsed 300 stays 10" 10 10 300 rtb_timeout_budget_into
  dt_expect_slice "E10: non-numeric elapsed counts as 0" 553 590 abc rtb_timeout_budget_into
  dt_eval 'e=0; sum=0; out=""; for n in 1 2 3; do rtb_timeout_budget_into 590 "$e"; s="$RTB_TIMEOUT_SLICE_OUT"; out="$out$s "; sum=$((sum + s)); e=$((e + s)); done; printf "%s%s" "$out" "$sum"'
  last="${DT_OUT##* }"
  if [ "$DT_RC" -eq 0 ] && [ "$DT_OUT" = "553 0 0 553" ] && [ "$last" -le 555 ] 2>/dev/null; then
    pass "E11: three wanted-590 tests share one budget (553 0 0, total $last <= 555)"
  else
    fail "E11: expected '553 0 0 553' within 555 total, got '$DT_OUT' (rc=$DT_RC)"
  fi
  dt_expect_slice "E16: negative elapsed counts as 0" 553 590 -5 rtb_timeout_budget_into
  dt_expect_slice "E17: 20-digit elapsed exhausts the budget" 0 590 99999999999999999999 rtb_timeout_budget_into
  dt_expect_range "E18: 20-digit wanted is cut to the remaining time" 0 553 \
    "rtb_timeout_budget_into '99999999999999999999' 0; printf '%s' \"\$RTB_TIMEOUT_SLICE_OUT\""
  dt_expect_slice "E19: TOTAL=-5 falls back to 600" 553 590 0 rtb_timeout_budget_into "RTB_BUDGET_TOTAL=-5"
  dt_expect_slice "E20: 20-digit TOTAL is cut to 600" 553 590 0 rtb_timeout_budget_into "RTB_BUDGET_TOTAL=99999999999999999999"
  # (e) the RTB_BUDGET_TOTAL override can only narrow the budget
  dt_expect_slice "E12: TOTAL=abc falls back to 600" 540 540 0 rtb_timeout_budget_into "RTB_BUDGET_TOTAL=abc"
  dt_expect_slice "E13: TOTAL=9999 is cut to 600" 553 590 0 rtb_timeout_budget_into "RTB_BUDGET_TOTAL=9999"
  dt_expect_slice "E14: TOTAL=700 is cut to 600" 553 590 0 rtb_timeout_budget_into "RTB_BUDGET_TOTAL=700"
  dt_expect_slice "E15: TOTAL=50 leaves 3s < 30: budget exhausted" 0 540 0 rtb_timeout_budget_into "RTB_BUDGET_TOTAL=50"

  dt_static_cases
}
