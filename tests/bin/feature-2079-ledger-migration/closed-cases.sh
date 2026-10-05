# shellcheck shell=bash
# tests/bin/feature-2079-ledger-migration/closed-cases.sh
# Tests: bin/lib/run-all-durations.sh
# Tags: tests, bin, ledger, durations, consolidate, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher header, tests/bin/feature-2079-ledger-migration.sh.
# n21 (#2079 S7b): the closed marker. (1)-(5), (7) through a real runner (_runner-closed.sh),
# (6) through direct calls: a second close is a no-op and an append after close writes nothing.

# ---- child side ---------------------------------------------------------------

c21_close_twice() {
  local seg closed
  run_all_dur_writer_init "$LM_REPO"
  run_all_dur_append "a.sh" 3
  seg="$RUN_ALL_DUR_SEGMENT"
  if ! command -v run_all_dur_close >/dev/null 2>&1; then say have no; return 0; fi
  say have yes
  run_all_dur_close
  closed="${seg%.log}.closed.log"
  say open_gone "$([ -e "$seg" ] && echo 0 || echo 1)"
  say closed_made "$([ -f "$closed" ] && echo 1 || echo 0)"
  say write_ok "${RUN_ALL_DUR_WRITE_OK:-unset}"
  local before; before="$(lm_ls)|$(lm_sum "$closed")"
  run_all_dur_close; say second_rc "$?"
  run_all_dur_append "b.sh" 4
  say after_same "$([ "$before" = "$(lm_ls)|$(lm_sum "$closed")" ] && echo 1 || echo 0)"
  say vals "$(lm_get a.sh b.sh)"
}

# ---- parent side --------------------------------------------------------------

# c21_runner_load — fills C21_OUT with the real-runner helper's `R21` values, once per
# dispatcher process; call it bare (never in `$(...)`) so the memo survives.
C21_OUT=""
c21_runner_load() {
  [ -n "$C21_OUT" ] || C21_OUT="$(run_with_timeout 280 env -u RUN_ALL_DUR_REPO_ID -u RUN_ALL_DUR_HOST_TOKEN \
    AGENTS_DIR="$AGENTS_DIR" bash "$LM_PARTS/_runner-closed.sh" 2>/dev/null | sed -n 's/^R21 //p')"
}

run_closed_runner_cases() {
  local r
  c21_runner_load; r="$C21_OUT"
  # Counts are open:closed:consolidating:base.
  ck "n21/1/normal-exit-closed" "0|0:1:0:0" "$(lm_v "$r" normal_rc)|$(lm_v "$r" normal_states)"
  ck "n21/5/next-start-folds-closed-into-base" "0:1:0:1|1" "$(lm_v "$r" second_states)|$(lm_v "$r" first_closed_gone)"
  ck "n21/2/deadline-exit-closed" "3|0:1:0:0" "$(lm_v "$r" deadline_rc)|$(lm_v "$r" deadline_states)"
  if [ "$(lm_v "$r" int_measured)" -ge 1 ] 2>/dev/null; then
    pass "n21/3/fixture-measured-before-int"
  else
    fail "n21/3/fixture-measured-before-int" "int_measured=[$(lm_v "$r" int_measured)]"
  fi
  ck "n21/3/int-closed" "130|0:1:0:0" "$(lm_v "$r" int_rc)|$(lm_v "$r" int_states)"
  ck "n21/4/print-plan-and-empty-run-no-ledger" "0:0" "$(lm_v "$r" plan_files):$(lm_v "$r" empty_files)"
}

run_closed_fail_cases() {
  local r recs secs
  c21_runner_load; r="$C21_OUT"
  ck "n21/7/failing-test-run-exits-1-and-closed" "1|0:1:0:0" "$(lm_v "$r" fail_rc)|$(lm_v "$r" fail_states)"
  recs="$(lm_v "$r" fail_records)"
  ck "n21/7/failing-and-passing-durations-recorded" "bad.sh q1.sh" "$(printf '%s\n' $recs | sed 's/=.*//' | tr '\n' ' ' | sed 's/ $//')"
  secs="$(printf '%s\n' $recs | sed -n 's/^bad\.sh=//p')"
  if [ "$secs" -ge 1 ] 2>/dev/null; then pass "n21/7/failing-test-duration-harvested"
  else fail "n21/7/failing-test-duration-harvested" "records=[$recs]"; fi
}

run_closed_direct_cases() {
  local c r
  lm_win; c="$(lm_cache)"
  r="$(lm_run "$c" c21_close_twice)"
  ck "n21/6/close-function-defined" "yes" "$(lm_v "$r" have)"
  ck "n21/6/close-renames-and-stops-writing" "1:1:0" "$(lm_v "$r" open_gone):$(lm_v "$r" closed_made):$(lm_v "$r" write_ok)"
  ck "n21/6/second-close-no-op" "0:1" "$(lm_v "$r" second_rc):$(lm_v "$r" after_same)"
  ck "n21/6/closed-record-readable-late-append-dropped" "3 -" "$(lm_v "$r" vals)"
}
