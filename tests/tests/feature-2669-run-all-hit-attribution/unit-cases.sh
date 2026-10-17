#!/usr/bin/env bash
# tests/tests/feature-2669-run-all-hit-attribution/unit-cases.sh — sourced by the dispatcher.
# Tests: bin/lib/run-all-hits.sh, bin/lib/run-all-report.sh, bin/lib/run-all-launch.sh
# Tags: run-all, command-guard, root-decoy, hit-attribution, scope:issue-specific, tl2
# Cases on the unit driver (setup.sh): the claim right after a test, and the records that come
# in after the test was reported, for every state a unit can end in.

UNSET_UD() { unset UD_LATE UD_LATE_TWICE UD_NOID UD_DUP; }

ha_case_claim_handles_the_records() {
  local g="PASS-0-guard-a.sh" d="PASS-0-decoy-b.sh"
  UNSET_UD
  ha_unit CLAIM "$g" "$d"
  expect_eq "claim: the guard hit turns the passing unit into FAIL, rc kept, one hit" "$(count_exact "$CLAIM_OUT" "UD:EXEC:$g=FAIL|0|1")" "1"
  expect_eq "claim: the decoy hit turns the passing unit into FAIL, rc kept, one hit" "$(count_exact "$CLAIM_OUT" "UD:EXEC:$d=FAIL|0|1")" "1"
  expect_eq "claim: the guard detail line is appended to that test's stderr file" "$(count_lines "$CLAIM_OUT" "UDERR:$g:[run-all] command guard hit: gh$TAB")" "1"
  expect_eq "claim: the decoy detail line is appended to that test's stderr file" "$(count_lines "$CLAIM_OUT" "UDERR:$d:[run-all] root decoy hit: main/hooks/lib/load-env.js$TAB")" "1"
  expect_eq "claim: the guard record is renamed to .hit.claimed" "$(count_exact "$CLAIM_OUT" "UDREC:guard:claim-$g.hit.claimed")" "1"
  expect_eq "claim: no unclaimed guard record is left" "$(count_exact "$CLAIM_OUT" "UDREC:guard:claim-$g.hit")" "0"
  expect_eq "claim: the decoy record is removed" "$(count_lines "$CLAIM_OUT" "UDREC:decoy:claim-$d")" "0"
  expect_eq "claim: each unit is one named FAIL line" "$(count_exact "$CLAIM_OUT" "FAIL: $CLAIM_DIR/$g (exit 0)")|$(count_exact "$CLAIM_OUT" "FAIL: $CLAIM_DIR/$d (exit 0)")" "1|1"
  expect_eq "claim: no PASS line is printed" "$(count_lines "$CLAIM_OUT" "PASS: ")" "0"
  expect_eq "claim: the contract counts two failures (a claimed record is not counted again) and no hits" "$(count_exact "$CLAIM_OUT" "RUN_CONTRACT: PASS=0 FAIL=2 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0")" "1"
  expect_eq "claim: nothing is reported again on the run's stderr" "$(count_lines "$CLAIM_ERR" "[run-all] command guard hit:")|$(count_lines "$CLAIM_ERR" "[run-all] root decoy hit:")" "0|0"
  expect_eq "claim: no HIT line is printed" "$(count_lines "$CLAIM_OUT" "HIT:")" "0"
}

# ha_one_fail_checks <label> <prefix> <unit> <rc> — the unit is the run's one named FAIL.
ha_one_fail_checks() {
  local ov="${2}_OUT" dv="${2}_DIR"
  local out="${!ov}" dir="${!dv}"
  expect_eq "$1: one named FAIL line with the unit's own exit code" "$(count_exact "$out" "FAIL: $dir/$3 (exit $4)")" "1"
  expect_eq "$1: no other FAIL line" "$(count_lines "$out" "FAIL: ")" "1"
  expect_eq "$1: the contract has one failure of one executed test and nothing unrunnable" "$(count_exact "$out" "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0")" "1"
  expect_eq "$1: no HIT line is printed" "$(count_lines "$out" "HIT:")" "0"
}

ha_case_unrunnable_and_unsupported_claims() {
  UNSET_UD
  ha_unit UCLAIM "UNRUNNABLE-79-guard-c.sh"
  ha_one_fail_checks "unrunnable claim" UCLAIM "UNRUNNABLE-79-guard-c.sh" 79
  expect_eq "unrunnable claim: no UNRUNNABLE line for the unit" "$(count_lines "$UCLAIM_OUT" "UNRUNNABLE: ")" "0"
  ha_unit SCLAIM "UNSUPPORTED-78-guard-d.sh"
  ha_one_fail_checks "unsupported claim" SCLAIM "UNSUPPORTED-78-guard-d.sh" 78
}

ha_case_unrunnable_and_unsupported_late() {
  UNSET_UD
  UD_LATE="UNRUNNABLE-79-none-e.sh" ha_unit ULATE "UNRUNNABLE-79-none-e.sh"
  ha_one_fail_checks "unrunnable late" ULATE "UNRUNNABLE-79-none-e.sh" 79
  expect_eq "unrunnable late: no Missing runtimes line once the unit is a FAIL" "$(count_lines "$ULATE_OUT" "Missing runtimes:")" "0"
  UD_LATE="UNSUPPORTED-78-none-f.sh" ha_unit SLATE "UNSUPPORTED-78-none-f.sh"
  ha_one_fail_checks "unsupported late" SLATE "UNSUPPORTED-78-none-f.sh" 78
}

# ha_timeout_checks <label> <prefix> <unit> — the TIMEOUT unit stays the one FAIL it already was.
ha_timeout_checks() {
  local ov="${2}_OUT" dv="${2}_DIR"
  local out="${!ov}" dir="${!dv}"
  expect_eq "$1: one named FAIL line with the timeout's exit code" "$(count_exact "$out" "FAIL: $dir/$3 (exit 124)")" "1"
  expect_eq "$1: no other FAIL line" "$(count_lines "$out" "FAIL: ")" "1"
  expect_eq "$1: the TIMEOUT line is kept" "$(count_lines "$out" "TIMEOUT: $dir/$3")" "1"
  expect_eq "$1: the contract counts the timeout once, not again for the hit" "$(count_exact "$out" "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=1")" "1"
  expect_eq "$1: no HIT line is printed" "$(count_lines "$out" "HIT:")" "0"
}

ha_case_skip_and_timeout_claims() {
  local k="SKIP-77-guard-l.sh" t="TIMEOUT-124-guard-m.sh"
  UNSET_UD
  ha_unit KCLAIM "$k"
  expect_eq "skip claim: the guard hit turns the skipped unit into FAIL, rc kept, one hit" "$(count_exact "$KCLAIM_OUT" "UD:EXEC:$k=FAIL|77|1")" "1"
  ha_one_fail_checks "skip claim" KCLAIM "$k" 77
  expect_eq "skip claim: no SKIP line for the unit" "$(count_lines "$KCLAIM_OUT" "SKIP: ")" "0"
  ha_unit TCLAIM "$t"
  expect_eq "timeout claim: the state stays TIMEOUT, with one hit claimed" "$(count_exact "$TCLAIM_OUT" "UD:EXEC:$t=TIMEOUT|124|1")" "1"
  expect_eq "timeout claim: the guard detail line is appended to that test's stderr file" "$(count_lines "$TCLAIM_OUT" "UDERR:$t:[run-all] command guard hit: gh$TAB")" "1"
  ha_timeout_checks "timeout claim" TCLAIM "$t"
}

ha_case_skip_and_timeout_late() {
  local k="SKIP-77-none-n.sh" t="TIMEOUT-124-none-o.sh"
  UNSET_UD
  UD_LATE="$k" ha_unit KLATE "$k"
  ha_one_fail_checks "skip late" KLATE "$k" 77
  UD_LATE="$t" ha_unit TLATE "$t"
  ha_timeout_checks "timeout late" TLATE "$t"
  expect_eq "timeout late: the detail line is still printed on stderr" "$(count_lines "$TLATE_ERR" "[run-all] command guard hit: gh$TAB")" "1"
}

ha_case_late_record_on_a_pass() {
  local u="PASS-0-none-g.sh" passn failn
  UNSET_UD
  UD_LATE="$u" ha_unit LATE "$u"
  ha_one_fail_checks "late on pass" LATE "$u" 0
  passn="$(line_no "$LATE_OUT" "PASS: $LATE_DIR/$u")"
  failn="$(line_no "$LATE_OUT" "FAIL: $LATE_DIR/$u (exit 0)")"
  expect_eq "late on pass: the FAIL line follows the PASS line already printed" "$([[ "$passn" -gt 0 && "$failn" -gt "$passn" ]] && echo after)" "after"
  expect_eq "late on pass: the detail line is printed on stderr" "$(count_lines "$LATE_ERR" "[run-all] command guard hit: gh$TAB")" "1"
  expect_eq "late on pass: the late record is renamed to .hit.claimed" "$(count_exact "$LATE_OUT" "UDPOST:guard:late-1-$u.hit.claimed")" "1"
}

ha_case_late_record_on_a_fail() {
  local u="FAIL-1-none-h.sh"
  UNSET_UD
  UD_LATE="$u" ha_unit LFAIL "$u"
  ha_one_fail_checks "late on fail" LFAIL "$u" 1
}

ha_case_two_late_records_one_fail() {
  local u="PASS-0-none-i.sh"
  UNSET_UD
  UD_LATE="$u" UD_LATE_TWICE=1 ha_unit LTWO "$u"
  ha_one_fail_checks "two late records" LTWO "$u" 0
}

ha_case_duplicate_late_id_applied_once() {
  local u="PASS-0-none-j.sh"
  UNSET_UD
  UD_LATE="$u" UD_DUP="$u" ha_unit LDUP "$u"
  expect_eq "duplicate id: the collect step is available" "$(count_exact "$LDUP_OUT" "UD:NO-COLLECT")" "0"
  ha_one_fail_checks "duplicate id" LDUP "$u" 0
}

ha_case_late_record_without_id_is_hits() {
  local u="PASS-0-none-k.sh"
  UNSET_UD
  UD_NOID=1 ha_unit LNOID "$u"
  expect_eq "late no id: the unit stays a PASS" "$(count_lines "$LNOID_OUT" "FAIL: ")" "0"
  expect_eq "late no id: one HIT line without a test id" "$(count_lines "$LNOID_OUT" "HIT: command-guard (no test id) ")" "1"
  expect_eq "late no id: the contract adds HITS=1" "$(count_exact "$LNOID_OUT" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1")" "1"
}
