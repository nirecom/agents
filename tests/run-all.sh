#!/usr/bin/env bash
# tests/run-all.sh — Run all (or specified) test scripts in parallel; exit 77 = skip.
# Tests: tests/run-all.sh
# Tags: bin, env, config, tests, scope:common
# Usage: tests/run-all.sh [-j N|auto] [--deadline SECS] [--print-plan] [--all | <glob-or-file> ...]
# Env:   FEATURE_644_PHASE, RUN_ALL_JOBS, RUN_ALL_DEADLINE, RUN_ALL_PROGRESS, RUN_ALL_REAP
# Exit:  0 pass / 1 fail / 2 argument error / 3 deadline abort / 130 interrupted
# See docs/architecture/tests/run-all-parallelism.md for the full contract.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${TESTS_DIR:-$AGENTS_DIR/tests}"

export FEATURE_644_PHASE="${FEATURE_644_PHASE:-0}"

# Job control puts every child in its own process group, so a whole test —
# including anything it spawned — can be torn down with one signal.
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

[ "$JOBS_SET" -eq 0 ] && [ -n "${RUN_ALL_JOBS+x}" ] && { JOBS_SET=1; JOBS_RAW="$RUN_ALL_JOBS"; }
[ "$DEADLINE_SET" -eq 0 ] && [ -n "${RUN_ALL_DEADLINE+x}" ] && { DEADLINE_SET=1; DEADLINE_RAW="$RUN_ALL_DEADLINE"; }

JOBS_MODE=auto; JOBS_FIXED=0
if [ "$JOBS_SET" -eq 1 ]; then
  case "$JOBS_RAW" in
    auto) ;;
    ''|*[!0-9]*) usage_error "invalid jobs value '$JOBS_RAW' (expected auto or an integer 1-1024)" ;;
    *) { [ "$JOBS_RAW" -ge 1 ] && [ "$JOBS_RAW" -le 1024 ]; } 2>/dev/null ||
         usage_error "invalid jobs value '$JOBS_RAW' (expected auto or an integer 1-1024)"
       JOBS_MODE=fixed; JOBS_FIXED="$JOBS_RAW" ;;
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
SELF_BASE="${BASH_SOURCE[0]##*/}"
SELF_PATH=""

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

WORK=()
add_work() {
  [ -f "$1" ] || return 0
  is_self "$1" && return 0
  WORK+=("$1")
  return 0
}

# Empty IFS keeps pathname expansion but disables word splitting, so a
# pattern with spaces still globs correctly without eval.
expand_pattern() {
  local IFS='' f
  for f in $1; do add_work "$f"; done
  return 0
}

if [ "$WANT_ALL" -eq 1 ] || [ $# -eq 0 ]; then
  # _archive/ is auto-excluded — *.sh matches top-level files only
  for f in "$TESTS_DIR"/*.sh; do add_work "$f"; done
else
  for pattern in "$@"; do expand_pattern "$pattern"; done
fi
TOTAL=${#WORK[@]}

WORKDIR="$(mktemp -d 2>/dev/null)" || usage_error "cannot create a temporary work directory"

CLEANUP_DONE=0
INFLIGHT=()
declare -a JOB_PID JOB_START JOB_RC DONE_FLAG LANE

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

# Bounded teardown: TERM, one grace second, then KILL — no polling, so a
# stuck child cannot stall it.
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
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR" 2>/dev/null
  return 0
}
trap 'cleanup_all; exit 130' INT TERM
trap 'cleanup_all' EXIT

# --- serial lane (reader side) ---------------------------------------------
# Reader window is lines 1-20 (lenient); authors are held to 10.
SERIAL_COUNT=0
scan_serial_batch() {
  awk 'FNR<=20 && /^# Serial:[ \t]*[^ \t]/ && !seen[FILENAME]++ { print FILENAME }' \
    "$@" >>"$WORKDIR/serial.list" 2>/dev/null
  return 0
}

detect_serial() {
  local i line batch=()
  for ((i = 0; i < TOTAL; i++)); do LANE[$i]=parallel; done
  [ "$TOTAL" -gt 0 ] || return 0
  : >"$WORKDIR/serial.list"
  # Batched so the argument vector stays clear of the 32KB Windows limit.
  for ((i = 0; i < TOTAL; i++)); do
    batch+=("${WORK[$i]}")
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

# --- width -----------------------------------------------------------------
RESOLVED_J=4
resolve_jobs() {
  local lib="${RUN_ALL_PARALLELISM_LIB:-$AGENTS_DIR/bin/lib/run-all-parallelism.sh}" reason=missing
  if [ "$JOBS_MODE" = "fixed" ]; then RESOLVED_J="$JOBS_FIXED"; return 0; fi
  # Read-only: never writes, repairs, or invokes the calibrator.
  # shellcheck source=/dev/null
  if [ -f "$lib" ] && . "$lib" 2>/dev/null && command -v run_all_cache_read >/dev/null 2>&1; then
    RESOLVED_J="${RUN_ALL_FALLBACK_JOBS:-4}"
    if run_all_cache_read "$(run_all_cache_file)" 2>/dev/null; then
      RESOLVED_J="$RUN_ALL_CACHE_JOBS"
      say "parallelism: -j $RESOLVED_J (calibrated $RUN_ALL_CACHE_MEASURED_AT)"
      return 0
    fi
    reason="${RUN_ALL_CACHE_REASON:-missing}"
  fi
  say "parallelism cache $reason; using -j $RESOLVED_J (conservative default). Calibrate with: ${RUN_ALL_CALIBRATOR_HINT:-bin/calibrate-test-parallelism.sh}"
  return 0
}
resolve_jobs

EFFECTIVE_J="$RESOLVED_J"
[ "$TOTAL" -lt "$EFFECTIVE_J" ] && EFFECTIVE_J="$TOTAL"
[ "$EFFECTIVE_J" -lt 1 ] && EFFECTIVE_J=1

if [ "$PRINT_PLAN" -eq 1 ]; then
  printf 'tests_dir=%s\n' "$TESTS_DIR"
  printf 'jobs=%s\n' "$EFFECTIVE_J"
  printf 'serial_count=%s\n' "$SERIAL_COUNT"
  for ((idx = 0; idx < TOTAL; idx++)); do
    printf 'plan\t%s\t%s\t%s\n' "$idx" "${LANE[$idx]}" "${WORK[$idx]}"
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
PASS=0; FAIL=0; SKIP=0
NEXT=0; REPORTED=0; HARVESTED=0
SERIAL_INFLIGHT=0; BARRIER_ANNOUNCED=0; DEADLINE_HIT=0; IDLE_SPINS=0
START_TS=$SECONDS

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

launch() {
  local i="$1" script="${WORK[$1]}"
  ( bash "$script" >"$WORKDIR/$i.out" 2>"$WORKDIR/$i.err" </dev/null
    echo $? >"$WORKDIR/$i.rc" ) &
  JOB_PID[$i]=$!
  JOB_START[$i]=$SECONDS
  INFLIGHT+=("$i")
  [ "${LANE[$i]}" = serial ] && SERIAL_INFLIGHT=1
  say "$((i + 1))/$TOTAL start $script (j=$EFFECTIVE_J inflight=${#INFLIGHT[@]})"
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
    rc="${JOB_RC[$i]:-1}"
    case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
    neutralize_stream "$WORKDIR/$i.out"
    neutralize_stream "$WORKDIR/$i.err" >&2
    if [ "$rc" -eq 0 ]; then
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
    [ "${#INFLIGHT[@]}" -lt "$EFFECTIVE_J" ] || break
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

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
EXECUTED=$((PASS + FAIL + SKIP))
echo "RUN_CONTRACT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP EXECUTED=$EXECUTED"
cleanup_all
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
