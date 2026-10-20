# shellcheck shell=bash
# bin/lib/test-language-match/case-addition.sh — source-only; sourced by bin/lib/test-language-match.sh.
# The case-addition judgment (#2502 S4-4b): when either version of a test is not conforming, its
# cases cannot be paired, so a case added there is caught by size instead of by target.
#   _tlm_case_addition <head-copy-or-empty> <work-file> <match-path>  one CASE_ADDED_WITHOUT_MARKERS line
#   _tlm_code_lines <file> <match-path>  the count of lines neither blank nor a comment
# Units come from the case-count op, else both versions' code lines; an empty <head-copy> counts 0.
# tlm_judge runs it on test entrypoints only, minus a new one-Tests:-token file and a migration.

# _tlm_code_lines <file> <match-path> — prints the number of lines that are not blank and do not
# start (after leading blanks) with the comment prefix of <match-path>'s registry entry.
_tlm_code_lines() {
  local prefix line n=0
  prefix="$(tlr_comment_prefix "$2")"
  if [[ -f "$1" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || ( -n "$prefix" && "$line" == "$prefix"* ) ]] && continue
      n=$((n + 1))
    done <"$1"
  fi
  printf '%s\n' "$n"
}

# _tlm_unit_count <id> <file> — _TLM_COUNT: the case-count answer; _TLM_COUNT_WHY: why there is
# none. rc 0 counted, 1 not.
_tlm_unit_count() {
  local rc=0 out=""
  _TLM_COUNT=""; _TLM_COUNT_WHY=""
  if _tlr_get "$1" caseEmbedRules.file; then
    out="$(tlr_call_part "$1" caseEmbedRules case-count "$2" 2>/dev/null)" || rc=$?
  else
    rc=3
  fi
  out="${out%$'\r'}"
  if [[ "$rc" -eq 0 && "$out" =~ ^[0-9]+$ ]]; then _TLM_COUNT="$out"; return 0; fi
  case "$rc" in
    0) _TLM_COUNT_WHY="no count in the answer" ;;
    1) _TLM_COUNT_WHY="no case unit" ;;
    3) _TLM_COUNT_WHY="no caseEmbedRules" ;;
    69) _TLM_COUNT_WHY="runtime not installed" ;;
    70) _TLM_COUNT_WHY="part unreachable" ;;
    *) _TLM_COUNT_WHY="rc $rc" ;;
  esac
  return 1
}

_tlm_case_addition() {
  local head="$1" file="$2" match="$3" id h_count=0 w_count h_ok=0 why="" basis h_lines=0 w_lines
  tlr_match "$match" || return 0
  id="$TLR_ID"
  if [[ -z "$head" ]]; then
    h_ok=1
  elif _tlm_unit_count "$id" "$head"; then
    h_count="$_TLM_COUNT"; h_ok=1
  else
    why="$_TLM_COUNT_WHY"
  fi
  if _tlm_unit_count "$id" "$file"; then w_count="$_TLM_COUNT"; else why="$_TLM_COUNT_WHY"; h_ok=0; fi
  if [[ "$h_ok" -eq 1 ]]; then
    [[ "$w_count" -gt "$h_count" ]] || return 0
    basis="case units $h_count -> $w_count"
  else
    [[ -z "$head" ]] || h_lines="$(_tlm_code_lines "$head" "$match")"
    w_lines="$(_tlm_code_lines "$file" "$match")"
    [[ "$w_lines" -gt "$h_lines" ]] || return 0
    basis="case count unavailable: $why; code lines $h_lines -> $w_lines"
  fi
  _tlr_get "$id" diagnostics.markerName || _TLR_V="case markers"
  echo "HIGH: $match: case added to a test file without valid case markers ($basis); add $_TLR_V to every case first, then each case's target is checked code=CASE_ADDED_WITHOUT_MARKERS"
  _TLM_HITS=1
}
