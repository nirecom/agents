# shellcheck shell=bash
# bin/lib/test-retire-predicate/case-state-rules.sh — source-only; not executable.
# The shared state rules trp_marker_state_from_globals applies to the globals any test case
# reader leaves (bash parser or a bridged reader child), so every language gets one verdict.

# _trp_reject_case_globals <line> <reason> — makes the file malformed and empties the case arrays.
_trp_reject_case_globals() {
  _TRP_MARKER_MALFORMED=1
  _TRP_MARKER_MALFORMED_LINE="$1"
  _TRP_MARKER_MALFORMED_REASON="$2"
  TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_NAMES=(); TRP_CASE_TARGETS=()
  # shellcheck disable=SC2034  # TRP_CASE_COUNT is read by the sourcing callers
  TRP_CASE_COUNT=0
}

# _trp_reject_record_delimiters — when a marked, not yet malformed file has a case whose name or
# target holds a TAB, CR or LF (a record delimiter), makes it malformed (grammar) on the first
# such case's begin line and empties the case arrays.
_trp_reject_record_delimiters() {
  [[ "${_TRP_MARKER_MALFORMED:-0}" -eq 0 && "${TRP_HAS_MARKERS:-0}" -eq 1 ]] || return 0
  # Read the globals in place: Git Bash drops a CR when an array literal copies them.
  local i v n="${#TRP_CASE_NAMES[@]}"
  for ((i = 0; i < n; i++)); do
    v="${TRP_CASE_NAMES[$i]}${TRP_CASE_TARGETS[$i]:-}"
    if [[ "$v" == *$'\t'* || "$v" == *$'\r'* || "$v" == *$'\n'* ]]; then
      _trp_reject_case_globals "${TRP_CASE_BEGIN_LINES[$i]:-}" grammar
      return 0
    fi
  done
  return 0
}

# _trp_reject_duplicate_names — when a marked, not yet malformed file has two cases of one name,
# makes it malformed (duplicate-name) on the later case's begin line and empties the case arrays.
_trp_reject_duplicate_names() {
  [[ "${_TRP_MARKER_MALFORMED:-0}" -eq 0 && "${TRP_HAS_MARKERS:-0}" -eq 1 ]] || return 0
  local -A seen=()
  local -a names=(${TRP_CASE_NAMES[@]+"${TRP_CASE_NAMES[@]}"})
  local -a begins=(${TRP_CASE_BEGIN_LINES[@]+"${TRP_CASE_BEGIN_LINES[@]}"})
  local i key
  for i in "${!names[@]}"; do
    key="k${names[$i]}"
    if [[ -n "${seen[$key]+x}" ]]; then
      _trp_reject_case_globals "${begins[$i]:-}" duplicate-name
      return 0
    fi
    seen[$key]=1
  done
  return 0
}
