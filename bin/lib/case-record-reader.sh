# shellcheck shell=bash
# bin/lib/case-record-reader.sh — crr_read <file> [<match-path>]: a test file's case records as TSV.
# Source only. <match-path> (default <file>) picks the registry entry; the content is <file>'s.
#   FILE\t<state>\t<malformed_line>\t<malformed_reason>      state: none|conforming|malformed|uncertain|unsupported|unavailable
#   unavailable: the reader part (79) or the deps op (69) found no runtime; the last column names the command.
#   uncertain with reason case-embed: the deps op failed or its rows broke the contract (no CASE lines).
#   CASE\t<name>\t<target>\t<begin>\t<end>\t<deps>\t<malformed_reason>   (one per case, in file order)
# deps: a csv of the functions the case calls, empty for none, `?` when the language has no
# caseEmbedRules part. The TRP_CASE_* globals stay set afterwards (the same-shell contract in
# docs/architecture/claude-code/test-language-registry.md). crr_supported <match-path>: rc 0 when a reader exists.

_crr_dir="${BASH_SOURCE[0]}"
case "$_crr_dir" in */*) _crr_dir="${_crr_dir%/*}" ;; *) _crr_dir=. ;; esac
declare -F tlr_load >/dev/null 2>&1 || . "$_crr_dir/test-language-registry.sh" || return 1
declare -F trp_marker_state_from_globals >/dev/null 2>&1 || . "$_crr_dir/test-retire-predicate.sh" || return 1

_crr_file_line() { printf 'FILE\t%s\t%s\t%s\n' "$1" "$2" "$3"; }

# crr_supported <match-path> — rc 0 when the path's registry entry is supported and names a
# caseMarkerReader file (left in _TLR_V); rc 1 otherwise. The registry must be loaded.
crr_supported() {
  tlr_match "${1:?crr_supported: match-path required}" && [[ "$TLR_STATUS" == supported ]] &&
    _tlr_get "$TLR_ID" caseMarkerReader.file
}

# _crr_deps_rows <n> <deps-output> — fills _CRR_DEPS[0..n-1] from the rows `<idx>\t<csv>`.
# rc 1 when a row breaks the contract: not two columns, an index that is not 0..n-1 or repeats,
# a CR, an empty csv element, a missing index, or no rows at all.
_crr_deps_rows() {
  local n="$1" row idx csv seen=0 tab=$'\t' re_csv='^([^,]+(,[^,]+)*)?$'
  _CRR_DEPS=()
  [[ -n "$2" && "$2" != *$'\r'* ]] || return 1
  while IFS= read -r row; do
    [[ "$row" == *"$tab"* && "${row#*"$tab"}" != *"$tab"* ]] || return 1
    idx="${row%%"$tab"*}" csv="${row#*"$tab"}"
    [[ "$idx" =~ ^[0-9]+$ && "$((10#$idx))" -lt "$n" && -z "${_CRR_DEPS[10#$idx]+x}" && "$csv" =~ $re_csv ]] || return 1
    _CRR_DEPS[10#$idx]="$csv"
    seen=$((seen + 1))
  done <<<"$2"
  [[ "$seen" -eq "$n" ]]
}

crr_read() {
  local abs="${1:?crr_read: file required}" i n rc deps_out="" line tab=$'\t'
  local -a deps_by_idx=() _CRR_DEPS=()
  if ! tlr_load; then _crr_file_line malformed "" reader; return 0; fi
  if ! crr_supported "${2:-$abs}"; then _crr_file_line unsupported "" ""; return 0; fi
  # An already-defined reader function would hide a missing reader file from tlr_call_part.
  if [[ ! -f "$TLR_REPO_ROOT/$_TLR_V" ]]; then rc=70; else tlr_call_part "$TLR_ID" caseMarkerReader "$abs"; rc=$?; fi
  if [[ "$rc" -ne 0 ]]; then
    # shellcheck disable=SC2034  # TRP_CASE_COUNT is read by the sourcing callers
    TRP_CASE_COUNT=0; TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_NAMES=(); TRP_CASE_TARGETS=()
    if [[ "$rc" -eq 79 ]]; then
      _tlr_get "$TLR_ID" launch.requires || _TLR_V=""
      _crr_file_line unavailable "" "$_TLR_V"; return 0
    fi
    _crr_file_line malformed "" reader; return 0
  fi
  trp_marker_state_from_globals
  if [[ "$TRP_MARKER_STATE" != conforming ]]; then
    _crr_file_line "$TRP_MARKER_STATE" "$TRP_MARKER_LINE" "$TRP_MARKER_REASON"; return 0
  fi
  n="${#TRP_CASE_BEGIN_LINES[@]}"
  for ((i = 0; i < n; i++)); do deps_by_idx+=("?"); done
  if _tlr_get "$TLR_ID" caseEmbedRules.file; then
    rc=0
    deps_out="$(tlr_call_part "$TLR_ID" caseEmbedRules deps "$abs")" || rc=$?
    if [[ "$rc" -eq 69 ]]; then
      _tlr_get "$TLR_ID" launch.requires || _TLR_V=""
      _crr_file_line unavailable "" "$_TLR_V"; return 0
    fi
    if [[ "$rc" -ne 0 ]] || ! _crr_deps_rows "$n" "$deps_out"; then
      _crr_file_line uncertain "" case-embed; return 0
    fi
    deps_by_idx=("${_CRR_DEPS[@]}")
  fi
  _crr_file_line conforming "" ""
  for ((i = 0; i < n; i++)); do
    line="CASE$tab${TRP_CASE_NAMES[$i]}$tab${TRP_CASE_TARGETS[$i]}$tab${TRP_CASE_BEGIN_LINES[$i]}"
    printf '%s\t%s\t%s\t\n' "$line" "${TRP_CASE_END_LINES[$i]}" "${deps_by_idx[$i]}"
  done
  return 0
}
