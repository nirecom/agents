#!/usr/bin/env bash
# tests/bin/feature-3047-exceeds-budget/driver.sh
# Tests: bin/lib/run-tests-baseline-timeout.sh
# Tags: run-tests, baseline, timeout, budget, helpers, scope:issue-specific, pwsh-not-required, TL2
# Child of eb_drive: bash driver.sh <repo> <snippet>. Sources the CLI's libs in the CLI's order, sets
# the CLI's globals for <repo>, stubs the test run (every run times out and, like a concurrent
# run-all, appends a timeout row to the duration ledger) and evals <snippet>.
# Env: EB_B2 (base sha), TR_ADVANCE (seconds the first stubbed run adds to SECONDS).

set -uo pipefail
EB_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
for _lib in ledger timeout worktree exec homeref branch rename compare classify; do
  # shellcheck source=/dev/null
  . "$EB_ROOT_DIR/bin/lib/run-tests-baseline-$_lib.sh" || { echo "driver: cannot source $_lib"; exit 98; }
done
# shellcheck source=/dev/null
{ . "$EB_ROOT_DIR/bin/lib/test-language-registry.sh" && tlr_load; } || { echo "driver: registry not loaded"; exit 98; }

ROOT="$1" SID="eb-sid" RTB_EVIDENCE="/nonexistent" PTT_EXPLICIT=0 PER_TEST_TIMEOUT="" B2="${EB_B2:-}" WT="$ROOT"
export RTB_LEDGER_REPO="$ROOT"
cd "$ROOT" || exit 97
run_all_dur_repo_id "$ROOT" >/dev/null
run_all_dur_host_token >/dev/null
TMP_BASE="$(run_all_cache_dir)/baseline/tmp"
mkdir -p "$TMP_BASE"
LOGDIR="$TMP_BASE/logs-$$"
mkdir -p "$LOGDIR"
TESTS=()
declare -A BR_EXIT=()
# shellcheck disable=SC2034
declare -a CLS=() DET=() RERUN=() NEWC=() NEWH=() BR_RES=() BR_END=() BR_NOREC=() BR_DECOY=() BR_TIMEOUT=() RUN_REL=() RUN_OLD=()
EB_CALLS="$TMP_BASE/calls-$$"
: >"$EB_CALLS"

rtb_branch_input_version() { printf 'iv-3047'; }

# eb_dur <rel> <secs> <STATE> — one duration-ledger row through run-all.sh's own writer functions.
# The writer opens on first use, so a run that seeds nothing never consolidates or adds a segment.
eb_dur() {
  run_all_dur_writer_init "$ROOT"
  run_all_dur_key_into "$ROOT/$1" "$ROOT" || return 0
  run_all_dur_file_result_into "$3"
  run_all_dur_append "$RUN_ALL_DUR_KEY_OUT" "$2" "$RUN_ALL_DUR_FR_VERDICT" "$RUN_ALL_DUR_FR_TERM"
}
eb_seed() { eb_dur "$@"; }

# eb_load — the real rtb_timeout_load_ledger over TESTS, as the CLI calls it once at its start.
eb_load() {
  local i; local -a a=()
  for i in "${!TESTS[@]}"; do a+=("$i:${TESTS[$i]}"); done
  rtb_timeout_load_ledger "$ROOT" "$TMP_BASE" "${a[@]}"
}

# Every run times out (rc 124) and appends a 400 s timeout row for its test mid-call (only when this
# run opened the writer); the first one optionally consumes TR_ADVANCE seconds of the budget.
rtb_exec_one() {
  RTB_EXEC_SEQ=$(( ${RTB_EXEC_SEQ:-0} + 1 ))
  mkdir -p "$4/$RTB_EXEC_SEQ.res"
  printf '%s\t%s\n' "$2" "$3" >>"$EB_CALLS"
  if [ "${RUN_ALL_DUR_WRITE_OK:-0}" = 1 ] && run_all_dur_key_into "$ROOT/$2" "$ROOT"; then
    run_all_dur_append "$RUN_ALL_DUR_KEY_OUT" 400 - timeout
  fi
  RTB_EXEC_TIMEDOUT=1 RTB_EXEC_UNSUPPORTED=0 RTB_EXEC_DECOY=0 RTB_EXEC_UNRUNNABLE=0 RTB_EXEC_STATE="" RTB_EXEC_RC=124
  if [ -n "${TR_ADVANCE:-}" ] && [ "$RTB_EXEC_SEQ" -eq 1 ]; then SECONDS=$((SECONDS + TR_ADVANCE)); fi
  return 0
}

# eb_report — R lines per test, the loaded measurement and termination, CALLS, branch cache rows.
eb_report() {
  local i f
  for i in "${!TESTS[@]}"; do
    printf 'R%s cls=%s det=%s\n' "$i" "${CLS[i]:-}" "${DET[i]:-}"
    printf 'M%s secs=%s term=%s\n' "$i" "${RTB_TIMEOUT_LEDGER[i]:-}" "${RTB_TIMEOUT_LEDGER_TERM[i]:-}"
  done
  printf 'CALLS=%s\n' "$(grep -c . "$EB_CALLS")"
  for f in "$(rtb_branch_dir)"/branch.v2.*.seg; do
    [ -f "$f" ] && awk -F'\t' '{ print "CACHE " $4 " " $5 }' "$f"
  done
  return 0
}

eval "$2"
