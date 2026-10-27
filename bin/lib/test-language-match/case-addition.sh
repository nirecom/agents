# shellcheck shell=bash
# bin/lib/test-language-match/case-addition.sh — source-only; sourced by bin/lib/test-language-match.sh.
# The case-addition judgment (#2502 S4-4b): when either version of a test is not conforming, its
# cases cannot be paired, so a case added there is caught by size instead of by target.
#   _tlm_case_addition <head-copy-or-empty> <work-file> <match-path>  one CASE_ADDED_WITHOUT_MARKERS line
#   _tlm_code_lines <file> <match-path>  the count of lines neither blank nor a comment
# Units come from the case-count op, else both versions' code lines; an empty <head-copy> counts 0.
# tlm_judge runs it on test entrypoints only, minus a migration and a one-working-Tests:-path file.

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

# _tlm_case_units <id> <file> <match-path> <units|lines> — _TLM_N: the case-count answer (units) or
# the code-line count (lines). rc 1 when units cannot be counted (_TLM_COUNT_WHY says why).
_tlm_case_units() {
  _TLM_N=""
  if [[ "$4" == lines ]]; then _TLM_N="$(_tlm_code_lines "$2" "$3")"; return 0; fi
  _tlm_unit_count "$1" "$2" || return 1
  _TLM_N="$_TLM_COUNT"
}

# _tlm_case_added_report <id> <match-path> <basis-text> — the CASE_ADDED_WITHOUT_MARKERS line.
_tlm_case_added_report() {
  _tlr_get "$1" diagnostics.markerName || _TLR_V="case markers"
  echo "HIGH: $2: case added to a test file without valid case markers ($3); add $_TLR_V to every case first, then each case's target is checked code=CASE_ADDED_WITHOUT_MARKERS"
  _TLM_HITS=1
}

_tlm_case_addition() {
  local head="$1" file="$2" match="$3" id h_count=0 w_count h_ok=0 why="" basis h_lines=0 w_lines
  _TLM_CA_REACHED=1
  tlr_match "$match" || return 0
  id="$TLR_ID"
  if [[ -z "$head" ]]; then
    h_ok=1
  elif _tlm_case_units "$id" "$head" "$match" units; then
    h_count="$_TLM_N"; h_ok=1
  else
    why="$_TLM_COUNT_WHY"
  fi
  if _tlm_case_units "$id" "$file" "$match" units; then w_count="$_TLM_N"; else why="$_TLM_COUNT_WHY"; h_ok=0; fi
  if [[ "$h_ok" -eq 1 ]]; then
    [[ "$w_count" -gt "$h_count" ]] || return 0
    basis="case units $h_count -> $w_count"
  else
    if [[ -n "$head" ]]; then _tlm_case_units "$id" "$head" "$match" lines; h_lines="$_TLM_N"; fi
    _tlm_case_units "$id" "$file" "$match" lines; w_lines="$_TLM_N"
    [[ "$w_lines" -gt "$h_lines" ]] || return 0
    basis="case count unavailable: $why; code lines $h_lines -> $w_lines"
  fi
  _tlm_case_added_report "$id" "$match" "$basis"
}

# _tlm_case_addition_3way <id> <file> <match-path> <head1> <head2> <base-or-empty> — the merge form
# (#2812): existing = max(0, n(head1) + n(head2) - n(base)), n(no base) = 0; reported when the
# staged count exceeds it. Every version is counted in case units, or all in code lines when any
# one cannot be, so the units are never mixed.
_tlm_case_addition_3way() {
  local id="$1" file="$2" match="$3" b="${6:-}" label="case units" why="" f existing nb=0
  local -a n=()
  for f in "$file" "$4" "$5" ${b:+"$b"}; do
    if _tlm_case_units "$id" "$f" "$match" units; then n+=("$_TLM_N"); else why="$_TLM_COUNT_WHY"; n=(); break; fi
  done
  if [[ "${#n[@]}" -eq 0 ]]; then
    label="case count unavailable: $why; code lines"
    for f in "$file" "$4" "$5" ${b:+"$b"}; do _tlm_case_units "$id" "$f" "$match" lines; n+=("$_TLM_N"); done
  fi
  [[ -z "$b" ]] || nb="${n[3]}"
  existing=$((n[1] + n[2] - nb))
  [[ "$existing" -ge 0 ]] || existing=0
  [[ "${n[0]}" -gt "$existing" ]] || return 0
  _tlm_case_added_report "$id" "$match" "$label H+M−B = $existing -> ${n[0]}"
}
