# shellcheck shell=bash disable=SC2034
# bin/lib/run-all-classify.sh — one test file's outcome; source only, needs nothing at source time.
# rac_classify <rc> <launched> <resultdir> sets RUN_ALL_EXEC_STATE (PASS|FAIL|SKIP|TIMEOUT|UNSUPPORTED|
#   UNRUNNABLE), RUN_ALL_EXEC_RC and RUN_ALL_EXEC_MISSING. rc 79 is UNRUNNABLE only when <resultdir>/unrunnable
#   holds exactly one of RAC_LABELS (the launcher sets its entry's; left unset, every entry's count).
# rac_entry_labels <id> [<launched>] sets RAC_LABELS (valid labels: docs/architecture/claude-code/test-result-contract.md).
# rac_effective_timeout <entry-timeout> sets RAC_EFFECTIVE_TIMEOUT: the entry value (empty when it is
#   not a positive integer), capped by a positive-integer RUN_ALL_TIMEOUT_SECONDS; empty = no per-file kill.
# rac_missing_exe <id> <unit> <root> <exe>... sets RAC_MISSING: the first of launch.requires and <exe>... not on PATH (from <root> for a suite).

case "${BASH_SOURCE[0]}" in
  */*) _RAC_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _RAC_DIR="." ;;
esac

# _rac_resolved <cases.tsv> — counts the resolved records (the last line of each seq, OPEN left out)
# into _RAC_N, with the SKIP and FAIL ones in _RAC_SKIP and _RAC_FAIL. Only the bash harness writes
# OPEN, and its XPASS is a failure (tests/lib/xfail.sh raises FAIL), so an XPASS on a seq that was
# opened counts in _RAC_FAIL; a wrapper's XPASS (pytest, non-strict) has no OPEN and stays a pass.
_rac_resolved() {
  local f="$1" seq st rest i
  local -a seqs=() states=() opened=() at=()
  _RAC_N=0 _RAC_SKIP=0 _RAC_FAIL=0
  [ -s "$f" ] || return 0
  while IFS=$'\t' read -r seq st rest; do
    [ -n "$seq" ] || continue
    # Every writer numbers its cases, so a seq is its own index; the scan is for anything else.
    if [[ "$seq" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
      i="${at[seq]:-${#seqs[@]}}"
      at[seq]=$i
    else
      for ((i = 0; i < ${#seqs[@]}; i++)); do
        if [[ "${seqs[i]}" == "$seq" ]]; then break; fi
      done
    fi
    seqs[i]="$seq"
    states[i]="$st"
    if [[ "$st" == OPEN ]]; then opened[i]=1; fi
  done <"$f"
  for ((i = 0; i < ${#states[@]}; i++)); do
    case "${states[i]}" in
      OPEN) ;;
      SKIP) _RAC_N=$((_RAC_N + 1)) _RAC_SKIP=$((_RAC_SKIP + 1)) ;;
      FAIL) _RAC_N=$((_RAC_N + 1)) _RAC_FAIL=$((_RAC_FAIL + 1)) ;;
      XPASS) _RAC_N=$((_RAC_N + 1)) _RAC_FAIL=$((_RAC_FAIL + ${opened[i]:-0})) ;;
      *) _RAC_N=$((_RAC_N + 1)) ;;
    esac
  done
  return 0
}

rac_entry_labels() {
  local i seen=""
  RAC_LABELS=""
  # A launched child is a wrapper reporting an unmet version floor; a missing executable is the
  # launcher's own finding, so no test code can claim one (a bash test naming `bash`).
  if [ "${2:-0}" = 1 ]; then
    if _tlr_get "$1" launch.minVersion; then RAC_LABELS="$_TLR_V"; fi
    return 0
  fi
  if _tlr_get "$1" launch.requires; then RAC_LABELS="$_TLR_V"; fi
  # The first word of launch.prepare and of launch.command is an executable the launch needs too.
  for ((i = 0; i < ${#_TLR_A_ID[@]}; i++)); do
    [ "${_TLR_A_ID[i]}" = "$1" ] || continue
    case " $seen " in *" ${_TLR_A_KIND[i]} "*) continue ;; esac
    seen="$seen ${_TLR_A_KIND[i]}"
    RAC_LABELS="$RAC_LABELS"$'\n'"${_TLR_A_VAL[i]}"
  done
}

_rac_has() {
  if [ "$2" != suite ]; then
    command -v "$1" >/dev/null 2>&1
    return
  fi
  (cd "$3" && command -v "$1" >/dev/null 2>&1)
}

rac_missing_exe() {
  local id="$1" unit="$2" root="$3" exe
  shift 3
  RAC_MISSING=""
  _tlr_get "$id" launch.requires || _TLR_V=""
  for exe in "$_TLR_V" "$@"; do
    if [ -n "$exe" ] && ! _rac_has "$exe" "$unit" "$root"; then
      RAC_MISSING="$exe"
      return 0
    fi
  done
  return 1
}

# _rac_all_labels <launched> — RAC_LABELS for every entry of the registry, loaded from this checkout when
# needed; only for a rac_classify caller that set no entry's RAC_LABELS.
_rac_all_labels() {
  local id all=""
  if ! declare -F tlr_load >/dev/null 2>&1; then
    # shellcheck source=bin/lib/test-language-registry.sh
    . "$_RAC_DIR/test-language-registry.sh" || return 1
  fi
  tlr_load || return 1
  for id in ${_TLR_E_ID[@]+"${_TLR_E_ID[@]}"}; do
    rac_entry_labels "$id" "${1:-0}"
    all="$all"$'\n'"$RAC_LABELS"
  done
  RAC_LABELS="$all"
}

# _rac_marker <resultdir> <labels> — RAC_MARKER when the marker file's whole content is one label.
_rac_marker() {
  local text="" label
  RAC_MARKER=""
  [ -f "$1/unrunnable" ] || return 1
  # read -d '' succeeds only when it stops at a NUL: bytes after it would go unread, so reject.
  if IFS= read -r -d '' text <"$1/unrunnable"; then return 1; fi
  text="${text%$'\n'}"
  text="${text%$'\r'}"
  [ -n "$text" ] || return 1
  while IFS= read -r label; do
    if [ -n "$label" ] && [ "$label" = "$text" ]; then
      RAC_MARKER="$label"
      return 0
    fi
  done <<<"$2"
  return 1
}

rac_classify() {
  local rc="$1" launched="$2" dir="$3"
  RUN_ALL_EXEC_MISSING=""
  if [[ "$rc" == 78 && "$launched" != 1 && ! -f "$dir/prepare-failed" ]]; then
    RUN_ALL_EXEC_STATE=UNSUPPORTED RUN_ALL_EXEC_RC=78
    return 0
  fi
  if [[ "$rc" == 79 && -f "$dir/unrunnable" ]] && { [ -n "${RAC_LABELS+x}" ] || _rac_all_labels "$launched"; } &&
    _rac_marker "$dir" "$RAC_LABELS"; then
    RUN_ALL_EXEC_STATE=UNRUNNABLE RUN_ALL_EXEC_RC=79 RUN_ALL_EXEC_MISSING="$RAC_MARKER"
    return 0
  fi
  # The command never started: a pass or skip rc is the prepare's, never the test's.
  if [ -f "$dir/prepare-failed" ]; then
    RUN_ALL_EXEC_STATE=FAIL RUN_ALL_EXEC_RC="$rc"
    if [[ "$rc" == 0 || "$rc" == 77 ]]; then RUN_ALL_EXEC_RC=1; fi
    return 0
  fi
  # Written only by timed_exec when its own timer fired; a child's own 124 is not a timeout.
  if [ -f "$dir/timed-out" ]; then
    RUN_ALL_EXEC_STATE=TIMEOUT RUN_ALL_EXEC_RC=124
    return 0
  fi
  if [[ "$rc" == 0 || "$rc" == 77 ]]; then
    _rac_resolved "$dir/cases.tsv"
    # The harness does not force a non-zero exit, so a recorded failure (FAIL, or its XPASS)
    # outranks the file's own rc 0, and its skip rc 77 alike.
    if [ "$_RAC_FAIL" -gt 0 ]; then
      RUN_ALL_EXEC_STATE=FAIL RUN_ALL_EXEC_RC=1
      return 0
    fi
    # UNOBSERVED (no assertion seen, e.g. deferred evaluation) counts as not skipped.
    if [[ "$rc" == 0 ]] && [ "$_RAC_N" -gt 0 ] && [ "$_RAC_N" -eq "$_RAC_SKIP" ]; then
      RUN_ALL_EXEC_STATE=SKIP RUN_ALL_EXEC_RC=77
      return 0
    fi
  fi
  case "$rc" in
    0) RUN_ALL_EXEC_STATE=PASS RUN_ALL_EXEC_RC=0 ;;
    77) RUN_ALL_EXEC_STATE=SKIP RUN_ALL_EXEC_RC=77 ;;
    *) RUN_ALL_EXEC_STATE=FAIL RUN_ALL_EXEC_RC="$rc" ;;
  esac
}

rac_effective_timeout() {
  local t="${1:-}" v="${RUN_ALL_TIMEOUT_SECONDS:-}"
  if [[ ! "$t" =~ ^[1-9][0-9]*$ ]]; then t=""; fi
  if [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
    if [[ -z "$t" ]] || [ "$v" -lt "$t" ]; then t="$v"; fi
  fi
  RAC_EFFECTIVE_TIMEOUT="$t"
}
