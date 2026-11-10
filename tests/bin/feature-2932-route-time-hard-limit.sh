#!/usr/bin/env bash
# tests/bin/feature-2932-route-time-hard-limit.sh
# Tests: bin/find-tests-for-source.sh, bin/lib/test-route-destination.sh, bin/lib/test-route-destination/time.sh
# Tags: TL2, bin, test-route, durations, heavy-judge, scope:issue-specific
# Issue #2932: under --with-time an append candidate whose own duration ledger says HARD is
# excluded like an over-size one; when time alone empties the viable set the row says
# `time-hard-limit`. WARN only advises. No ledger means the rows of today.
# TL3 gap: a ledger grown by real run-all runs on this host (mitigation: the fixture segment
# is written through the same repo-id / host-token functions the writer uses).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPBASE/transcripts"
LEDGER_CACHE="$TMPBASE/cache-ledger"
EMPTY_CACHE="$TMPBASE/cache-empty"
export RUN_ALL_CACHE_DIR="$LEDGER_CACHE"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR" "$LEDGER_CACHE" "$EMPTY_CACHE"
unset CLAUDE_CODE_SESSION_ID GIT_DIR GIT_WORK_TREE TEST_LANES_HELD TEST_LANES FIND_TESTS_CORPUS_CACHE \
  TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP \
  TEST_MAX_JOBS_PER_HOST RUN_ALL_LANES_LIB

HELPER="$SCRIPT_CHECKOUT_ROOT/bin/find-tests-for-source.sh"
TIME_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-route-destination/time.sh"
# shellcheck source=../../bin/lib/test-dup-group.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/test-dup-group.sh"
# shellcheck source=../../bin/lib/run-all-parallelism.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-parallelism.sh"
# shellcheck source=../../bin/lib/run-all-durations.sh
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-durations.sh"

NEUTRAL_CWD="$TMPBASE/neutral"
REPO="$TMPBASE/repo"
EMPTY_PATH_DIR="$TMPBASE/empty-path"
mkdir -p "$NEUTRAL_CWD" "$EMPTY_PATH_DIR"
harness_git_init "$REPO"
mkdir -p "$REPO/tests/bin" "$REPO/src"
T="tests/bin"
HARD_MAX=100

# mk <name-under-tests/bin> <tests-csv> [<filler lines>] — a bash test file.
mk() {
  local i
  printf '#!/usr/bin/env bash\n# Tests: %s\n# Tags: scope:common\necho fixture\n' "$2" > "$REPO/$T/$1"
  for ((i = 0; i < ${3:-0}; i++)); do printf 'echo %s\n' "$i" >> "$REPO/$T/$1"; done
}
for _f in src/th.sh src/mx.sh src/tw.sh src/tq.sh src/tn.sh src/mix.sh; do printf 'fixture\n' > "$REPO/$_f"; done
mk mixh.sh "src/mix.sh"
mk mixq.sh "src/mix.sh"
mk th.sh "src/th.sh"
mk mx-size.sh "src/mx.sh" 120
mk mx-time.sh "src/mx.sh"
mk tw.sh "src/tw.sh"
mk tq.sh "src/tq.sh"
mk tn.sh "src/tn.sh"

# The ledger: one segment of this host, every row PASS|completed. Medians 200/200/100/40, so
# the suite median is 150 and no relative criterion fires; tn.sh has no series at all.
LEDGER_RID="$(run_all_dur_repo_id "$REPO")"
LEDGER_TOK="$(run_all_dur_host_token)"
DUR_DIR="$LEDGER_CACHE/$RUN_ALL_DUR_DIRNAME"
mkdir -p "$DUR_DIR"
SEG="$DUR_DIR/dur.$RUN_ALL_DUR_SCHEMA.$LEDGER_TOK.20261101T000000-1.log"
printf '#os %s\n' "${RUN_ALL_DUR_OS_ATTR:-$(run_all_os_attr)}" > "$SEG"
for _row in "th.sh:200" "mx-time.sh:200" "tw.sh:100" "tq.sh:40" "mixh.sh:200" "mixq.sh:40"; do
  for _n in 1 2 3; do
    printf '%s|%s|PASS|completed|%s\n' "$LEDGER_RID" "${_row##*:}" "$T/${_row%%:*}" >> "$SEG"
  done
done

Q_TH="src/th.sh"; Q_MX="src/mx.sh"; Q_TW="src/tw.sh"
QUERIES=("$Q_TH" "$Q_MX" "$Q_TW")

# run_h <cache-dir> <with-time 0|1> <query>... — one helper run. Sets H_RC H_OUT H_ERR.
run_h() {
  local cache="$1" with="$2" q
  shift 2
  local -a args=(--root "$REPO" --hard-max "$HARD_MAX")
  for q in "$@"; do args+=(--sources "$q"); done
  [ "$with" = 1 ] && args+=(--with-time)
  H_RC=0
  (
    cd "$NEUTRAL_CWD" || exit 99
    export RUN_ALL_CACHE_DIR="$cache"
    bash "$RWT" 100 bash "$HELPER" "${args[@]}"
  ) >"$TMPBASE/h.out" 2>"$TMPBASE/h.err" || H_RC=$?
  H_OUT="$(cat "$TMPBASE/h.out")"
  H_ERR="$(cat "$TMPBASE/h.err")"
}

row() { printf '%s\n' "$1" | sed -n "$(($2 + 1))p"; }
col() { printf '%s\n' "$1" | cut -f "$2"; }

# files_of <list column> — the file paths of columns 6-8, sorted, comma-joined; `-` when empty.
files_of() {
  local colv="$1" e
  local -a outer=() inner=() res=()
  if [ -z "$colv" ] || [ "$colv" = "-" ]; then printf '%s' "$colv"; return 0; fi
  tdg_split_escaped_csv "$colv" outer 2>/dev/null
  for e in "${outer[@]}"; do
    inner=()
    tdg_split_escaped_csv "$e" inner 2>/dev/null
    res+=("${inner[0]}")
  done
  printf '%s\n' "${res[@]}" | LC_ALL=C sort | paste -sd, -
}

# time_elems <time column> — its unescaped elements, sorted, comma-joined.
time_elems() {
  local colv="$1"
  local -a outer=()
  if [ -z "$colv" ] || [ "$colv" = "-" ]; then printf '%s' "$colv"; return 0; fi
  tdg_split_escaped_csv "$colv" outer 2>/dev/null
  printf '%s\n' "${outer[@]}" | LC_ALL=C sort | paste -sd, -
}

run_h "$LEDGER_CACHE" 1 "${QUERIES[@]}"; L_OUT="$H_OUT"; L_RC="$H_RC"; L_ERR="$H_ERR"
run_h "$EMPTY_CACHE" 1 "${QUERIES[@]}"; E_OUT="$H_OUT"; E_RC="$H_RC"; E_ERR="$H_ERR"
run_h "$EMPTY_CACHE" 0 "${QUERIES[@]}"; B_OUT="$H_OUT"; B_RC="$H_RC"

case_begin "time-hard-only-candidate-is-new-time-hard-limit" "bin/lib/test-route-destination.sh"
assert_eq "ledger run rc=$L_RC err=$L_ERR" "ledger run rc=0 err="
_r="$(row "$L_OUT" 0)"
assert_eq "$Q_TH -> $(col "$_r" 2)/$(col "$_r" 3)" "$Q_TH -> new/time-hard-limit"
assert_eq "$Q_TH target=$(col "$_r" 4)" "$Q_TH target=-"
assert_eq "$Q_TH viable=$(files_of "$(col "$_r" 7)")" "$Q_TH viable=-"
assert_eq "$Q_TH excluded=$(files_of "$(col "$_r" 8)")" "$Q_TH excluded=$T/th.sh"
case_end

case_begin "size-and-time-exclusions-say-size-hard-limit" "bin/lib/test-route-destination.sh"
_r="$(row "$L_OUT" 1)"
assert_eq "$Q_MX -> $(col "$_r" 2)/$(col "$_r" 3)" "$Q_MX -> new/size-hard-limit"
assert_eq "$Q_MX viable=$(files_of "$(col "$_r" 7)")" "$Q_MX viable=-"
assert_eq "$Q_MX excluded=$(files_of "$(col "$_r" 8)")" "$Q_MX excluded=$T/mx-size.sh,$T/mx-time.sh"
case_end

case_begin "time-warn-candidate-stays-viable" "bin/lib/test-route-destination.sh"
_r="$(row "$L_OUT" 2)"
assert_eq "$Q_TW -> $(col "$_r" 2)/$(col "$_r" 3)/$(col "$_r" 4)" "$Q_TW -> append/exact/$T/tw.sh"
assert_eq "$Q_TW viable=$(files_of "$(col "$_r" 7)")" "$Q_TW viable=$T/tw.sh"
assert_eq "$Q_TW excluded=$(col "$_r" 8)" "$Q_TW excluded=-"
case_end

run_h "$LEDGER_CACHE" 1 src/tn.sh src/tq.sh src/mix.sh; V_OUT="$H_OUT"; V_RC="$H_RC"; V_ERR="$H_ERR"

case_begin "time-unknown-and-quiet-candidates-stay-viable" "bin/lib/test-route-destination.sh"
assert_eq "viable run rc=$V_RC err=$V_ERR" "viable run rc=0 err="
_r="$(row "$V_OUT" 0)"
assert_eq "src/tn.sh (tier ?) -> $(col "$_r" 2)/$(col "$_r" 3)/$(col "$_r" 4)" "src/tn.sh (tier ?) -> append/exact/$T/tn.sh"
assert_eq "src/tn.sh excluded=$(col "$_r" 8)" "src/tn.sh excluded=-"
_r="$(row "$V_OUT" 1)"
assert_eq "src/tq.sh (tier -) -> $(col "$_r" 2)/$(col "$_r" 3)/$(col "$_r" 4)" "src/tq.sh (tier -) -> append/exact/$T/tq.sh"
assert_eq "src/tq.sh excluded=$(col "$_r" 8)" "src/tq.sh excluded=-"
case_end

case_begin "hard-and-quiet-candidates-exclude-only-the-hard-one" "bin/lib/test-route-destination.sh"
_r="$(row "$V_OUT" 2)"
assert_eq "src/mix.sh -> $(col "$_r" 2)/$(col "$_r" 3)/$(col "$_r" 4)" "src/mix.sh -> append/exact/$T/mixq.sh"
assert_eq "src/mix.sh viable=$(files_of "$(col "$_r" 7)")" "src/mix.sh viable=$T/mixq.sh"
assert_eq "src/mix.sh excluded=$(files_of "$(col "$_r" 8)")" "src/mix.sh excluded=$T/mixh.sh"
case_end

case_begin "no-ledger-rows-equal-the-baseline" "bin/find-tests-for-source.sh"
assert_eq "baseline rc=$B_RC" "baseline rc=0"
assert_eq "no-ledger --with-time rc=$E_RC err=$E_ERR" "no-ledger --with-time rc=0 err="
assert_eq "baseline $Q_TH -> $(col "$(row "$B_OUT" 0)" 2)/$(col "$(row "$B_OUT" 0)" 3)" "baseline $Q_TH -> append/exact"
assert_eq "baseline $Q_MX target=$(col "$(row "$B_OUT" 1)" 4)" "baseline $Q_MX target=$T/mx-time.sh"
if [ -n "$E_OUT" ] && [ "$(printf '%s\n' "$E_OUT" | cut -f 1-8)" = "$B_OUT" ]; then
  pass "no ledger: columns 1-8 under --with-time equal the run without the flag"
else
  fail "no ledger columns 1-8" "differ from the run without the flag"
fi
case_end

case_begin "with-time-adds-a-last-time-column" "bin/find-tests-for-source.sh"
assert_eq "field counts=$(printf '%s\n' "$L_OUT" | awk -F'\t' '{print NF}' | sort -u | paste -sd, -)" "field counts=9"
assert_eq "$Q_TH time=$(time_elems "$(col "$(row "$L_OUT" 0)" 9)")" "$Q_TH time=$T/th.sh:HARD:median:3"
assert_eq "$Q_MX time=$(time_elems "$(col "$(row "$L_OUT" 1)" 9)")" \
  "$Q_MX time=$T/mx-size.sh:?:-:0,$T/mx-time.sh:HARD:median:3"
assert_eq "$Q_TW time=$(time_elems "$(col "$(row "$L_OUT" 2)" 9)")" "$Q_TW time=$T/tw.sh:WARN:median:3"
case_end

# The tier lookup, driven straight from the sourced lib with PATH emptied and the command
# hash cleared, so any external command (a fork) inside trd_time_tier breaks the answer.
# shellcheck disable=SC2016 # expanded by the driver shell
TIER_DRIVER='
set -u
. "$1/bin/lib/test-route-destination.sh" || exit 3
[ -f "$1/bin/lib/test-route-destination/time.sh" ] || { echo "time.sh absent" >&2; exit 4; }
. "$1/bin/lib/test-route-destination/time.sh" || exit 5
TRD_ROOT="$2"
trd_time_prepare "$2" || exit 6
shift 3
_saved="$PATH"
for p in "$@"; do
  TRD_TIME_TIER=""
  PATH="$EMPTY_PATH_DIR"; hash -r
  trd_time_tier "$p" >"$TIER_OUT" 2>/dev/null
  PATH="$_saved"; hash -r
  IFS= read -r got <"$TIER_OUT" || got=""
  [ -n "$got" ] || got="${TRD_TIME_TIER-}"
  printf "%s=%s\n" "$p" "$got"
done
'
T_RC=0
( cd "$REPO" || exit 99
  export RUN_ALL_CACHE_DIR="$LEDGER_CACHE" EMPTY_PATH_DIR TIER_OUT="$TMPBASE/tier.one"
  bash "$RWT" 60 bash -c "$TIER_DRIVER" _ "$SCRIPT_CHECKOUT_ROOT" "$REPO" - \
    "$T/th.sh" "$T/tw.sh" "$T/tq.sh" "$T/tn.sh"
) >"$TMPBASE/tier.out" 2>"$TMPBASE/tier.err" || T_RC=$?
T_OUT="$(cat "$TMPBASE/tier.out")"
T_ERR="$(cat "$TMPBASE/tier.err")"

case_begin "time-tier-lookup-is-fork-free" "bin/lib/test-route-destination/time.sh"
assert_eq "driver rc=$T_RC err=$T_ERR" "driver rc=0 err="
assert_eq "$(printf '%s\n' "$T_OUT" | paste -sd' ' -)" \
  "$T/th.sh=HARD $T/tw.sh=WARN $T/tq.sh=- $T/tn.sh=?"
case_end

# An unreadable ledger: a node stub that fails only for the test-time limits thj_judge reads
# (every other node call reaches the real node), so the judge reports reason=unreadable.
U_BIN="$TMPBASE/limits-fail-bin"
mkdir -p "$U_BIN"
printf '#!/bin/sh\ncase " $* " in *" test-time "*|*" --test-time-params "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v node)" > "$U_BIN/node"
chmod +x "$U_BIN/node"
_saved_path="$PATH"
export PATH="$U_BIN:$PATH"
run_h "$LEDGER_CACHE" 1 "${QUERIES[@]}"; U_OUT="$H_OUT"; U_RC="$H_RC"; U_ERR="$H_ERR"
export PATH="$_saved_path"

case_begin "unreadable-ledger-rows-equal-the-baseline" "bin/lib/test-route-destination/time.sh"
assert_eq "unreadable --with-time rc=$U_RC err=$U_ERR" "unreadable --with-time rc=0 err="
if [ -n "$U_OUT" ] && [ "$(printf '%s\n' "$U_OUT" | cut -f 1-8)" = "$B_OUT" ]; then
  pass "unreadable ledger: no HARD exclusion, columns 1-8 equal the run without the flag"
else
  fail "unreadable ledger columns 1-8" "differ from the run without the flag: ${U_OUT:0:300}"
fi
assert_eq "$Q_TH time=$(time_elems "$(col "$(row "$U_OUT" 0)" 9)")" "$Q_TH time=$T/th.sh:?:-:0"
assert_eq "$Q_TW time=$(time_elems "$(col "$(row "$U_OUT" 2)" 9)")" "$Q_TW time=$T/tw.sh:?:-:0"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
