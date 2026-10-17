#!/usr/bin/env bash
# tests/tests/feature-2669-run-all-hit-attribution/launched-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh, bin/lib/run-all-hits.sh, bin/lib/run-all-report.sh
# Tags: run-all, command-guard, root-decoy, hit-attribution, scope:issue-specific, tl2
# Cases that go through the real tests/run-all.sh: a hit with a test id is that test's FAIL, a
# hit without one is HITS, and a run without hits prints exactly what it printed before.

# ha_named_fail_checks <label> <prefix> <fixture> <detail-prefix> — the shared T2 expectations.
ha_named_fail_checks() {
  local label="$1" fx="$HA_FX/$3" ov="${2}_OUT" ev="${2}_ERR" rv="${2}_RC"
  local out="${!ov}" err="${!ev}" rc="${!rv}"
  expect_eq "$label: the test that reached the stub is a named FAIL with its own exit code" "$(count_lines "$out" "FAIL: $fx (exit 0)")" "1"
  expect_eq "$label: no PASS line is printed for it" "$(count_lines "$out" "PASS: $fx")" "0"
  expect_eq "$label: its file-level case line is a FAIL" "$(count_lines "$out" "FAIL $fx::(file) target=$fx")" "1"
  expect_eq "$label: the contract counts it as the one failure of one executed test" "$(count_lines "$out" "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0")" "1"
  expect_eq "$label: the contract carries no HITS field" "$(count_lines "$out" "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS")" "0"
  expect_eq "$label: no HIT line is printed" "$(count_lines "$out" "HIT:")" "0"
  expect_eq "$label: run-all exits 1" "$rc" "1"
  expect_eq "$label: the detail line appears once on stderr" "$(count_lines "$err" "$4")" "1"
}

ha_case_guard_hit_is_named_fail() {
  ha_run_all GUARD "$HA_FX/guard-pass.sh"
  ha_named_fail_checks "guard" GUARD guard-pass.sh "[run-all] command guard hit: gh$TAB"
  expect_has "guard: the detail line names the test" "$GUARD_ERR" "$TAB$HA_FX/guard-pass.sh$TAB"
}

ha_case_decoy_hit_is_named_fail() {
  ha_run_all DECOY "$HA_FX/decoy-pass.sh"
  ha_named_fail_checks "decoy" DECOY decoy-pass.sh "[run-all] root decoy hit: main/hooks/lib/load-env.js$TAB"
  expect_has "decoy: the detail line names the test" "$DECOY_ERR" "$HA_FX/decoy-pass.sh"
}

ha_case_hit_without_test_id_is_hits() {
  local fx="$HA_FX/noid-hit.sh" hitn contn
  ha_run_all NOID "$fx"
  expect_eq "no id: the test itself still passes" "$(count_lines "$NOID_OUT" "PASS: $fx")" "1"
  expect_eq "no id: no FAIL line is printed" "$(count_lines "$NOID_OUT" "FAIL: ")" "0"
  expect_eq "no id: the contract keeps FAIL=0 and adds HITS=1" "$(count_lines "$NOID_OUT" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1")" "1"
  expect_eq "no id: the Results line carries HITS=1" "$(count_lines "$NOID_OUT" "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0  HITS=1")" "1"
  expect_eq "no id: a column-0 HIT line names the command guard without a test id" "$(count_lines "$NOID_OUT" "HIT: command-guard (no test id) ")" "1"
  expect_eq "no id: run-all exits 1" "$NOID_RC" "1"
  hitn="$(line_no "$NOID_OUT" "HIT:")"
  contn="$(line_no "$NOID_OUT" "RUN_CONTRACT:")"
  expect_eq "no id: the HIT line comes before the contract line" "$([[ "$hitn" -gt 0 && "$hitn" -lt "$contn" ]] && echo before)" "before"
  expect_eq "no id: the contract is the last non-empty stdout line" "$(last_nonempty "$NOID_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"
}

ha_case_no_hit_run_is_unchanged() {
  local fx="$HA_FX/nohit.sh"
  ha_run_all CLEAN "$fx"
  expect_eq "no hit: run-all exits 0" "$CLEAN_RC" "0"
  expect_eq "no hit: the Results line is byte-identical to before" "$(count_lines "$CLEAN_OUT" "Results: ")" "1"
  expect_has "no hit: the Results line has no HITS field" "$CLEAN_OUT" "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0"$'\n'
  expect_eq "no hit: the contract is byte-identical to before" "$(last_nonempty "$CLEAN_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
  expect_eq "no hit: no HIT line is printed" "$(count_lines "$CLEAN_OUT" "HIT:")" "0"
  expect_eq "no hit: nothing is reported on stderr as a hit" "$(count_lines "$CLEAN_ERR" "[run-all] ")" "0"
}

ha_case_test_output_cannot_forge_a_hit() {
  local fx="$HA_FX/forge.sh"
  ha_run_all FORGE "$fx"
  expect_eq "forge: the test passes" "$(count_lines "$FORGE_OUT" "PASS: $fx")" "1"
  expect_eq "forge: the test's own HIT line is not printed at column 0" "$(count_lines "$FORGE_OUT" "HIT: command-guard forged-by-the-test")" "0"
  expect_eq "forge: the test's own HIT line is neutralized" "$(count_lines "$FORGE_OUT" "[run-all:neutralized] HIT: command-guard forged-by-the-test")" "1"
  expect_eq "forge: the contract carries no HITS field" "$(last_nonempty "$FORGE_OUT")" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
  expect_eq "forge: run-all exits 0" "$FORGE_RC" "0"
}
