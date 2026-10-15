# shellcheck shell=bash
# bin/lib/test-route-destination/language.sh — source-only. Which test languages a query's
# sources call for, and which append candidates are written in one of them (#2411). Every
# language fact comes from the test language registry (codeLanguage, newFileNameShape,
# launch.requires); the criteria live in skills/_shared/test-design/append-vs-new.md.

# Output globals of the last trl_query_languages call.
TRL_LANGS=""
TRL_SHAPES=""
TRL_RUNTIME_GAP=0
_TRL_KEY=""
_TRL_HIT=""
declare -a _TRL_ID=() _TRL_SHAPE=() _TRL_REQ=() _TRL_RT=() _TRL_ALLOWED=()
declare -a _TRL_PAT_AT=() _TRL_PAT=() _TRL_INT_AT=() _TRL_INT=()

# _trl_init — the supported entries, table order, once per loaded registry table.
_trl_init() {
  if [[ -z "${TLR_LOADED_KEY-}" ]]; then tlr_load || return 1; fi
  [[ "$_TRL_KEY" == "$TLR_LOADED_KEY" ]] && return 0
  local id v n
  local -a parts=()
  _TRL_ID=(); _TRL_SHAPE=(); _TRL_REQ=(); _TRL_RT=()
  _TRL_PAT_AT=(); _TRL_PAT=(); _TRL_INT_AT=(); _TRL_INT=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    n="${#_TRL_ID[@]}"
    _TRL_ID+=("$id")
    _tlr_get "$id" newFileNameShape || _TLR_V="-"
    _TRL_SHAPE+=("$_TLR_V")
    _tlr_get "$id" launch.requires || _TLR_V=""
    _TRL_REQ+=("$_TLR_V")
    _TRL_RT+=("")
    if _tlr_get "$id" codeLanguage.sourcePatterns; then
      IFS=',' read -r -a parts <<< "$_TLR_V"
      for v in "${parts[@]}"; do _TRL_PAT_AT+=("$n"); _TRL_PAT+=("$v"); done
    fi
    if _tlr_get "$id" codeLanguage.shebangInterpreters; then
      IFS=',' read -r -a parts <<< "$_TLR_V"
      for v in "${parts[@]}"; do _TRL_INT_AT+=("$n"); _TRL_INT+=("$v"); done
    fi
  done < <(tlr_ids supported)
  _TRL_KEY="$TLR_LOADED_KEY"
}

# _trl_runtime_ok <entry-index> — the entry's launch.requires command is on PATH; asked once
# per language and process.
_trl_runtime_ok() {
  if [[ -z "${_TRL_RT[$1]}" ]]; then
    _TRL_RT[$1]=1
    if [[ -n "${_TRL_REQ[$1]}" ]] && ! command -v "${_TRL_REQ[$1]}" >/dev/null 2>&1; then _TRL_RT[$1]=0; fi
  fi
  [[ "${_TRL_RT[$1]}" -eq 1 ]]
}

# _trl_token_index <source token> — sets _TRL_HIT to the entry index of the token's test
# language: by codeLanguage.sourcePatterns on the file name, else, for an existing file whose
# name has no extension, by the interpreter line 1 names. rc 1 when no language takes it.
_trl_token_index() {
  local name="${1##*/}" i w first="" cmd
  local -a words=()
  for i in "${!_TRL_PAT[@]}"; do
    # shellcheck disable=SC2053 # the pattern is a registry glob
    if [[ "$name" == ${_TRL_PAT[$i]} ]]; then _TRL_HIT="${_TRL_PAT_AT[$i]}"; return 0; fi
  done
  [[ "$name" != *.* ]] || return 1
  local file="${TRD_ROOT:+$TRD_ROOT/}$1"
  [[ -f "$file" && -r "$file" ]] || return 1
  IFS= read -r first < "$file" 2>/dev/null || [[ -n "$first" ]] || return 1
  first="${first%$'\r'}"
  [[ "$first" == '#!'* ]] || return 1
  read -r -a words <<< "${first#'#!'}"
  cmd="${words[0]-}"; cmd="${cmd##*/}"
  if [[ "$cmd" == env ]]; then
    for ((w = 1; w < ${#words[@]}; w++)); do
      [[ "${words[w]}" == -* || "${words[w]}" == *=* ]] || break
    done
    cmd="${words[w]-}"; cmd="${cmd##*/}"
  fi
  [[ -n "$cmd" ]] || return 1
  for i in "${!_TRL_INT[@]}"; do
    if [[ "$cmd" == "${_TRL_INT[$i]}" ]]; then _TRL_HIT="${_TRL_INT_AT[$i]}"; return 0; fi
  done
  return 1
}

# trl_query_languages <query-key> — TRL_LANGS: the ids the LF-joined source tokens map to,
# table order, comma-joined (empty when none maps); TRL_SHAPES: their new-file name shapes in
# the same order. TRL_RUNTIME_GAP=1 when the query has languages and none of them can run here.
trl_query_languages() {
  local q i
  local -a hit=()
  TRL_LANGS=""; TRL_SHAPES=""; TRL_RUNTIME_GAP=0; _TRL_ALLOWED=()
  _trl_init || return 1
  while IFS= read -r q; do
    if [[ -n "$q" ]] && _trl_token_index "$q"; then hit[_TRL_HIT]=1; fi
  done <<< "${1-}"
  for i in "${!_TRL_ID[@]}"; do
    [[ -n "${hit[$i]-}" ]] || continue
    TRL_LANGS="${TRL_LANGS:+$TRL_LANGS,}${_TRL_ID[$i]}"
    TRL_SHAPES="${TRL_SHAPES:+$TRL_SHAPES,}${_TRL_SHAPE[$i]}"
  done
  # A query no language takes is not narrowed by language, only by what can run here.
  for i in "${!_TRL_ID[@]}"; do
    if [[ -n "$TRL_LANGS" && -z "${hit[$i]-}" ]]; then continue; fi
    _trl_runtime_ok "$i" && _TRL_ALLOWED+=("${_TRL_ID[$i]}")
  done
  # shellcheck disable=SC2034 # read by trd_decide
  if [[ -n "$TRL_LANGS" && "${#_TRL_ALLOWED[@]}" -eq 0 ]]; then TRL_RUNTIME_GAP=1; fi
  return 0
}

# trl_filter_candidates <inout-array> <query-key> — keeps the trd_candidates entries whose
# test file is written in a language the query allows. An unreadable registry filters nothing.
# The array name is a literal identifier at every call site (eval, as in trd_candidates).
trl_filter_candidates() {
  local _trl_name="${1:?trl_filter_candidates: array name required}" e id keep
  local -a _trl_cur=() _trl_kept=()
  trl_query_languages "${2-}" || return 0
  eval "_trl_cur=(\"\${${_trl_name}[@]}\")"
  for e in "${_trl_cur[@]+"${_trl_cur[@]}"}"; do
    tdg_unescape_field "${e##*$'\t'}" >/dev/null
    keep=0
    if tlr_match "$TDG_UNESCAPED"; then
      for id in "${_TRL_ALLOWED[@]+"${_TRL_ALLOWED[@]}"}"; do
        if [[ "$id" == "$TLR_ID" ]]; then keep=1; break; fi
      done
    elif [[ -z "$TRL_LANGS" ]]; then
      keep=1
    fi
    [[ "$keep" -eq 1 ]] && _trl_kept+=("$e")
  done
  eval "$_trl_name=(\"\${_trl_kept[@]+\"\${_trl_kept[@]}\"}\")"
  return 0
}
