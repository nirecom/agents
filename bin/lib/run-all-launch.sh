#!/usr/bin/env bash
# Launch helpers for tests/run-all.sh; sourced, never executed.
# run_all_exec <script> <out> <err> — launch one test the way its test-language registry entry
# says (launch.unit / requires / prepare / command / timeoutSeconds), reading the table that sits
# beside this file. Returns the child rc; 77 (SKIP) when launch.requires is not on PATH; 78 when
# not launched (no supported entry matches, or a suite has no root); 2 when no table is readable.
# Sets RUN_ALL_EXEC_LAUNCHED to 1 when a process was started, else 0.
# run_all_pin_test_env <root> — the per-run pins: carried settings, root decoy
# (run_all_pin_root_decoy), state dirs (run_all_pin_state_dirs); each is described at its function.
# Contract: docs/architecture/claude-code/test-runner-parallelism.md.

case "${BASH_SOURCE[0]}" in
  */*) RUN_ALL_LAUNCH_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RUN_ALL_LAUNCH_DIR="." ;;
esac

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
_RUN_ALL_DECOY_REPORTED=0
_RUN_ALL_CARRIED_KEYS="RUN_TL3 RUN_TL4"

# run_all_pin_root_decoy — points AGENTS_MAIN_ROOT and the retired root names at the stub trees
# of tests/lib/root-decoy.sh; non-zero (nothing switched) when the decoy is unavailable.
run_all_pin_root_decoy() {
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

# run_all_pin_test_env <root> — carries RUN_TL3 / RUN_TL4 over from the real settings (a value
# already in the environment wins), then pins the root decoy and the state dirs under <root>.
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
  run_all_pin_state_dirs "${1:-}" || return 1
  _RUN_ALL_DECOY_SINCE="${WORKFLOW_STATE_DIR%/workflow}/root-decoy-since"
  : >"$_RUN_ALL_DECOY_SINCE" || return 1
  # tests/run-all.sh is at its line limit, so the hit report rides on its teardown: a hit
  # raises its FAIL count before the exit status is decided.
  if declare -F cleanup_all >/dev/null 2>&1 && ! declare -F _run_all_cleanup_all_inner >/dev/null 2>&1; then
    eval "_run_all_cleanup_all_inner ()"$'\n'"$(declare -f cleanup_all | tail -n +2)"
    # shellcheck disable=SC2034,SC2317  # FAIL belongs to tests/run-all.sh.
    cleanup_all() {
      run_all_root_decoy_report || FAIL=$((${FAIL:-0} + 1))
      _run_all_cleanup_all_inner
    }
  fi
  return 0
}

# run_all_root_decoy_report — one stderr line per stub this run reached ("<stub><TAB><test id>"),
# then removes those records. Non-zero when there was a hit. A record without a test id counts
# when it is newer than this run's pin: a child with a stripped environment cannot say whose it is.
run_all_root_decoy_report() {
  local tree f line stub id n=0 mine
  [ "$_RUN_ALL_DECOY_REPORTED" -eq 0 ] || return 0
  _RUN_ALL_DECOY_REPORTED=1
  [ -n "$_RUN_ALL_DECOY_RUN" ] && [ -n "${ROOT_DECOY_DIR:-}" ] || return 0
  for tree in main old; do
    for f in "$ROOT_DECOY_DIR/$tree"/hits/*.hit; do
      [ -f "$f" ] || continue
      stub=""; mine=0
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
          stub=*) stub="${line#stub=}" ;;
          test_id=*)
            id="${line#test_id=}"
            case "$id" in
              "$_RUN_ALL_DECOY_RUN":*) mine=1 ;;
              "") [ -n "$_RUN_ALL_DECOY_SINCE" ] && [ "$f" -nt "$_RUN_ALL_DECOY_SINCE" ] || continue
                  id="(no test id)" ;;
              *) continue ;;
            esac
            n=$((n + 1))
            printf '[run-all] root decoy hit: %s/%s\t%s\n' "$tree" "$stub" "$id" >&2 ;;
        esac
      done <"$f"
      [ "$mine" -eq 1 ] && rm -f "$f"
    done
  done
  [ "$n" -eq 0 ] && return 0
  printf '[run-all] %s root decoy hit(s): a test reached a root it must not use; the run fails\n' "$n" >&2
  return 1
}

# The loader keys its cache by its own CLI path, so sourcing this checkout's loader makes
# tlr_load re-read this checkout's table even when the caller loaded another checkout's.
if [ -f "$RUN_ALL_LAUNCH_DIR/test-language-registry.sh" ]; then
  # shellcheck source=bin/lib/test-language-registry.sh
  . "$RUN_ALL_LAUNCH_DIR/test-language-registry.sh"
fi

# _rae_sub <text> <token> <value> — literal replace-all into _RAE_S (no pattern or & semantics).
_rae_sub() {
  local s="$1" out=""
  while [[ "$s" == *"$2"* ]]; do
    out="$out${s%%"$2"*}$3"
    s="${s#*"$2"}"
  done
  _RAE_S="$out$s"
}

# _rae_argv <id> <prepare|command> <path> <native> — the entry's argv into _RAE_ARGV.
_rae_argv() {
  local i=0 q="'"
  _RAE_ARGV=()
  while [ "$i" -lt "${#_TLR_A_ID[@]}" ]; do
    if [ "${_TLR_A_ID[$i]}" = "$1" ] && [ "${_TLR_A_KIND[$i]}" = "$2" ]; then
      _rae_sub "${_TLR_A_VAL[$i]}" '{nativePathSq}' "${4//$q/$q$q}"
      _rae_sub "$_RAE_S" '{nativePath}' "$4"
      _rae_sub "$_RAE_S" '{path}' "$3"
      _RAE_ARGV+=("$_RAE_S")
    fi
    i=$((i + 1))
  done
}

run_all_exec() {
  local script="$1" out="$2" err="$3" id native root rc=0 rto
  local -a tmo=() prep=() cmd=()
  RUN_ALL_EXEC_LAUNCHED=0
  if [ -n "$_RUN_ALL_DECOY_RUN" ]; then local -x ROOT_DECOY_TEST_ID="$_RUN_ALL_DECOY_RUN:$script"; fi
  if ! declare -F tlr_load >/dev/null 2>&1; then
    printf '[run-all-launch] test language registry loader not found beside %s\n' "$RUN_ALL_LAUNCH_DIR" >&2
    return 2
  fi
  tlr_load || return 2
  if ! tlr_match "$script" || [ "$TLR_STATUS" != supported ]; then
    printf 'UNSUPPORTED: %s (language: %s; not run)\n' "$script" "${TLR_ID:-unknown}" >"$out"
    return 78
  fi
  id="$TLR_ID"
  if _tlr_get "$id" launch.requires && ! command -v "$_TLR_V" >/dev/null 2>&1; then
    printf 'SKIP: %s not on PATH\n' "$_TLR_V" >"$out"
    return 77
  fi
  rto="$RUN_ALL_LAUNCH_DIR/../run-with-timeout.sh"
  if _tlr_get "$id" launch.timeoutSeconds && [ -f "$rto" ]; then tmo=(bash "$rto" "$_TLR_V"); fi
  native="$script"
  command -v cygpath >/dev/null 2>&1 && native="$(cygpath -m "$script")"
  _rae_argv "$id" prepare "$script" "$native"
  prep=(${_RAE_ARGV[@]+"${_RAE_ARGV[@]}"})
  _rae_argv "$id" command "$script" "$native"
  cmd=(${_RAE_ARGV[@]+"${_RAE_ARGV[@]}"})
  _tlr_get "$id" launch.unit || true
  if [ "$_TLR_V" != suite ]; then
    RUN_ALL_EXEC_LAUNCHED=1
    ${tmo[@]+"${tmo[@]}"} "${cmd[@]}" >"$out" 2>"$err" </dev/null
    return
  fi
  if ! root="$(tlr_suite_root "$id" "$script")"; then
    _tlr_get "$id" launch.suiteRootMarker || true
    printf 'UNSUPPORTED: %s (language: %s; no suite root %s)\n' "$script" "$id" "$_TLR_V" >"$out"
    return 78
  fi
  RUN_ALL_EXEC_LAUNCHED=1
  # Redirect before cd so a relative <out>/<err> still names the caller's file.
  (
    exec >"$out" 2>"$err" </dev/null
    cd "$root" || exit 2
    if [ "${#prep[@]}" -gt 0 ]; then
      ${tmo[@]+"${tmo[@]}"} "${prep[@]}" || exit
    fi
    ${tmo[@]+"${tmo[@]}"} "${cmd[@]}"
  ) || rc=$?
  return "$rc"
}
