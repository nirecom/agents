#!/usr/bin/env bash
# run_all_exec <script> <out> <err> — launch one test the way its test-language registry entry
# says (launch.unit / requires / prepare / command / timeoutSeconds), reading the table that sits
# beside this file. Returns the child rc; 77 (SKIP) when launch.requires is not on PATH; 78 when
# not launched (no supported entry matches, or a suite has no root); 2 when no table is readable.
# Sets RUN_ALL_EXEC_LAUNCHED to 1 when a process was started, else 0.
# Contract: docs/architecture/claude-code/test-runner-parallelism.md.

case "${BASH_SOURCE[0]}" in
  */*) RUN_ALL_LAUNCH_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RUN_ALL_LAUNCH_DIR="." ;;
esac

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
