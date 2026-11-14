#!/usr/bin/env bash
# tests/bin/feature-3015-baseline-timeout-record/driver.sh
# Tests: bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, timeout, helpers, scope:issue-specific, pwsh-not-required, TL2
# Child of tr_drive: bash driver.sh <repo> <snippet>. Sources the CLI's libs in the CLI's order, sets
# the CLI's globals for <repo>, stubs the test run (every run times out) and evals <snippet>.
# Env: TR_B2 (base sha), TR_ADVANCE (seconds the first stubbed run adds to SECONDS).

set -uo pipefail
TR_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
for _lib in ledger timeout worktree exec homeref branch rename compare classify; do
  # shellcheck source=/dev/null
  . "$TR_ROOT_DIR/bin/lib/run-tests-baseline-$_lib.sh" || { echo "driver: cannot source $_lib"; exit 98; }
done
# The CLI loads the registry once the merge base is known; the compare and classify libs need it.
# shellcheck source=/dev/null
{ . "$TR_ROOT_DIR/bin/lib/test-language-registry.sh" && tlr_load; } || { echo "driver: registry not loaded"; exit 98; }

ROOT="$1" SID="tr-sid" RTB_EVIDENCE="/nonexistent" PTT_EXPLICIT="${TR_PTT_EXPLICIT:-0}"
PER_TEST_TIMEOUT="${TR_PTT:-}" B2="${TR_B2:-}" WT="$ROOT"
export RTB_LEDGER_REPO="$ROOT"
cd "$ROOT" || exit 97
run_all_dur_repo_id "$ROOT" >/dev/null
run_all_dur_host_token >/dev/null
TMP_BASE="$(run_all_cache_dir)/baseline/tmp"
mkdir -p "$TMP_BASE"
LOGDIR="$TMP_BASE/logs-$$"
TESTS=()
declare -A BR_EXIT=()
# shellcheck disable=SC2034
declare -a CLS=() DET=() RERUN=() NEWC=() NEWH=() BR_RES=() BR_END=() BR_NOREC=() BR_TIMEOUT=() RUN_REL=() RUN_OLD=()
TR_CALLS="$TMP_BASE/calls-$$"
: >"$TR_CALLS"

# The input version of this checkout is fixed, so a second driver run hits the first one's rows.
rtb_branch_input_version() { printf 'iv-3015'; }
# Every run times out (rc 124); the first one optionally consumes TR_ADVANCE seconds of the budget.
rtb_exec_one() {
  RTB_EXEC_SEQ=$(( ${RTB_EXEC_SEQ:-0} + 1 ))
  mkdir -p "$4/$RTB_EXEC_SEQ.res"
  printf '%s\t%s\n' "$2" "$3" >>"$TR_CALLS"
  RTB_EXEC_TIMEDOUT=1 RTB_EXEC_UNSUPPORTED=0 RTB_EXEC_DECOY=0 RTB_EXEC_UNRUNNABLE=0 RTB_EXEC_STATE="" RTB_EXEC_RC=124
  if [ -n "${TR_ADVANCE:-}" ] && [ "$RTB_EXEC_SEQ" -eq 1 ]; then SECONDS=$((SECONDS + TR_ADVANCE)); fi
  return 0
}

# tr_seed_branch <rel> <result> [<epoch>] — a raw branch cache row (cache_put rejects odd results).
tr_seed_branch() {
  local d; d="$(rtb_branch_dir)"; mkdir -p "$d"
  printf 'b2\tiv-3015\t%s\t%s\t%s\t-\t%s\n' "$RUN_ALL_DUR_HOST_TOKEN" "$1" "$2" "${3:-1000}" >>"$d/branch.v2.seed-1000-1.seg"
}

# tr_seed_ledger <sha> <rel> <result> <epoch> — a raw v3 ledger row with an explicit epoch.
tr_seed_ledger() {
  local d; d="$(rtb_ledger_dir)"; mkdir -p "$d"
  [ -n "${RUN_ALL_DUR_OS_ATTR:-}" ] || RUN_ALL_DUR_OS_ATTR="$(run_all_os_attr)"
  printf 'v3\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$RUN_ALL_DUR_HOST_TOKEN" "$2" "$3" "$4" "$RUN_ALL_DUR_OS_ATTR" \
    >>"$d/v3.$RUN_ALL_DUR_HOST_TOKEN-1000-1.seg"
}

# tr_report — R lines per test, then CALLS, the branch cache rows and the ledger rows.
tr_report() {
  local i f
  for i in "${!TESTS[@]}"; do
    printf 'R%s cls=%s det=%s brt=%s end=%s\n' "$i" "${CLS[i]:-}" "${DET[i]:-}" "${BR_TIMEOUT[i]:-}" "${BR_END[i]:-}"
  done
  printf 'RERUN=%s\n' "${RERUN[*]:-}"
  printf 'CALLS=%s\n' "$(grep -c . "$TR_CALLS")"
  for f in "$(rtb_branch_dir)"/branch.v2.*.seg; do
    [ -f "$f" ] && awk -F'\t' '{ print "CACHE " $4 " " $5 " " $6 }' "$f"
  done
  for f in "$(rtb_ledger_dir)"/v3.*.seg; do
    [ -f "$f" ] && awk -F'\t' '{ print "LEDGER " $4 " " $5 }' "$f"
  done
  return 0
}

eval "$2"
