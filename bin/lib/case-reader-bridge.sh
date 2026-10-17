# shellcheck shell=bash
# shellcheck disable=SC2034  # the globals are read by the sourcing callers
# bin/lib/case-reader-bridge.sh — loads the records a case reader child process prints. Source only.
# crb_run <file> <command> [args...] runs `<command> [args...] <file>` and reads its stdout:
#   FILE\t<state>\t<line>\t<reason>                                  state: none|conforming|malformed|uncertain
#   CASE\t<idx>\t<name>\t<target>\t<begin>\t<end>\t<deps>\t<reason>      (conforming only, at least one; name and target non-empty)
# It sets the globals trp_parse_case_markers sets, so trp_marker_state_from_globals reads them.
# rc: 0 loaded, 79 <command> is not installed, 1 the child failed or broke the format above.

# crb_native_path <path> — sets CRB_PATH to the form a non-shell child process can open.
crb_native_path() {
  CRB_PATH="$1"
  if command -v cygpath >/dev/null 2>&1; then CRB_PATH="$(cygpath -m "$1")" || CRB_PATH="$1"; fi
}

# _crb_split <line> — the line's tab-separated columns into CRB_COL, empty columns kept.
_crb_split() {
  local rest="$1" tab=$'\t'
  CRB_COL=()
  while [[ "$rest" == *"$tab"* ]]; do
    CRB_COL+=("${rest%%"$tab"*}")
    rest="${rest#*"$tab"}"
  done
  CRB_COL+=("$rest")
}

crb_run() {
  local file="${1:?crb_run: file required}" out line state="" mline="" mreason="" files=0
  local -a names=() targets=() begins=() ends=()
  shift
  TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_NAMES=(); TRP_CASE_TARGETS=()
  TRP_CASE_COUNT=0; TRP_HAS_MARKERS=0
  _TRP_MARKER_MALFORMED=0; _TRP_MARKER_MALFORMED_LINE=""
  _TRP_MARKER_MALFORMED_REASON=""; _TRP_MARKER_UNCERTAIN=0
  command -v "${1:?crb_run: command required}" >/dev/null 2>&1 || return 79
  crb_native_path "$file"
  out="$("$@" "$CRB_PATH")" || return 1
  while IFS= read -r line; do
    _crb_split "${line%$'\r'}"
    case "${CRB_COL[0]}" in
      FILE)
        [[ "${#CRB_COL[@]}" -eq 4 ]] || return 1
        files=$((files + 1)); state="${CRB_COL[1]}"; mline="${CRB_COL[2]}"; mreason="${CRB_COL[3]}"
        ;;
      CASE)
        [[ "${#CRB_COL[@]}" -eq 8 && -n "${CRB_COL[2]}" && -n "${CRB_COL[3]}" ]] || return 1
        [[ "${CRB_COL[4]}" =~ ^[0-9]+$ && "${CRB_COL[5]}" =~ ^[0-9]+$ ]] || return 1
        names+=("${CRB_COL[2]}"); targets+=("${CRB_COL[3]}"); begins+=("${CRB_COL[4]}"); ends+=("${CRB_COL[5]}")
        ;;
      *) return 1 ;;
    esac
  done <<<"$out"
  [[ "$files" -eq 1 ]] || return 1
  case "$state" in
    none) [[ "${#names[@]}" -eq 0 ]] || return 1 ;;
    conforming)
      [[ "${#names[@]}" -gt 0 ]] || return 1
      TRP_HAS_MARKERS=1
      TRP_CASE_NAMES=(${names[@]+"${names[@]}"}); TRP_CASE_TARGETS=(${targets[@]+"${targets[@]}"})
      TRP_CASE_BEGIN_LINES=(${begins[@]+"${begins[@]}"}); TRP_CASE_END_LINES=(${ends[@]+"${ends[@]}"})
      TRP_CASE_COUNT="${#names[@]}"
      ;;
    malformed | uncertain)
      [[ "${#names[@]}" -eq 0 ]] || return 1
      TRP_HAS_MARKERS=1; _TRP_MARKER_MALFORMED=1
      _TRP_MARKER_MALFORMED_LINE="$mline"; _TRP_MARKER_MALFORMED_REASON="$mreason"
      [[ "$state" == uncertain ]] && _TRP_MARKER_UNCERTAIN=1
      ;;
    *) return 1 ;;
  esac
  return 0
}
