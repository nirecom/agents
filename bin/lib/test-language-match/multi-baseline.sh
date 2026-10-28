# shellcheck shell=bash
# bin/lib/test-language-match/multi-baseline.sh — source-only; sourced by bin/lib/test-language-match.sh.
# The merge 3-way of the language-match judgment (#2812, a path whose two merge parents differ):
# tlm_judge runs once per baseline (head1, head2, and the merge-base B, an empty head when B lacks
# the path), and the occurrences each run judged not existing are combined per key.
#   tlm_judge_multi <file> <match-path> <base-or-empty> <head1> <head2>  rc as tlm_judge
# Rules and the accepted edges: docs/architecture/claude-code/case-marker-gate.md.

# _tlm_mb_count <key> <keys>... — prints how many of <keys> equal <key>.
_tlm_mb_count() {
  local key="$1" k n=0
  shift
  for k in "$@"; do [[ "$k" == "$key" ]] && n=$((n + 1)); done
  printf '%s' "$n"
}

# _tlm_mb_run <file> <match-path> <baseline-or-empty> — one tlm_judge run, output discarded; keeps
# _TLM_KEYS / _TLM_LINES / _TLM_CA_REACHED for the caller. rc 2 / 3 as tlm_judge, else 0.
_tlm_mb_run() {
  local rc=0
  tlm_judge "$1" "$2" "$3" >/dev/null || rc=$?
  [[ "$rc" -le 1 ]] || return "$rc"
  return 0
}

# _tlm_mb_all <file-or-empty> <match-path> — _TLM_KEYS: every mismatched occurrence of <file> (judged
# as a new file); empty for an empty <file>. rc 2 / 3 as tlm_judge, else 0.
_tlm_mb_all() {
  _TLM_KEYS=()
  [[ -n "$1" ]] || return 0
  _tlm_mb_run "$1" "$2" ""
}

# _tlm_mb_excess <p> <s> — prints max(0, p - s).
_tlm_mb_excess() {
  local d=$(($1 - $2))
  [[ "$d" -gt 0 ]] || d=0
  printf '%s' "$d"
}

# A key (hdr:<target> or case:<target>) is reported when a + b - c > 0, where a / b / c are its
# not-existing occurrences against head1 / head2 / B; one line per target, head1's line first,
# then head2's, then the staged file's.
# A not-existing count stops at 0 where a baseline holds more occurrences than the staged file,
# so each one gets that excess back (max(0, P - S), P and S the occurrences in the baseline and the
# staged file) — otherwise a + b - c differs from H + M - B when both parents dropped one.
tlm_judge_multi() {
  local file="$1" match="$2" base="${3:-}" h1="$4" h2="$5" reached=0 i key target a b c s line seen=$'\n'
  local -a k1=() l1=() k2=() l2=() kb=() order=() ks=() ls=() p1=() p2=() pb=()
  _tlm_mb_run "$file" "$match" "$h1" || return "$?"
  k1=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}"); l1=("${_TLM_LINES[@]+"${_TLM_LINES[@]}"}")
  [[ "$_TLM_CA_REACHED" -eq 1 ]] && reached=1
  _tlm_mb_run "$file" "$match" "$h2" || return "$?"
  k2=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}"); l2=("${_TLM_LINES[@]+"${_TLM_LINES[@]}"}")
  [[ "$_TLM_CA_REACHED" -eq 1 ]] && reached=1
  _tlm_mb_run "$file" "$match" "$base" || return "$?"
  kb=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}")
  _tlm_mb_all "$file" "$match" || return "$?"
  ks=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}"); ls=("${_TLM_LINES[@]+"${_TLM_LINES[@]}"}")
  _tlm_mb_all "$h1" "$match" || return "$?"
  p1=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}")
  _tlm_mb_all "$h2" "$match" || return "$?"
  p2=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}")
  _tlm_mb_all "$base" "$match" || return "$?"
  pb=("${_TLM_KEYS[@]+"${_TLM_KEYS[@]}"}")
  _TLM_HITS=0
  order=("${k1[@]+"${k1[@]}"}" "${k2[@]+"${k2[@]}"}" "${ks[@]+"${ks[@]}"}")
  for key in "${order[@]+"${order[@]}"}"; do
    target="${key#*:}"
    case "$seen" in *$'\n'"$target"$'\n'*) continue ;; esac
    a="$(_tlm_mb_count "$key" "${k1[@]+"${k1[@]}"}")"
    b="$(_tlm_mb_count "$key" "${k2[@]+"${k2[@]}"}")"
    c="$(_tlm_mb_count "$key" "${kb[@]+"${kb[@]}"}")"
    s="$(_tlm_mb_count "$key" "${ks[@]+"${ks[@]}"}")"
    a=$((a - $(_tlm_mb_excess "$(_tlm_mb_count "$key" "${p1[@]+"${p1[@]}"}")" "$s")))
    b=$((b - $(_tlm_mb_excess "$(_tlm_mb_count "$key" "${p2[@]+"${p2[@]}"}")" "$s")))
    c=$((c - $(_tlm_mb_excess "$(_tlm_mb_count "$key" "${pb[@]+"${pb[@]}"}")" "$s")))
    [[ $((a + b - c)) -gt 0 ]] || continue
    seen="$seen$target"$'\n'
    line=""
    for i in "${!k1[@]}"; do [[ "${k1[$i]}" == "$key" ]] && { line="${l1[$i]}"; break; }; done
    if [[ -z "$line" ]]; then
      for i in "${!k2[@]}"; do [[ "${k2[$i]}" == "$key" ]] && { line="${l2[$i]}"; break; }; done
    fi
    if [[ -z "$line" ]]; then
      for i in "${!ks[@]}"; do [[ "${ks[$i]}" == "$key" ]] && { line="${ls[$i]}"; break; }; done
    fi
    echo "$line"
    _TLM_HITS=1
  done
  if [[ "$reached" -eq 1 ]] && tlr_match "$match"; then
    _tlm_case_addition_3way "$TLR_ID" "$file" "$match" "$h1" "$h2" "$base"
  fi
  [[ "$_TLM_HITS" -eq 1 ]] && return 1
  return 0
}
