# shellcheck shell=bash
# bin/lib/run-all-hits.sh — the hit lifecycle of tests/run-all.sh; sourced by bin/lib/run-all-launch.sh.
#   _run_all_claim_hits <script> <err>  right after one test: its own guard / decoy records become its
#                                       FAIL (detail lines into <err>, RUN_ALL_EXEC_HITS=n).
#   run_all_hit_collect                 once, at the end: records left over with this run's test id go to
#                                       RUN_ALL_LATE_IDS; the rest and every worktree change go to
#                                       RUN_ALL_HITS / RUN_ALL_HIT_LINES (applied by rar_hits).
#   run_all_hit_report                  the collect, non-zero when it found any hit (test-jail, the base run).
# Design: docs/architecture/claude-code/test-command-guard.md

RUN_ALL_HITS=0
RUN_ALL_HIT_LINES=()
RUN_ALL_LATE_IDS=()
RUN_ALL_LATE_LINES=()
_RUN_ALL_GUARD_REPORTED=0
_RUN_ALL_DECOY_REPORTED=0
_RUN_ALL_HITS_REPORTED=0

# _run_all_guard_hit_line <stub> <id> <target> — the guard detail line, this run's token stripped.
_run_all_guard_hit_line() {
  local id="$2"
  [ -n "${_RUN_ALL_DECOY_RUN:-}" ] && id="${id#"$_RUN_ALL_DECOY_RUN":}"
  printf '[run-all] command guard hit: %s\t%s\t%s\n' "$1" "${id:-(no test id)}" "$3"
}

# _run_all_decoy_hit_line <tree> <stub> <id> — the root decoy detail line.
_run_all_decoy_hit_line() {
  printf '[run-all] root decoy hit: %s/%s\t%s\n' "$1" "$2" "$3"
}

# _run_all_decoy_fields <file> — _RA_STUB / _RA_ID from one decoy record; _RA_HAS_ID=1 once its
# test_id line is written (a record still being written has none and is left alone).
_run_all_decoy_fields() {
  local line
  _RA_STUB="" _RA_ID="" _RA_HAS_ID=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      stub=*) _RA_STUB="${line#stub=}" ;;
      test_id=*) _RA_ID="${line#test_id=}" _RA_HAS_ID=1 ;;
    esac
  done <"$1"
}

_run_all_claim_hits() {
  local key="${_RUN_ALL_DECOY_RUN:-}:$1" err="$2" f tree n=0
  RUN_ALL_EXEC_HITS=0
  [ -n "${_RUN_ALL_DECOY_RUN:-}" ] || return 0
  if [ -n "${_RUN_ALL_GUARD_DIR:-}" ] && declare -F command_guard_hit_fields >/dev/null 2>&1; then
    for f in "$_RUN_ALL_GUARD_DIR"/hits/*.hit; do
      [ -f "$f" ] || continue
      command_guard_hit_fields "$f"
      [ "$_CG_HIT_ID" = "$key" ] || continue
      _run_all_guard_hit_line "$_CG_HIT_STUB" "$_CG_HIT_ID" "$_CG_HIT_TARGET" >>"$err"
      # Renamed, not removed: the record stays for a post-mortem, but no *.hit glob counts it again.
      mv -f "$f" "$f.claimed" 2>/dev/null || rm -f "$f"
      n=$((n + 1))
    done
  fi
  if [ -n "${ROOT_DECOY_DIR:-}" ]; then
    for tree in main old; do
      for f in "$ROOT_DECOY_DIR/$tree"/hits/*.hit; do
        [ -f "$f" ] || continue
        _run_all_decoy_fields "$f"
        [ "$_RA_HAS_ID" = 1 ] && [ "$_RA_ID" = "$key" ] || continue
        _run_all_decoy_hit_line "$tree" "$_RA_STUB" "$_RA_ID" >>"$err"
        rm -f "$f"
        n=$((n + 1))
      done
    done
  fi
  [ "$n" -gt 0 ] || return 0
  # shellcheck disable=SC2034  # read by the sourcing caller (bin/lib/run-tests-baseline-exec.sh)
  RUN_ALL_EXEC_HITS=$n
  # A FAIL or TIMEOUT is already one named failure; anything else becomes one, its rc kept.
  case "${RUN_ALL_EXEC_STATE:-}" in FAIL | TIMEOUT) ;; *) RUN_ALL_EXEC_STATE=FAIL ;; esac
  return 0
}

# _run_all_hit_late <script> <hit line> — one entry per test id, however many records it left.
_run_all_hit_late() {
  local s
  for s in ${RUN_ALL_LATE_IDS[@]+"${RUN_ALL_LATE_IDS[@]}"}; do
    [ "$s" = "$1" ] && return 0
  done
  RUN_ALL_LATE_IDS+=("$1")
  RUN_ALL_LATE_LINES+=("$2")
}

_run_all_hit_unattributed() {
  RUN_ALL_HITS=$((RUN_ALL_HITS + 1))
  RUN_ALL_HIT_LINES+=("$1")
}

# run_all_command_guard_report — the guard records nobody claimed: a detail line each on stderr,
# then late (this run's test id, renamed) or unattributed. Non-zero when there was one. Runs once.
run_all_command_guard_report() {
  local f id n=0
  [ "$_RUN_ALL_GUARD_REPORTED" -eq 0 ] || return 0
  _RUN_ALL_GUARD_REPORTED=1
  [ -n "${_RUN_ALL_GUARD_DIR:-}" ] && declare -F command_guard_hit_fields >/dev/null 2>&1 || return 0
  for f in "$_RUN_ALL_GUARD_DIR"/hits/*.hit; do
    [ -f "$f" ] || continue
    command_guard_hit_fields "$f"
    [ -n "$_CG_HIT_STUB" ] || continue
    n=$((n + 1))
    _run_all_guard_hit_line "$_CG_HIT_STUB" "$_CG_HIT_ID" "$_CG_HIT_TARGET" >&2
    id="$_CG_HIT_ID"
    if [ -n "${_RUN_ALL_DECOY_RUN:-}" ] && [ "${id#"$_RUN_ALL_DECOY_RUN":}" != "$id" ]; then
      id="${id#"$_RUN_ALL_DECOY_RUN":}"
      _run_all_hit_late "$id" "command-guard $id $_CG_HIT_STUB${_CG_HIT_TARGET:+ $_CG_HIT_TARGET}"
      mv -f "$f" "$f.claimed" 2>/dev/null || rm -f "$f"
    else
      _run_all_hit_unattributed "command-guard ${id:-(no test id)} $_CG_HIT_STUB${_CG_HIT_TARGET:+ $_CG_HIT_TARGET}"
    fi
  done
  [ "$n" -eq 0 ] && return 0
  printf '[run-all] %s command guard hit(s): a test ran a command the guard refused; the run fails\n' "$n" >&2
  return 1
}

# run_all_root_decoy_report — the decoy records of this run nobody claimed (late, removed) and those
# without a test id newer than this run's pin (a child with a stripped environment cannot say whose
# it is; unattributed). Another run's records are skipped. Non-zero when there was one. Runs once.
run_all_root_decoy_report() {
  local tree f n=0
  [ "$_RUN_ALL_DECOY_REPORTED" -eq 0 ] || return 0
  _RUN_ALL_DECOY_REPORTED=1
  [ -n "${_RUN_ALL_DECOY_RUN:-}" ] && [ -n "${ROOT_DECOY_DIR:-}" ] || return 0
  for tree in main old; do
    for f in "$ROOT_DECOY_DIR/$tree"/hits/*.hit; do
      [ -f "$f" ] || continue
      _run_all_decoy_fields "$f"
      [ "$_RA_HAS_ID" = 1 ] || continue
      case "$_RA_ID" in
        "$_RUN_ALL_DECOY_RUN":*)
          _run_all_hit_late "${_RA_ID#"$_RUN_ALL_DECOY_RUN":}" "root-decoy ${_RA_ID#"$_RUN_ALL_DECOY_RUN":} $tree/$_RA_STUB"
          rm -f "$f" ;;
        "")
          [ -n "${_RUN_ALL_DECOY_SINCE:-}" ] && [ "$f" -nt "$_RUN_ALL_DECOY_SINCE" ] || continue
          _RA_ID="(no test id)"
          _run_all_hit_unattributed "root-decoy (no test id) $tree/$_RA_STUB" ;;
        *) continue ;;
      esac
      n=$((n + 1))
      _run_all_decoy_hit_line "$tree" "$_RA_STUB" "$_RA_ID" >&2
    done
  done
  [ "$n" -eq 0 ] && return 0
  printf '[run-all] %s root decoy hit(s): a test reached a root it must not use; the run fails\n' "$n" >&2
  return 1
}

# _run_all_wcd_hits — one unattributed hit per logged worktree change (tests run alongside each
# other, so a change is never one test's FAIL), after the change report's own stderr lines.
_run_all_wcd_hits() {
  local rc=0 tree id kind paths
  declare -F run_all_worktree_change_report >/dev/null 2>&1 || return 0
  run_all_worktree_change_report || rc=1
  [ -n "${_RUN_ALL_WCD_LOG:-}" ] && [ -s "$_RUN_ALL_WCD_LOG" ] || return "$rc"
  while IFS=$'\t' read -r tree id kind paths || [ -n "$tree" ]; do
    [ -n "$tree" ] || continue
    _run_all_hit_unattributed "worktree-change $id tree=$tree kind=${kind%$'\r'}${paths:+ paths=${paths%$'\r'}}"
  done <"$_RUN_ALL_WCD_LOG"
  return "$rc"
}

run_all_hit_collect() {
  [ "$_RUN_ALL_HITS_REPORTED" -eq 0 ] || return 0
  _RUN_ALL_HITS_REPORTED=1
  run_all_root_decoy_report || true
  run_all_command_guard_report || true
  _run_all_wcd_hits || true
  return 0
}

# Only the call that collects judges: a repeat in the same run is silent and returns 0.
run_all_hit_report() {
  [ "$_RUN_ALL_HITS_REPORTED" -eq 0 ] || return 0
  run_all_hit_collect
  [ "${#RUN_ALL_LATE_IDS[@]}" -eq 0 ] && [ "$RUN_ALL_HITS" -eq 0 ]
}
