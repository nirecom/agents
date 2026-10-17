#!/usr/bin/env bash
# Launch helpers for tests/run-all.sh; sourced, never executed.
# run_all_exec <script> <out> <err> [<resultdir>] — launch one test the way its registry entry says,
# then classify it (bin/lib/run-all-classify.sh). Sets RUN_ALL_EXEC_LAUNCHED / _STATE / _RC / _MISSING
# and returns that rc. Only the child sees RUN_ALL_RESULT_DIR / RUN_ALL_RESULT_OWNER; without
# <resultdir> a temporary one is used and removed. Contract: docs/architecture/claude-code/test-result-contract.md.
# Each test is wrapped in worktree change detection.
# run_all_pin_test_env <root> — the per-run pins: carried settings, root decoy, run root, command
# guard, state dirs, change detection; each is described at its function.
# Hits (claim after each test, the end-of-run collect and report): bin/lib/run-all-hits.sh.
# Contract: docs/architecture/claude-code/test-runner-parallelism.md, test-command-guard.md.

case "${BASH_SOURCE[0]}" in
  */*) RUN_ALL_LAUNCH_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RUN_ALL_LAUNCH_DIR="." ;;
esac

# shellcheck source=tests/lib/test-run-root.sh
[ -f "$RUN_ALL_LAUNCH_DIR/../../tests/lib/test-run-root.sh" ] && . "$RUN_ALL_LAUNCH_DIR/../../tests/lib/test-run-root.sh"
# shellcheck source=tests/lib/command-guard.sh
[ -f "$RUN_ALL_LAUNCH_DIR/../../tests/lib/command-guard.sh" ] && . "$RUN_ALL_LAUNCH_DIR/../../tests/lib/command-guard.sh"
# shellcheck source=bin/lib/run-all-worktree-change-detect.sh
[ -f "$RUN_ALL_LAUNCH_DIR/run-all-worktree-change-detect.sh" ] && . "$RUN_ALL_LAUNCH_DIR/run-all-worktree-change-detect.sh"
# shellcheck source=bin/lib/run-all-hits.sh
[ -f "$RUN_ALL_LAUNCH_DIR/run-all-hits.sh" ] && . "$RUN_ALL_LAUNCH_DIR/run-all-hits.sh"

# run_all_pin_state_dirs <root> — exports WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR as fresh
# subdirectories of <root>; non-zero when they cannot be created.
# Always overrides the inherited pair: a test that pins neither or only one of them must
# never reach the developer's live ~/.workflow-state (or its legacy root) or ~/.workflow-plans.
run_all_pin_state_dirs() {
  local root="${1:-}"
  [[ -n "$root" ]] || return 1
  # Mixed form so Node on Windows receives a usable path.
  if command -v cygpath >/dev/null 2>&1; then root="$(cygpath -m "$root")"; fi
  mkdir -p "$root/workflow" "$root/plans" 2>/dev/null || return 1
  export WORKFLOW_STATE_DIR="$root/workflow" WORKFLOW_PLANS_DIR="$root/plans"
}

_RUN_ALL_DECOY_LIB="$RUN_ALL_LAUNCH_DIR/../../tests/lib/root-decoy.sh"
_RUN_ALL_DECOY_RUN=""
_RUN_ALL_DECOY_SINCE=""
_RUN_ALL_CARRIED_KEYS="RUN_TL3 RUN_TL4"

# run_all_pin_root_decoy — points AGENTS_MAIN_ROOT and the retired root names at the stub trees
# of tests/lib/root-decoy.sh; non-zero (nothing switched) when the decoy is unavailable.
# Exception: a launcher copied without tests/lib (a fixture) keeps a decoy its caller already pinned.
run_all_pin_root_decoy() {
  if [ ! -f "$_RUN_ALL_DECOY_LIB" ] && [ -n "${ROOT_DECOY_DIR:-}" ] && [ -d "$ROOT_DECOY_DIR/main" ] &&
    [ "${AGENTS_MAIN_ROOT:-}" = "$ROOT_DECOY_DIR/main" ]; then
    _RUN_ALL_DECOY_RUN="run-$$-$RANDOM$RANDOM"
    return 0
  fi
  if [ ! -f "$_RUN_ALL_DECOY_LIB" ]; then
    printf '[run-all-launch] %s not found; refusing to run without the root decoy\n' "$_RUN_ALL_DECOY_LIB" >&2
    return 1
  fi
  # shellcheck source=tests/lib/root-decoy.sh
  . "$_RUN_ALL_DECOY_LIB" || return 1
  root_decoy_ensure || return 1
  # The decoy is shared through the cache dir, so a hit is told apart by this run's token.
  _RUN_ALL_DECOY_RUN="run-$$-$RANDOM$RANDOM"
}

# _run_all_real_setting <key> — the value the real settings give <key>, read before the switch.
# Transitional: bin/get-config-var still finds its settings dir through the retired names, so a
# caller that only set AGENTS_MAIN_ROOT has it handed over under those names for this one read.
_run_all_real_setting() {
  local getcv="$RUN_ALL_LAUNCH_DIR/../get-config-var" builder name
  local -a bridge=()
  [ -f "$getcv" ] || return 0
  if [ -n "${AGENTS_MAIN_ROOT:-}" ]; then
    builder="$RUN_ALL_LAUNCH_DIR/../../tests/lib/root-decoy-build.js"
    command -v cygpath >/dev/null 2>&1 && builder="$(cygpath -m "$builder")"
    while IFS= read -r name; do
      name="${name%$'\r'}"
      [ -n "$name" ] && bridge+=("$name=$AGENTS_MAIN_ROOT")
    done < <(node "$builder" --print-retired-env-names 2>/dev/null)
  fi
  env ${bridge[@]+"${bridge[@]}"} bash "$getcv" "$1" 2>/dev/null || true
}

_RUN_ALL_GUARD_DIR=""

# run_all_pin_command_guard — a fresh guard instance in $TEST_RUN_ROOT/command-guard, first on
# PATH (tests/lib/command-guard.sh); an inherited COMMAND_GUARD_DIR is never reused here.
run_all_pin_command_guard() {
  if ! declare -F command_guard_ensure >/dev/null 2>&1; then
    printf '[run-all-launch] tests/lib/command-guard.sh not loaded; refusing to run without the command guard\n' >&2
    return 1
  fi
  unset COMMAND_GUARD_DIR
  command_guard_ensure || return 1
  _RUN_ALL_GUARD_DIR="$COMMAND_GUARD_DIR"
}

# _run_all_fixture_pins_inherited — the run root / command guard side of the fixture exception at
# run_all_pin_root_decoy: a launcher copied without tests/lib keeps the pair its caller pinned.
_run_all_fixture_pins_inherited() {
  [ ! -f "$RUN_ALL_LAUNCH_DIR/../../tests/lib/test-run-root.sh" ] &&
    [ ! -f "$RUN_ALL_LAUNCH_DIR/../../tests/lib/command-guard.sh" ] &&
    [ -n "${TEST_RUN_ROOT:-}" ] && [ -d "$TEST_RUN_ROOT" ] &&
    [ -n "${COMMAND_GUARD_DIR:-}" ] && [ -f "$COMMAND_GUARD_DIR/guard.conf" ]
}

# run_all_pin_test_env <root> — carries RUN_TL3 / RUN_TL4 over from the real settings (a value
# already in the environment wins), then pins the root decoy, <root> as the run root, the command
# guard, the state dirs under <root>, and worktree change detection.
run_all_pin_test_env() {
  local key
  local -a carried=()
  for key in $_RUN_ALL_CARRIED_KEYS; do
    if [ -n "${!key+x}" ]; then carried+=("${!key}"); else carried+=("$(_run_all_real_setting "$key")"); fi
  done
  run_all_pin_root_decoy || return 1
  for key in $_RUN_ALL_CARRIED_KEYS; do
    if [ -n "${carried[0]}" ]; then export "$key=${carried[0]}"; fi
    carried=("${carried[@]:1}")
  done
  if ! _run_all_fixture_pins_inherited; then
    [ -n "${1:-}" ] && declare -F test_run_root_ensure >/dev/null 2>&1 || return 1
    export TEST_RUN_ROOT="$1"
    test_run_root_ensure || return 1
    run_all_pin_command_guard || return 1
  fi
  run_all_pin_state_dirs "${1:-}" || return 1
  _RUN_ALL_DECOY_SINCE="${WORKFLOW_STATE_DIR%/workflow}/root-decoy-since"
  : >"$_RUN_ALL_DECOY_SINCE" || return 1
  if declare -F run_all_pin_worktree_change_detect >/dev/null 2>&1; then
    run_all_pin_worktree_change_detect "$1/worktree-change.log" || return 1
  fi
  if declare -F run_all_worktree_change_begin >/dev/null 2>&1; then
    run_all_worktree_change_begin
    declare -F _run_all_wcd_write_slot_before >/dev/null 2>&1 && _run_all_wcd_write_slot_before
  fi
  # tests/run-all.sh reports a hit itself before it prints its counts; this teardown wrapper
  # covers the exits that never get there (deadline, signal), and the report runs only once.
  if declare -F cleanup_all >/dev/null 2>&1 && ! declare -F _run_all_cleanup_all_inner >/dev/null 2>&1; then
    eval "_run_all_cleanup_all_inner ()"$'\n'"$(declare -f cleanup_all | tail -n +2)"
    # shellcheck disable=SC2317
    cleanup_all() {
      if declare -F run_all_hit_report >/dev/null 2>&1; then run_all_hit_report || true; fi
      _run_all_cleanup_all_inner
    }
  fi
  return 0
}

# The loader keys its cache by its own CLI path, so sourcing this checkout's loader makes
# tlr_load re-read this checkout's table even when the caller loaded another checkout's.
for _rae_lib in test-language-registry.sh run-all-classify.sh timed-exec.sh; do
  # shellcheck source=/dev/null
  if [ -f "$RUN_ALL_LAUNCH_DIR/$_rae_lib" ]; then . "$RUN_ALL_LAUNCH_DIR/$_rae_lib"; fi
done
unset _rae_lib

# _rae_native <path> — the mixed (C:/...) form Windows-native tools and Node accept, into _RAE_N.
_rae_native() {
  _RAE_N="$1"
  if command -v cygpath >/dev/null 2>&1; then _RAE_N="$(cygpath -m "$1")"; fi
}

# _rae_sub <text> <token> <value> — literal replace-all into _RAE_S (no pattern or & semantics).
_rae_sub() {
  local s="$1" out=""
  while [[ "$s" == *"$2"* ]]; do
    out="$out${s%%"$2"*}$3"
    s="${s#*"$2"}"
  done
  _RAE_S="$out$s"
}

# _rae_argv <id> <prepare|command> <path> <native> <wrapper> <minVersion> — the argv into _RAE_ARGV.
_rae_argv() {
  local i=0 q sq="$4"
  _RAE_ARGV=()
  # PowerShell closes a '...' string at ASCII ' and at U+2018..U+201B alike; doubling escapes each.
  for q in "'" $'\xe2\x80\x98' $'\xe2\x80\x99' $'\xe2\x80\x9a' $'\xe2\x80\x9b'; do sq="${sq//$q/$q$q}"; done
  while [ "$i" -lt "${#_TLR_A_ID[@]}" ]; do
    if [ "${_TLR_A_ID[$i]}" = "$1" ] && [ "${_TLR_A_KIND[$i]}" = "$2" ]; then
      _rae_sub "${_TLR_A_VAL[$i]}" '{nativePathSq}' "$sq"
      _rae_sub "$_RAE_S" '{nativePath}' "$4"
      _rae_sub "$_RAE_S" '{path}' "$3"
      _rae_sub "$_RAE_S" '{wrapper}' "$5"
      _rae_sub "$_RAE_S" '{minVersion}' "$6"
      _RAE_ARGV+=("$_RAE_S")
    fi
    i=$((i + 1))
  done
}

# _rae_timed <dir> <secs> <cmd...> — timed_exec (its firing marked in <dir>), or the bare command.
_rae_timed() {
  local dir="$1" secs="$2"
  shift 2
  if [[ "$secs" =~ ^[1-9][0-9]*$ ]]; then timed_exec --fired-file "$dir/timed-out" "$secs" "$@"; else "$@"; fi
}

# _rae_launch <owner> <out> <err> <resultdir> <unit> <eff> <root> — the child, in a subshell so the
# result-dir env and the suite's cd never reach the caller.
_rae_launch() {
  local owner="$1" out="$2" err="$3" dir="$4" unit="$5" eff="$6" root="$7" p0 rc
  (
    _rae_native "$dir"
    export RUN_ALL_RESULT_DIR="$_RAE_N" RUN_ALL_RESULT_OWNER="$owner"
    # Redirect before cd so a relative <out>/<err> still names the caller's file.
    exec >"$out" 2>"$err" </dev/null
    if [ "$unit" = suite ]; then cd "$root" || exit 2; fi
    # prepare belongs to the entry, not to the unit: a file entry runs it too, before each file.
    if [ "${#_RAE_PREP[@]}" -gt 0 ]; then
      p0=$SECONDS
      rc=0
      _rae_timed "$dir" "$eff" "${_RAE_PREP[@]}" || rc=$?
      if [ "$rc" -ne 0 ]; then
        if [ ! -e "$dir/timed-out" ]; then : >"$dir/prepare-failed"; fi
        exit "$rc"
      fi
      # One limit covers the unit: the command gets what prepare left of it.
      if [[ "$eff" =~ ^[1-9][0-9]*$ ]]; then
        eff=$((eff - (SECONDS - p0)))
        if [ "$eff" -lt 1 ]; then
          : >"$dir/timed-out"
          exit 124
        fi
      fi
    fi
    _rae_timed "$dir" "$eff" "${_RAE_CMD[@]}"
  )
}

# A test the launcher could not even set up was not run: FAIL, never UNSUPPORTED (which a run ignores).
_rae_setup_failed() {
  # shellcheck disable=SC2034 # read by the sourcing caller
  RUN_ALL_EXEC_STATE=FAIL RUN_ALL_EXEC_RC=2
  return 2
}

run_all_exec() {
  local rc=0
  declare -F run_all_worktree_change_begin >/dev/null 2>&1 && run_all_worktree_change_begin
  _run_all_exec_inner "$@" || rc=$?
  declare -F run_all_worktree_change_check >/dev/null 2>&1 && run_all_worktree_change_check "$1"
  # Last, so a record from a process that outlived the test is caught here rather than late.
  if declare -F _run_all_claim_hits >/dev/null 2>&1; then _run_all_claim_hits "$1" "$3"; fi
  return "$rc"
}

_run_all_exec_inner() {
  # shellcheck disable=SC2034 # RAC_LABELS: set by rac_entry_labels, read by rac_classify
  local script="$1" out="$2" err="$3" dir="${4:-}" tmpdir="" id unit root="" wrap="" minv="" rc=0 lpath RAC_LABELS
  RUN_ALL_EXEC_LAUNCHED=0
  # shellcheck disable=SC2034 # read by the sourcing caller
  RUN_ALL_EXEC_STATE=UNSUPPORTED RUN_ALL_EXEC_RC=78 RUN_ALL_EXEC_MISSING=""
  if [ -n "$_RUN_ALL_DECOY_RUN" ]; then local -x ROOT_DECOY_TEST_ID="$_RUN_ALL_DECOY_RUN:$script"; fi
  if ! declare -F tlr_load >/dev/null 2>&1 || ! declare -F rac_classify >/dev/null 2>&1 || ! declare -F timed_exec >/dev/null 2>&1; then
    printf '[run-all-launch] launcher libraries not found beside %s\n' "$RUN_ALL_LAUNCH_DIR" >&2
    _rae_setup_failed
    return
  fi
  tlr_load || { _rae_setup_failed; return; }
  if ! tlr_match "$script" || [ "$TLR_STATUS" != supported ]; then
    printf 'UNSUPPORTED: %s (language: %s; not run)\n' "$script" "${TLR_ID:-unknown}" >"$out"
    return 78
  fi
  id="$TLR_ID"
  _tlr_get "$id" launch.unit || true
  unit="$_TLR_V"
  if [ "$unit" = suite ] && ! root="$(tlr_suite_root "$id" "$script")"; then
    _tlr_get "$id" launch.suiteRootMarker || true
    printf 'UNSUPPORTED: %s (language: %s; no suite root %s)\n' "$script" "$id" "$_TLR_V" >"$out"
    return 78
  fi
  if [ -z "$dir" ]; then
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/run-all-result.XXXXXX")" || { _rae_setup_failed; return; }
    dir="$tmpdir"
  fi
  if _tlr_get "$id" launch.wrapper; then
    _rae_native "$(cd "$RUN_ALL_LAUNCH_DIR/../.." && pwd)/$_TLR_V"
    wrap="$_RAE_N"
  fi
  if _tlr_get "$id" launch.minVersion; then minv="${_TLR_V##*>=}"; fi
  # A relative path starting with '-' would read as an option to the runtime (and to cygpath).
  lpath="$script"
  case "$lpath" in -*) lpath="./$lpath" ;; esac
  _rae_native "$lpath"
  _rae_argv "$id" prepare "$lpath" "$_RAE_N" "$wrap" "$minv"
  _RAE_PREP=(${_RAE_ARGV[@]+"${_RAE_ARGV[@]}"})
  _rae_argv "$id" command "$lpath" "$_RAE_N" "$wrap" "$minv"
  _RAE_CMD=(${_RAE_ARGV[@]+"${_RAE_ARGV[@]}"})
  if rac_missing_exe "$id" "$unit" "$root" "${_RAE_PREP[0]:-}" "${_RAE_CMD[0]:-}"; then
    printf '%s\n' "$RAC_MISSING" >"$dir/unrunnable"
    printf 'UNRUNNABLE: missing %s\n' "$RAC_MISSING" >"$out"
    rc=79
  else
    _tlr_get "$id" launch.timeoutSeconds || _TLR_V=""
    rac_effective_timeout "$_TLR_V"
    RUN_ALL_EXEC_LAUNCHED=1
    # The owner is the path as launched: the harness compares it with its own $0.
    _rae_launch "$lpath" "$out" "$err" "$dir" "$unit" "$RAC_EFFECTIVE_TIMEOUT" "$root" || rc=$?
    # A failed prepare never started the command: not launched, though still a FAIL (D3-4).
    if [ -f "$dir/prepare-failed" ]; then RUN_ALL_EXEC_LAUNCHED=0; fi
  fi
  rac_entry_labels "$id" "$RUN_ALL_EXEC_LAUNCHED"
  rac_classify "$rc" "$RUN_ALL_EXEC_LAUNCHED" "$dir"
  if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
  return "$RUN_ALL_EXEC_RC"
}
