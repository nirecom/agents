# shellcheck shell=bash
# bin/lib/case-record-reader.sh — crr_read <file>: a test file's case records as TSV. Source only.
#   FILE\t<state>\t<malformed_line>\t<malformed_reason>      state: none|conforming|malformed|uncertain|unsupported
#   CASE\t<idx>\t<name>\t<target>\t<begin>\t<end>\t<deps>\t<malformed_reason>   (one per case, idx 0-based)
# deps: a csv of the functions the case calls, empty for none, `?` when the language has no
# caseEmbedRules part. The TRP_CASE_* globals stay set afterwards, so the caseEmbedRules ops can
# run in the same shell (the same-shell contract in docs/architecture/claude-code/test-language-registry.md).

_crr_dir="${BASH_SOURCE[0]}"
case "$_crr_dir" in */*) _crr_dir="${_crr_dir%/*}" ;; *) _crr_dir=. ;; esac
declare -F tlr_load >/dev/null 2>&1 || . "$_crr_dir/test-language-registry.sh" || return 1
declare -F trp_marker_state_from_globals >/dev/null 2>&1 || . "$_crr_dir/test-retire-predicate.sh" || return 1

_crr_file_line() { printf 'FILE\t%s\t%s\t%s\n' "$1" "$2" "$3"; }

crr_read() {
  local abs="${1:?crr_read: file required}" i n deps_out="" deps line tab=$'\t' lf=$'\n'
  local -a deps_by_idx=()
  if ! tlr_load; then _crr_file_line malformed "" reader; return 0; fi
  if ! tlr_match "$abs" || [[ "$TLR_STATUS" != supported ]] || ! _tlr_get "$TLR_ID" caseMarkerReader.file; then
    _crr_file_line unsupported "" ""; return 0
  fi
  # An already-defined reader function would hide a missing reader file from tlr_call_part.
  if [[ ! -f "$TLR_REPO_ROOT/$_TLR_V" ]] || ! tlr_call_part "$TLR_ID" caseMarkerReader "$abs"; then
    TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_NAMES=(); TRP_CASE_TARGETS=(); TRP_CASE_COUNT=0
    _crr_file_line malformed "" reader; return 0
  fi
  trp_marker_state_from_globals
  if [[ "$TRP_MARKER_STATE" != conforming ]]; then
    _crr_file_line "$TRP_MARKER_STATE" "$TRP_MARKER_LINE" "$TRP_MARKER_REASON"; return 0
  fi
  n="${#TRP_CASE_BEGIN_LINES[@]}"
  for ((i = 0; i < n; i++)); do
    if [[ "${TRP_CASE_NAMES[$i]}${TRP_CASE_TARGETS[$i]}" == *["$tab$lf"]* ]]; then
      _crr_file_line malformed "${TRP_CASE_BEGIN_LINES[$i]}" grammar; return 0
    fi
    deps_by_idx+=("?")
  done
  if _tlr_get "$TLR_ID" caseEmbedRules.file && deps_out="$(tlr_call_part "$TLR_ID" caseEmbedRules deps "$abs")"; then
    for ((i = 0; i < n; i++)); do deps_by_idx[i]=""; done
    while IFS="$tab" read -r i deps; do
      [[ "$i" =~ ^[0-9]+$ && "$i" -lt "$n" ]] && deps_by_idx[i]="$deps"
    done <<<"$deps_out"
  fi
  _crr_file_line conforming "" ""
  for ((i = 0; i < n; i++)); do
    line="CASE$tab$i$tab${TRP_CASE_NAMES[$i]}$tab${TRP_CASE_TARGETS[$i]}$tab${TRP_CASE_BEGIN_LINES[$i]}"
    printf '%s\t%s\t%s\t\n' "$line" "${TRP_CASE_END_LINES[$i]}" "${deps_by_idx[$i]}"
  done
  return 0
}
