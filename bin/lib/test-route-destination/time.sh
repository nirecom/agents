#!/usr/bin/env bash
# bin/lib/test-route-destination/time.sh — source-only; the --with-time half of
# test-route-destination.sh (#2932). One thj_judge pass over the corpus at prepare time;
# every later lookup is fork-free parameter expansion. A HARD heavy test is excluded from
# the append candidates like an over-size file; WARN only advises.

_TRD_TIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-heavy-judge.sh
declare -F thj_judge >/dev/null || . "$_TRD_TIME_DIR/../test-heavy-judge.sh" || return 1

TRD_TIME_READY=0
TRD_TIME_TIER=""
TRD_TIME_ROW=""
TRD_TIME_COLUMN="-"
# LF-framed `path<TAB>tier<TAB>basis<TAB>samples` rows of the last trd_time_prepare.
_TRD_TIME_ROWS=$'\n'

# trd_time_prepare <repo-root> — judges every direct test file of _TDG_TEST_DIRS once.
# Never fails the caller: a missing or unreadable ledger leaves every path at tier `?`.
trd_time_prepare() {
  local root="${1:?trd_time_prepare: repo root required}" d f pf out tab=$'\t'
  local p tier basis n rest
  _TRD_TIME_ROWS=$'\n'
  TRD_TIME_READY=1
  pf="$(mktemp)" || return 0
  out="$(mktemp)" || { rm -f "$pf"; return 0; }
  tdg_use_root "$root"
  for d in ${_TDG_TEST_DIRS[@]+"${_TDG_TEST_DIRS[@]}"}; do
    tlr_list_dir_into "$root/$d" case-marker || continue
    for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do printf '%s\n' "${f#"${root%/}"/}"; done
  done >"$pf"
  thj_judge "$root" "$pf" "$out" || true
  while IFS="$tab" read -r p tier basis n rest || [ -n "$p" ]; do
    case "$p" in '#'* | '') continue ;; esac
    _TRD_TIME_ROWS="$_TRD_TIME_ROWS$p$tab$tier$tab$basis$tab$n"$'\n'
  done <"$out"
  rm -f "$pf" "$out"
  return 0
}

# trd_time_tier <root-relative path> — prints and sets TRD_TIME_TIER (- WARN HARD ?);
# TRD_TIME_ROW gets `tier<TAB>basis<TAB>samples`. A path the judge never saw is `?`.
trd_time_tier() {
  local p="${1-}" tab=$'\t' r
  TRD_TIME_ROW="?$tab-${tab}0"
  case "$_TRD_TIME_ROWS" in
    *$'\n'"$p$tab"*)
      r="${_TRD_TIME_ROWS#*$'\n'"$p$tab"}"
      TRD_TIME_ROW="${r%%$'\n'*}" ;;
  esac
  TRD_TIME_TIER="${TRD_TIME_ROW%%"$tab"*}"
  printf '%s\n' "$TRD_TIME_TIER"
}

# trd_time_is_hard <escaped path> — rc 0 when --with-time is prepared and the path is HARD.
trd_time_is_hard() {
  [[ "$TRD_TIME_READY" -eq 1 ]] || return 1
  tdg_unescape_field "${1-}" >/dev/null
  trd_time_tier "$TDG_UNESCAPED" >/dev/null
  [[ "$TRD_TIME_TIER" == HARD ]]
}

# trd_time_column <array-name> — the --with-time column over trd_candidates entries: one
# escaped `path:tier:basis:samples` element each, `-` when empty. Sets TRD_TIME_COLUMN.
# Reads via `eval` (Bash 3.2: no namerefs); the name is always a literal identifier here.
trd_time_column() {
  local _trd_tc_name="${1:?trd_time_column: array name required}" e out="" tab=$'\t' r
  local -a _trd_tc=()
  eval "_trd_tc=(\"\${${_trd_tc_name}[@]}\")"
  for e in "${_trd_tc[@]+"${_trd_tc[@]}"}"; do
    tdg_unescape_field "${e##*$'\t'}" >/dev/null
    trd_time_tier "$TDG_UNESCAPED" >/dev/null
    r="${TRD_TIME_ROW//"$tab"/:}"
    tdg_escape_field "$TDG_UNESCAPED:$r" >/dev/null
    out="${out:+$out,}$TDG_ESCAPED"
  done
  TRD_TIME_COLUMN="${out:--}"
  printf '%s' "$TRD_TIME_COLUMN"
}
