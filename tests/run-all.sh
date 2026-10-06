#!/usr/bin/env bash
# tests/run-all.sh — Run all (or specified) test scripts in parallel; exit 77 = skip.
# Tests: tests/run-all.sh
# Tags: bin, env, config, tests, scope:common
# Usage: tests/run-all.sh [-j N|auto] [--deadline SECS] [--print-plan] [--all | <glob-or-file> ...]
# Env:   FEATURE_644_PHASE, TEST_MAX_JOBS_PER_RUN, RUN_ALL_DEADLINE, RUN_ALL_PROGRESS, RUN_ALL_REAP
# Exit:  0 pass / 1 fail / 2 argument error / 3 deadline abort / 4 no test lane / 5 registry unreadable / 130 interrupted
# See docs/architecture/claude-code/test-runner-parallelism.md for the full contract.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${TESTS_DIR:-$AGENTS_DIR/tests}"
REGISTRY_LIB="${RUN_ALL_REGISTRY_LIB:-$AGENTS_DIR/bin/lib/test-language-registry.sh}"
# shellcheck source=/dev/null
{ [ -f "$REGISTRY_LIB" ] && . "$REGISTRY_LIB" && tlr_load; } || { echo "[run-all] test language registry not readable: $REGISTRY_LIB (RUN_ALL_REGISTRY_LIB)" >&2; exit 5; }

export FEATURE_644_PHASE="${FEATURE_644_PHASE:-0}"

# Job control: each child gets its own process group, torn down with one signal.
set -m 2>/dev/null || true
case "$-" in *m*) PGROUP_KILL=1 ;; *) PGROUP_KILL=0 ;; esac

usage_error() { echo "[run-all] $1" >&2; exit 2; }

# --- option prefix ---------------------------------------------------------
JOBS_SET=0; JOBS_RAW=""
DEADLINE_SET=0; DEADLINE_RAW=""
WANT_ALL=0; PRINT_PLAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --all)        WANT_ALL=1; shift ;;
    --print-plan) PRINT_PLAN=1; shift ;;
    -j|--jobs)    [ $# -ge 2 ] || usage_error "option $1 requires a value"
                  JOBS_SET=1; JOBS_RAW="$2"; shift 2 ;;
    --jobs=*)     JOBS_SET=1; JOBS_RAW="${1#--jobs=}"; shift ;;
    --deadline)   [ $# -ge 2 ] || usage_error "option $1 requires a value"
                  DEADLINE_SET=1; DEADLINE_RAW="$2"; shift 2 ;;
    --deadline=*) DEADLINE_SET=1; DEADLINE_RAW="${1#--deadline=}"; shift ;;
    --)           shift; break ;;
    -*)           usage_error "unknown option: $1" ;;
    *)            break ;;
  esac
done

{ [ "$JOBS_SET" -eq 0 ] || [ "$JOBS_RAW" = auto ]; } && [ -n "${TEST_MAX_JOBS_PER_RUN:-}" ] && { JOBS_SET=1; JOBS_RAW="$TEST_MAX_JOBS_PER_RUN"; }
[ "$DEADLINE_SET" -eq 0 ] && [ -n "${RUN_ALL_DEADLINE+x}" ] && { DEADLINE_SET=1; DEADLINE_RAW="$RUN_ALL_DEADLINE"; }

JOBS_MODE=auto; MAX_JOBS_PER_RUN_FIXED=0
if [ "$JOBS_SET" -eq 1 ]; then
  case "$JOBS_RAW" in
    auto) ;;
    ''|*[!0-9]*) usage_error "invalid jobs value '$JOBS_RAW' (expected auto or an integer 1-1024)" ;;
    *) { [ "$JOBS_RAW" -ge 1 ] && [ "$JOBS_RAW" -le 1024 ]; } 2>/dev/null ||
         usage_error "invalid jobs value '$JOBS_RAW' (expected auto or an integer 1-1024)"
       JOBS_MODE=fixed; MAX_JOBS_PER_RUN_FIXED="$JOBS_RAW" ;;
  esac
fi

DEADLINE=0
if [ "$DEADLINE_SET" -eq 1 ]; then
  case "$DEADLINE_RAW" in
    ''|*[!0-9]*) usage_error "invalid deadline value '$DEADLINE_RAW' (expected a positive integer of seconds)" ;;
    *) { [ "$DEADLINE_RAW" -ge 1 ]; } 2>/dev/null ||
         usage_error "invalid deadline value '$DEADLINE_RAW' (expected a positive integer of seconds)"
       DEADLINE="$DEADLINE_RAW" ;;
  esac
fi

PROGRESS=1
case "${RUN_ALL_PROGRESS:-on}" in off|OFF|0|false) PROGRESS=0 ;; esac
say() { [ "$PROGRESS" -eq 1 ] && printf '[run-all] %s\n' "$1" >&2; return 0; }

# --- work list -------------------------------------------------------------
# #1836: exclude self — the glob matches this script too.
SELF_BASE="${BASH_SOURCE[0]##*/}"; SELF_PATH=""

# Basename check is a fast gate before the canonicalising subshell.
is_self() {
  local d
  [ "${1##*/}" = "$SELF_BASE" ] || return 1
  if [ -z "$SELF_PATH" ]; then
    case "${BASH_SOURCE[0]}" in */*) d="${BASH_SOURCE[0]%/*}" ;; *) d="." ;; esac
    SELF_PATH="$(cd "$d" 2>/dev/null && pwd -P)/$SELF_BASE"
  fi
  case "$1" in */*) d="${1%/*}" ;; *) d="." ;; esac
  d="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  [ "$d/$SELF_BASE" = "$SELF_PATH" ]
}

WORK=(); UNSUP=()   # UNSUP: files no supported registry entry covers — listed, never run
add_work() {
  [ -f "$1" ] || return 0
  is_self "$1" && return 0
  if tlr_match "$1" && [ "$TLR_STATUS" = supported ]; then WORK+=("$1"); else UNSUP+=("$1"); fi
  return 0
}

# Empty IFS: pathname expansion without word splitting, so spaced patterns glob sans eval.
expand_pattern() {
  local IFS='' f
  for f in $1; do add_work "$f"; done
  return 0
}

if [ "$WANT_ALL" -eq 1 ] || [ $# -eq 0 ]; then
  # The six categories' direct files only (sub-dirs, lib, fixtures, tests/ top level excluded).
  for cat in hooks bin skills agents install tests; do
    tlr_list_dir_into "$TESTS_DIR/$cat" supported && for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do add_work "$f"; done
    tlr_list_dir_into "$TESTS_DIR/$cat" recognized-only && for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do tlr_match "$f" && [ "$TLR_STATUS" != supported ] && UNSUP+=("$f"); done
  done
else
  for pattern in "$@"; do expand_pattern "$pattern"; done
fi
# A suite-unit language runs once per suite root (tlr_dedupe_suites keeps one file per root).
tlr_dedupe_suites_into ${WORK[@]+"${WORK[@]}"}; WORK=(${TLR_LIST[@]+"${TLR_LIST[@]}"})
TOTAL=${#WORK[@]}

WORKDIR="$(mktemp -d 2>/dev/null)" || usage_error "cannot create a temporary work directory"

CLEANUP_DONE=0; INFLIGHT=()
declare -a JOB_PID JOB_START JOB_RC DONE_FLAG LANE TIER KEY

signal_tree() {
  local sig="$1" pid="$2" kid
  if [ "$PGROUP_KILL" = "1" ]; then
    kill -"$sig" "-$pid" 2>/dev/null
  else
    for kid in $(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }'); do
      [ "$kid" = "$pid" ] || signal_tree "$sig" "$kid"
    done
  fi
  kill -"$sig" "$pid" 2>/dev/null
  return 0
}

# Bounded teardown: TERM, one grace second, then KILL — no polling to stall on.
cleanup_all() {
  local i pid pids=""
  [ "$CLEANUP_DONE" -eq 1 ] && return 0
  CLEANUP_DONE=1
  for i in ${INFLIGHT[@]+"${INFLIGHT[@]}"}; do
    pid="${JOB_PID[$i]:-}"
    [ -n "$pid" ] && pids="$pids $pid"
  done
  if [ -n "$pids" ]; then
    for pid in $pids; do signal_tree TERM "$pid"; done
    sleep 1
    for pid in $pids; do signal_tree KILL "$pid"; done
  fi
  command -v run_all_dur_close >/dev/null 2>&1 && run_all_dur_close
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR" 2>/dev/null
  [ "${LANES_LIB_OK:-0}" -eq 1 ] && thl_release_all
  return 0
}
trap 'cleanup_all; exit 130' INT TERM
trap 'cleanup_all' EXIT
# --- serial lane (reader side) ---------------------------------------------
# Reader window is the registry's headerMaxLines, the same limit authors are held to.
SERIAL_COUNT=0
scan_serial_batch() { # args: <header.commentPrefix>TAB<file>, matched as a fixed string
  printf '%s\n' "$@" | awk -v M="$TLR_HEADER_MAX_LINES" '{ t = index($0, "\t"); p = substr($0, 1, t - 1) " Serial:"; f = substr($0, t + 1); n = 0
    while (n++ < M + 0 && (getline l < f) > 0) { if (index(l, p) == 1 && substr(l, length(p) + 1) ~ /^[ \t]*[^ \t]/) { print f; break } } close(f) }' >>"$WORKDIR/serial.list" 2>/dev/null
  return 0
}

detect_serial() {
  local i line batch=()
  for ((i = 0; i < TOTAL; i++)); do LANE[$i]=parallel; done
  [ "$TOTAL" -gt 0 ] || return 0
  : >"$WORKDIR/serial.list"
  # Batched so the argument vector stays clear of the 32KB Windows limit.
  for ((i = 0; i < TOTAL; i++)); do
    tlr_comment_prefix "${WORK[$i]}" >/dev/null; batch+=("$TLR_COMMENT_PREFIX"$'\t'"${WORK[$i]}")
    if [ "${#batch[@]}" -ge 200 ]; then scan_serial_batch "${batch[@]}"; batch=(); fi
  done
  [ "${#batch[@]}" -gt 0 ] && scan_serial_batch "${batch[@]}"
  while IFS= read -r line; do
    for ((i = 0; i < TOTAL; i++)); do
      if [ "${WORK[$i]}" = "$line" ] && [ "${LANE[$i]}" != serial ]; then
        LANE[$i]=serial; SERIAL_COUNT=$((SERIAL_COUNT + 1))
      fi
    done
  done <"$WORKDIR/serial.list"
  return 0
}
detect_serial

# --- duration ledger -------------------------------------------------------
# Submission order is Longest-Processing-Time-first over historical durations (rationale:
# docs/architecture/claude-code/test-runner-parallelism.md).
PARALLELISM_LIB_OK=0; DUR_LIB_OK=0; LANES_LIB_OK=0; LEDGER_INITED=0
UNMEASURED=99

load_run_all_libs() {
  local plib="${RUN_ALL_PARALLELISM_LIB:-$AGENTS_DIR/bin/lib/run-all-parallelism.sh}"
  local dlib="${RUN_ALL_DURATIONS_LIB:-$AGENTS_DIR/bin/lib/run-all-durations.sh}"
  # shellcheck source=/dev/null
  [ -f "$plib" ] && . "$plib" 2>/dev/null &&
    command -v run_all_cache_dir >/dev/null 2>&1 && PARALLELISM_LIB_OK=1
  [ "$PARALLELISM_LIB_OK" -eq 1 ] || return 0
  local llib="${RUN_ALL_LANES_LIB:-$AGENTS_DIR/bin/lib/test-host-lanes.sh}"
  # shellcheck source=/dev/null
  [ -f "$llib" ] && . "$llib" 2>/dev/null && command -v thl_run_all_lease >/dev/null 2>&1 && LANES_LIB_OK=1
  # shellcheck source=/dev/null
  [ -f "$dlib" ] && . "$dlib" 2>/dev/null &&
    command -v run_all_dur_lookup >/dev/null 2>&1 && DUR_LIB_OK=1
  [ "$DUR_LIB_OK" -eq 1 ] && UNMEASURED="$RUN_ALL_DUR_TIER_UNMEASURED"
  return 0
}
load_run_all_libs

# Keys are computed for every index even when the run is too small to reorder: the key
# is what the writer records at completion, not just what the sort consumed.
init_tiers() {
  local i id secs
  for ((i = 0; i < TOTAL; i++)); do TIER[$i]="$UNMEASURED"; KEY[$i]=""; done
  { [ "$DUR_LIB_OK" -eq 1 ] && [ "$TOTAL" -gt 0 ]; } || return 0
  for ((i = 0; i < TOTAL; i++)); do
    run_all_dur_key_into "${WORK[$i]}" "$AGENTS_DIR" || true
    KEY[$i]="$RUN_ALL_DUR_KEY_OUT"
    printf '%s\t%s\n' "$i" "$RUN_ALL_DUR_KEY_OUT"
  done >"$WORKDIR/dur.keys" 2>/dev/null
  [ -f "$WORKDIR/dur.keys" ] || return 0
  run_all_dur_lookup "$AGENTS_DIR" "$WORKDIR/dur.keys" "$WORKDIR/dur.secs"
  [ -f "$WORKDIR/dur.secs" ] || return 0
  while IFS="$(printf '\t')" read -r id secs; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    [ "$id" -lt "$TOTAL" ] || continue
    [ -n "$secs" ] || continue
    run_all_dur_tier_into "$secs" && TIER[$id]="$RUN_ALL_DUR_TIER_OUT"
  done <"$WORKDIR/dur.secs"
  return 0
}
init_tiers

# Bucket sort on the tier, unmeasured first then longest-first, stable inside a bucket so
# an all-unmeasured ledger reproduces glob order exactly. Serial slots are pinned: the
# barrier semantics are positional, so only the parallel-lane rows are permuted.
sort_work_lpt() {
  local i j k t
  local -a slots=() ordered=() nw=() nl=() nt=() nk=()
  [ "$TOTAL" -ge 2 ] || return 0
  for ((i = 0; i < TOTAL; i++)); do
    [ "${LANE[$i]}" = serial ] || slots+=("$i")
  done
  [ "${#slots[@]}" -ge 2 ] || return 0
  for j in "${slots[@]}"; do
    [ "${TIER[$j]}" = "$UNMEASURED" ] && ordered+=("$j")
  done
  t=30
  while [ "$t" -ge 0 ]; do
    for j in "${slots[@]}"; do
      [ "${TIER[$j]}" = "$t" ] && ordered+=("$j")
    done
    t=$((t - 1))
  done
  [ "${#ordered[@]}" -eq "${#slots[@]}" ] || return 0
  k=0
  for ((i = 0; i < TOTAL; i++)); do
    if [ "${LANE[$i]}" = serial ]; then
      j="$i"
    else
      j="${ordered[$k]}"
      k=$((k + 1))
    fi
    nw[$i]="${WORK[$j]}"
    nl[$i]="${LANE[$j]}"
    nt[$i]="${TIER[$j]}"
    nk[$i]="${KEY[$j]:-}"
  done
  WORK=("${nw[@]}")
  LANE=("${nl[@]}")
  TIER=("${nt[@]}")
  KEY=("${nk[@]}")
  return 0
}
sort_work_lpt

# Lazy: the segment is created on the first completed test, so a run that executes
# nothing (a pattern matching no file, --print-plan) leaves no ledger behind.
ledger_record() {
  local i="$1" secs=""
  [ "$DUR_LIB_OK" -eq 1 ] || return 0
  [ -n "${KEY[$i]:-}" ] || return 0
  [ -f "$WORKDIR/$i.dur" ] || return 0
  read -r secs <"$WORKDIR/$i.dur" 2>/dev/null
  case "$secs" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$LEDGER_INITED" -eq 0 ]; then
    LEDGER_INITED=1
    run_all_dur_writer_init "$AGENTS_DIR"
  fi
  run_all_dur_append "${KEY[$i]}" "$secs"
  return 0
}

# --- width -----------------------------------------------------------------
RUN_JOBS=4
resolve_jobs() {
  if [ "$JOBS_MODE" = "fixed" ]; then RUN_JOBS="$MAX_JOBS_PER_RUN_FIXED"; return 0; fi
  if [ "$PARALLELISM_LIB_OK" -eq 1 ]; then
    run_all_resolve_max_jobs_per_run || usage_error "$RUN_ALL_RESOLVE_NOTE"
    RUN_JOBS="$RUN_ALL_MAX_JOBS_PER_RUN"; say "$RUN_ALL_RESOLVE_NOTE"; return 0
  fi
  say "parallelism library unavailable; max jobs per run $RUN_JOBS (built-in default)"
}
resolve_jobs
[ "$TOTAL" -lt "$RUN_JOBS" ] && RUN_JOBS="$TOTAL"
[ "$RUN_JOBS" -lt 1 ] && RUN_JOBS=1

if [ "$PRINT_PLAN" -eq 1 ]; then
  [ "$LANES_LIB_OK" -eq 1 ] && { thl_plan "$RUN_JOBS"; RUN_JOBS="$THL_PLAN_JOBS"; say "plan: $THL_NOTE"; }
  printf 'tests_dir=%s\n' "$TESTS_DIR"
  printf 'jobs=%s\n' "$RUN_JOBS"
  printf 'serial_count=%s\n' "$SERIAL_COUNT"
  for ((idx = 0; idx < TOTAL; idx++)); do
    printf 'plan\t%s\t%s\t%s\t%s\n' "$idx" "${LANE[$idx]}" "${WORK[$idx]}" "${TIER[$idx]:-$UNMEASURED}"
  done
  cleanup_all
  exit 0
fi

# --- reaper ----------------------------------------------------------------
# RUN_ALL_WAITN_PROBE is a test seam used only when resolving `auto`.
REAP="${RUN_ALL_REAP:-auto}"
case "$REAP" in
  waitn|fifo) ;;
  *) case "${RUN_ALL_WAITN_PROBE-}" in
       0) REAP=fifo ;;
       1) REAP=waitn ;;
       *) if [ "${BASH_VERSINFO[0]}" -gt 4 ] ||
            { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
            REAP=waitn
          else
            REAP=fifo
          fi ;;
     esac ;;
esac
say "reap: $REAP"

# --- scheduler -------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0; NEXT=0; REPORTED=0; HARVESTED=0
SERIAL_INFLIGHT=0; BARRIER_ANNOUNCED=0; DEADLINE_HIT=0; IDLE_SPINS=0; START_TS=$SECONDS
# Host-wide lanes (#2455): the lease can only narrow RUN_JOBS, never widen it.
if [ "$LANES_LIB_OK" -eq 1 ] && [ "$TOTAL" -gt 0 ]; then
  thl_init_dir; thl_run_all_lease "$RUN_JOBS" "$DEADLINE" || { cleanup_all
    echo "[run-all] no test lane freed within ${THL_WAIT_CAP_USED}s; inspect holders with: bash bin/test-lanes-status.sh" >&2; exit 4; }
  RUN_JOBS="$THL_GRANTED"; [ -n "$THL_NOTE" ] && say "lanes: $THL_NOTE"
fi

# Only a line-initial RUN_CONTRACT marker is disarmed, by prefixing.
# Shell builtins only — a fork per line would outcost the run on MSYS.
neutralize_stream() {
  local line
  [ -s "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^[[:blank:]]*RUN_CONTRACT: ]]; then
      printf '[run-all:neutralized] %s\n' "$line"
    else
      printf '%s\n' "$line"
    fi
  done <"$1"
  return 0
}

LAUNCH_LIB="${RUN_ALL_LAUNCH_LIB:-$AGENTS_DIR/bin/lib/run-all-launch.sh}"
# shellcheck source=/dev/null
[ -f "$LAUNCH_LIB" ] && . "$LAUNCH_LIB"
command -v run_all_exec >/dev/null 2>&1 || run_all_exec() { tlr_exec_plain "$@"; }
if command -v run_all_pin_state_dirs >/dev/null 2>&1; then run_all_pin_state_dirs "$WORKDIR" || usage_error "cannot pin the per-run state directories"; fi

launch() {
  local i="$1" script="${WORK[$1]}"
  # The duration is measured child-side and written BEFORE the rc file, which stays the
  # sole completion signal — a harvest that sees <i>.rc always sees a finished <i>.dur.
  ( __t0=$SECONDS
    run_all_exec "$script" "$WORKDIR/$i.out" "$WORKDIR/$i.err"
    __rc=$?; [ "$__rc" = 78 ] && [ "${RUN_ALL_EXEC_LAUNCHED:-1}" = 0 ] && __rc=U
    echo $((SECONDS - __t0)) >"$WORKDIR/$i.dur"
    echo "$__rc" >"$WORKDIR/$i.rc" ) &
  JOB_PID[$i]=$!
  JOB_START[$i]=$SECONDS
  INFLIGHT+=("$i")
  [ "${LANE[$i]}" = serial ] && SERIAL_INFLIGHT=1
  say "$((i + 1))/$TOTAL start $script (j=$RUN_JOBS inflight=${#INFLIGHT[@]})"
  NEXT=$((NEXT + 1))
  return 0
}

# The <i>.rc file is the source of truth for job completion; read only
# after waiting on the pid, so the file is guaranteed whole.
harvest() {
  local i rc rest=()
  HARVESTED=0
  for i in ${INFLIGHT[@]+"${INFLIGHT[@]}"}; do
    if [ -e "$WORKDIR/$i.rc" ]; then
      wait "${JOB_PID[$i]}" 2>/dev/null
      rc=""
      read -r rc <"$WORKDIR/$i.rc" 2>/dev/null
      JOB_RC[$i]="$rc"
      DONE_FLAG[$i]=1
      ledger_record "$i"
      [ "${LANE[$i]}" = serial ] && SERIAL_INFLIGHT=0
      HARVESTED=$((HARVESTED + 1))
    else
      rest+=("$i")
    fi
  done
  INFLIGHT=(${rest[@]+"${rest[@]}"})
  return 0
}

# Replay is strictly in SUBMISSION order, so stdout is byte-identical at any -j.
flush() {
  local i script rc verdict
  while [ "$REPORTED" -lt "$NEXT" ]; do
    i="$REPORTED"
    [ "${DONE_FLAG[$i]:-0}" = "1" ] || break
    script="${WORK[$i]}"
    rc="${JOB_RC[$i]:-1}"; case "$rc" in U) ;; ''|*[!0-9]*) rc=1 ;; esac
    neutralize_stream "$WORKDIR/$i.out"
    neutralize_stream "$WORKDIR/$i.err" >&2
    if [ "$rc" = U ]; then verdict=UNSUPPORTED  # not launched; <i>.out already holds its UNSUPPORTED line
    elif [ "$rc" -eq 0 ]; then
      echo "PASS: $script"; PASS=$((PASS + 1)); verdict=PASS
    elif [ "$rc" -eq 77 ]; then
      echo "SKIP: $script"; SKIP=$((SKIP + 1)); verdict=SKIP
    else
      echo "FAIL: $script (exit $rc)"; FAIL=$((FAIL + 1)); verdict=FAIL
    fi
    say "$((i + 1))/$TOTAL $verdict $script $((SECONDS - ${JOB_START[$i]}))s"
    REPORTED=$((REPORTED + 1))
  done
  return 0
}

# Without a deadline the wait BLOCKS — polling would burn a core for the whole
# suite. With one, the same wait is bounded so a wedged child cannot outlive it.
reap_wait() {
  if [ "$DEADLINE" -gt 0 ]; then
    while :; do
      harvest
      [ "$HARVESTED" -gt 0 ] && return 0
      if [ $((SECONDS - START_TS)) -ge "$DEADLINE" ]; then DEADLINE_HIT=1; return 1; fi
      sleep 1
    done
  fi
  if [ "$REAP" = "waitn" ]; then
    wait -n 2>/dev/null
  else
    wait "${JOB_PID[${INFLIGHT[0]}]}" 2>/dev/null
  fi
  harvest
  if [ "$HARVESTED" -gt 0 ]; then
    IDLE_SPINS=0
  else
    IDLE_SPINS=$((IDLE_SPINS + 1))
    [ "$IDLE_SPINS" -ge 3 ] && sleep 1
  fi
  return 0
}

while [ "$REPORTED" -lt "$TOTAL" ]; do
  while [ "$NEXT" -lt "$TOTAL" ] && [ "$SERIAL_INFLIGHT" -eq 0 ]; do
    if [ "${LANE[$NEXT]}" = serial ]; then
      if [ "${#INFLIGHT[@]}" -gt 0 ]; then
        [ "$BARRIER_ANNOUNCED" -eq 1 ] ||
          say "serial barrier: draining ${#INFLIGHT[@]} job(s) before ${WORK[$NEXT]}"
        BARRIER_ANNOUNCED=1
        break
      fi
      [ "$BARRIER_ANNOUNCED" -eq 1 ] ||
        say "serial barrier: draining 0 job(s) before ${WORK[$NEXT]}"
      say "serial: running ${WORK[$NEXT]} alone"
      BARRIER_ANNOUNCED=0
      launch "$NEXT"
      break
    fi
    [ "${#INFLIGHT[@]}" -lt "$RUN_JOBS" ] || break
    launch "$NEXT"
  done
  if [ "${#INFLIGHT[@]}" -eq 0 ]; then flush; break; fi
  reap_wait || break
  flush
done

if [ "$DEADLINE_HIT" -eq 1 ]; then
  echo "[run-all] deadline of ${DEADLINE}s exceeded; aborting the run" >&2
  cleanup_all
  exit 3
fi

for f in ${UNSUP[@]+"${UNSUP[@]}"}; do tlr_match "$f"; printf 'UNSUPPORTED: %s (language: %s; not run)\n' "$f" "${TLR_ID:-unknown}"; done
echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
EXECUTED=$((PASS + FAIL + SKIP))
echo "RUN_CONTRACT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP EXECUTED=$EXECUTED"
cleanup_all
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
