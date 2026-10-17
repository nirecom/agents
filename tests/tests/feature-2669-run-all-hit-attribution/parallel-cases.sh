#!/usr/bin/env bash
# tests/tests/feature-2669-run-all-hit-attribution/parallel-cases.sh — sourced by the dispatcher.
# Tests: tests/run-all.sh
# Tags: run-all, command-guard, root-decoy, hit-attribution, parallel, scope:issue-specific, tl2
# Plan risk R5: tests running at once in parallel lanes each get their own hits and nobody else's.
# Three fixtures wait at a barrier until all three are running, then two of them reach a stub.

# ha_par_fixtures <barrier-dir> — par-guard.sh, par-decoy.sh and par-clean.sh. Each one marks
# itself up, waits up to 20 s for the other two, records whether it saw them, then acts.
ha_par_fixtures() {
  local b="$1" name act
  mkdir -p "$b" || return 1
  for name in guard decoy clean; do
    case "$name" in
      guard) act='gh --version >/dev/null 2>&1 || true' ;;
      decoy) act='grep -q "^ROOT_DECOY_MARKER=main$" "${AGENTS_MAIN_ROOT:-/nonexistent}/.env" 2>/dev/null && { node "$AGENTS_MAIN_ROOT/hooks/lib/load-env.js" >/dev/null 2>&1 || true; }' ;;
      clean) act=':' ;;
    esac
    ha_write_fixture "$HA_FX/par-$name.sh" <<FIXTURE
B='$b'
: >"\$B/$name.up"
n=0
while [ ! -e "\$B/guard.up" ] || [ ! -e "\$B/decoy.up" ] || [ ! -e "\$B/clean.up" ]; do
  n=\$((n + 1)); [ "\$n" -gt 200 ] && break
  sleep 0.1
done
[ -e "\$B/guard.up" ] && [ -e "\$B/decoy.up" ] && [ -e "\$B/clean.up" ] && : >"\$B/$name.saw-all"
$act
sleep 1
exit 0
FIXTURE
  done
}

# ha_run_all_parallel <prefix> <test...> — tests/run-all.sh with three lanes (the parallel path,
# not -j 1); sets <prefix>_OUT, <prefix>_ERR and <prefix>_RC like ha_run_all.
ha_run_all_parallel() {
  local p="$1" errf="$TMP_ROOT/$1.err" out rc
  shift
  out="$(ha_launched bash "$ROOT_N/tests/run-all.sh" -j 3 "$@" 2>"$errf")"
  rc=$?
  printf -v "${p}_OUT" '%s' "$out"
  printf -v "${p}_ERR" '%s' "$(cat "$errf" 2>/dev/null || true)"
  printf -v "${p}_RC" '%s' "$rc"
}

ha_case_parallel_hits_are_charged_to_their_own_tests() {
  local b="$TMP_ROOT/par barrier" g d c name
  ha_par_fixtures "$b" || { fail "parallel: fixture setup" "cannot write the fixtures"; return; }
  g="$HA_FX/par-guard.sh" d="$HA_FX/par-decoy.sh" c="$HA_FX/par-clean.sh"
  ha_run_all_parallel PAR "$g" "$d" "$c"
  for name in guard decoy clean; do
    expect_eq "parallel: $name was running while the other two were (barrier met)" "$([[ -e "$b/$name.saw-all" ]] && echo met)" "met"
  done
  expect_eq "parallel: the guard test is a named FAIL" "$(count_lines "$PAR_OUT" "FAIL: $g (exit 0)")" "1"
  expect_eq "parallel: the decoy test is a named FAIL" "$(count_lines "$PAR_OUT" "FAIL: $d (exit 0)")" "1"
  expect_eq "parallel: the clean test still passes" "$(count_lines "$PAR_OUT" "PASS: $c")" "1"
  expect_eq "parallel: the clean test is not a FAIL" "$(count_lines "$PAR_OUT" "FAIL: $c")" "0"
  expect_eq "parallel: no PASS line for the guard test" "$(count_lines "$PAR_OUT" "PASS: $g")" "0"
  expect_eq "parallel: no PASS line for the decoy test" "$(count_lines "$PAR_OUT" "PASS: $d")" "0"
  expect_eq "parallel: the guard detail line names the guard test only" "$(count_lines "$PAR_ERR" "[run-all] command guard hit: gh$TAB")" "1"
  expect_has "parallel: the guard detail line carries the guard test's path" "$PAR_ERR" "$TAB$g$TAB"
  expect_eq "parallel: the guard detail line does not name the decoy or clean test" \
    "$(grep -F "[run-all] command guard hit: gh$TAB" <<<"$PAR_ERR" | grep -cF -e "$d" -e "$c")" "0"
  expect_eq "parallel: the decoy detail line appears once" "$(count_lines "$PAR_ERR" "[run-all] root decoy hit: main/hooks/lib/load-env.js$TAB")" "1"
  expect_has "parallel: the decoy detail line carries the decoy test's path" \
    "$(grep -F "[run-all] root decoy hit: main/hooks/lib/load-env.js$TAB" <<<"$PAR_ERR")" "$d"
  expect_eq "parallel: the decoy detail line does not name the guard or clean test" \
    "$(grep -F "[run-all] root decoy hit: main/hooks/lib/load-env.js$TAB" <<<"$PAR_ERR" | grep -cF -e "$g" -e "$c")" "0"
  expect_eq "parallel: the contract counts two failures and one pass, with no HITS" \
    "$(last_nonempty "$PAR_OUT")" "RUN_CONTRACT: PASS=1 FAIL=2 SKIP=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0"
  expect_eq "parallel: no unattributed HIT line is printed" "$(count_lines "$PAR_OUT" "HIT:")" "0"
  expect_eq "parallel: run-all exits 1" "$PAR_RC" "1"
}
