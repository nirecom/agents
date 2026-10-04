#!/usr/bin/env bash
# bin/lib/test-route-destination.sh — source-only; not executable. Decides
# whether a planned test case appends to an existing categorized
# tests/<category>/<name>.sh file or needs a new one. The same-token-set rule lives in
# skills/_shared/test-design/append-vs-new.md. Corpus scanning is delegated to
# tdg_scan_corpus, structural validation to tdg_classify_parsed and token
# extraction to tfm_parse_tests_matches (CPR-SSOT). The 500-line HARD default is owned by
# skills/_shared/test-design.md "Size Limits" — bin/review-code-size hardcodes
# the same number and no shared constant exists to reference instead.

_TRD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-dup-group.sh
source "$_TRD_DIR/test-dup-group.sh" || return 1

TRD_HARD_MAX_DEFAULT=500

# Output globals. Every one is rewritten by the call that owns it.
TRD_ROOT=""
TRD_CLASSIFY_VERDICT=""
TRD_VERDICT=""
TRD_REASON=""
TRD_TARGET="-"
TRD_TARGET_LINES="-"
declare -a TRD_CORPUS_FILES=()
declare -a TRD_CORPUS_TOKENS=()
declare -a TRD_CORPUS_NTOK=()
declare -a TRD_CORPUS_LINES=()
declare -a TRD_CANDIDATES=()
declare -a TRD_VIABLE=()
declare -a TRD_EXCLUDED=()

# trd_normalize_token <token> — trim, strip every leading `./`, then validate.
# A leading `/`, any `..` component and anything tfm_token_format_ok rejects is
# a non-zero status, never a silently repaired token.
trd_normalize_token() {
  local t="${1-}"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  while true; do
    case "$t" in
      ./*) t="${t#./}" ;;
      *) break ;;
    esac
    while [[ "$t" == /* ]]; do t="${t#/}"; done
  done
  [[ -n "$t" ]] || return 1
  [[ "$t" != /* ]] || return 1
  [[ "/$t/" != */../* ]] || return 1
  tfm_token_format_ok "$t" || return 1
  TRD_NORMALIZED="$t"
  printf '%s' "$t"
}

# trd_canonicalize_set <out-array> <token>... — the ONLY normalization entry
# point: both the query side and every corpus candidate pass through it, so a
# one-sided spelling difference can never decide a verdict.
# Bash-3.2-compatible: writes via `eval` indirection instead of `local -n`
# (namerefs are Bash-4.3+ and crash on macOS stock bash, #1486's class of
# bug). The array-name argument is always a literal identifier at every call
# site in this repo, never external input, so eval is safe here.
trd_canonicalize_set() {
  local _trd_set_name="${1:?trd_canonicalize_set: array name required}"
  shift
  eval "$_trd_set_name=()"
  local t
  _TRD_SORTED=()
  for t in "$@"; do
    trd_normalize_token "$t" >/dev/null || return 1
    _trd_insert_sorted "$TRD_NORMALIZED"
  done
  [[ "${#_TRD_SORTED[@]}" -gt 0 ]] || return 1
  for t in "${_TRD_SORTED[@]}"; do
    eval "$_trd_set_name+=(\"\$t\")"
  done
  return 0
}

# _trd_insert_sorted <token> — adds <token> to _TRD_SORTED keeping it equal to
# `LC_ALL=C sort -u` output; fork-free because sets hold a handful of tokens and
# a sort process per corpus file dominated the scan on MSYS (#2455).
_trd_insert_sorted() {
  local LC_ALL=C
  local v="$1" j tmp
  for ((j = 0; j < ${#_TRD_SORTED[@]}; j++)); do
    [[ "${_TRD_SORTED[j]}" == "$v" ]] && return 0
  done
  _TRD_SORTED+=("$v")
  j=$((${#_TRD_SORTED[@]} - 1))
  while [[ "$j" -gt 0 && "${_TRD_SORTED[j]}" < "${_TRD_SORTED[j - 1]}" ]]; do
    tmp="${_TRD_SORTED[j]}"
    _TRD_SORTED[j]="${_TRD_SORTED[j - 1]}"
    _TRD_SORTED[j - 1]="$tmp"
    j=$((j - 1))
  done
}

# trd_set_key <token>... — the canonical set as one LF-joined comparison key.
trd_set_key() {
  local -a _trd_k=()
  trd_canonicalize_set _trd_k "$@" || return 1
  local out="" t
  for t in "${_trd_k[@]}"; do
    if [[ -z "$out" ]]; then out="$t"; else out="$out"$'\n'"$t"; fi
  done
  printf '%s' "$out"
}

# trd_is_in_corpus <root-relative path> — is the path inside the corpus range
# contract: tests/<canonical-category>/<name>.sh (3 components only).
# Uses _TDG_CANONICAL_CATEGORIES (CPR-SSOT) — available because this file
# sources test-dup-group.sh above. Non-canonical directories (split-test
# fragments, _archive, lib) are rejected. Flat tests/<name>.sh (2 components)
# are NOT in the corpus range.
trd_is_in_corpus() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  local -a parts=()
  IFS='/' read -r -a parts <<< "$p"
  [[ "${parts[0]}" == "tests" ]] || return 1
  if [[ "${#parts[@]}" -eq 3 ]]; then
    local _cat _found=0
    for _cat in "${_TDG_CANONICAL_CATEGORIES[@]}"; do
      [[ "${parts[1]}" == "$_cat" ]] && { _found=1; break; }
    done
    [[ "$_found" -eq 1 ]] || return 1
    # A supported test language whose cases the registry can read.
    tlr_match "${parts[2]}" && [[ "$TLR_STATUS" == supported ]] && _tlr_get "$TLR_ID" caseMarkerReader.file || return 1
  else
    return 1
  fi
  return 0
}

# trd_validate_test_matches <grep -n rows> — structural validation of one
# file's `# Tests:` matches (_tdg_batch_matches output) through
# tdg_classify_parsed, never through the parser alone: the parser accepts the
# first header it finds and would pass duplicate, late and malformed ones.
# Sets TRD_CLASSIFY_VERDICT; on ok, TFM_TOKENS holds the parsed set.
trd_validate_test_matches() {
  TRD_CLASSIFY_VERDICT=""
  tfm_parse_tests_matches "${1-}"
  tdg_classify_parsed
  # shellcheck disable=SC2153  # TDG_VERDICT is set by the sourced test-dup-group.sh
  TRD_CLASSIFY_VERDICT="$TDG_VERDICT"
  [[ "$TRD_CLASSIFY_VERDICT" == "ok" ]]
}

# _trd_corpus_reset <repo-root> — the one place the parallel corpus arrays are
# emptied, shared by the scan and the corpus-cache loader.
_trd_corpus_reset() {
  TRD_ROOT="${1-}"
  TRD_CORPUS_FILES=()
  TRD_CORPUS_TOKENS=()
  TRD_CORPUS_NTOK=()
  TRD_CORPUS_LINES=()
}

# trd_load_corpus <repo-root> — one tdg_scan_corpus pass, `full` rows only.
# Files tdg_classify rejected never reach this list (skip semantics inherited).
trd_load_corpus() {
  local root="${1:?trd_load_corpus: repo root required}"
  _trd_corpus_reset "$root"
  local axis key esc_file file joined t
  local -a _trd_raw=() _trd_can=()
  while IFS=$'\t' read -r axis key esc_file; do
    [[ "$axis" == "full" ]] || continue
    tdg_unescape_field "$esc_file" >/dev/null
    file="$TDG_UNESCAPED"
    _trd_raw=()
    tdg_split_escaped_csv "$key" _trd_raw
    _trd_can=()
    trd_canonicalize_set _trd_can "${_trd_raw[@]}" || continue
    joined=""
    for t in "${_trd_can[@]}"; do
      if [[ -z "$joined" ]]; then joined="$t"; else joined="$joined"$'\n'"$t"; fi
    done
    TRD_CORPUS_FILES+=("$file")
    TRD_CORPUS_TOKENS+=("$joined")
    TRD_CORPUS_NTOK+=("${#_trd_can[@]}")
  done < <(tdg_scan_corpus "$root")
  return 0
}

# mapfile is bash 4+; the only bash-3.2 branch of trd_file_lines keys on this.
_TRD_HAS_MAPFILE=0
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] && _TRD_HAS_MAPFILE=1

# trd_file_lines <file> — the `wc -l` line count (a final line without LF is
# not counted), or a non-zero status when unreadable. Also sets TRD_FILE_LINES
# so hot loops can skip the command substitution (#2455).
trd_file_lines() {
  local f="${1:?trd_file_lines: file required}"
  if [[ "$f" != /* && ! -e "$f" && -n "$TRD_ROOT" ]]; then f="$TRD_ROOT/$f"; fi
  [[ -f "$f" && -r "$f" ]] || return 1
  local n
  if [[ "$_TRD_HAS_MAPFILE" -eq 1 ]]; then
    local -a _trd_fl=()
    mapfile _trd_fl < "$f" 2>/dev/null || return 1
    n="${#_trd_fl[@]}"
    [[ "$n" -gt 0 && "${_trd_fl[n - 1]}" != *$'\n' ]] && n=$((n - 1))
  else
    n="$(wc -l < "$f" 2>/dev/null)" || return 1
    n="${n//[[:space:]]/}"
    [[ -n "$n" ]] || return 1
  fi
  TRD_FILE_LINES="$n"
  printf '%s' "$n"
}

# trd_candidates <out-array> <query-key> <self-exclude-path> — every corpus file
# whose canonical set T satisfies S ⊆ T. One element is
# `<extra_count>TAB<lines>TAB<escaped path>`.
# Bash-3.2-compatible: writes via `eval` indirection instead of `local -n`
# (namerefs are Bash-4.3+ and crash on macOS stock bash, #1486's class of
# bug). The array-name argument is always a literal identifier at every call
# site in this repo, never external input, so eval is safe here.
trd_candidates() {
  local _trd_cands_name="${1:?trd_candidates: array name required}"
  local qkey="${2-}" self="${3-}"
  eval "$_trd_cands_name=()"
  local -a _trd_q=()
  local q i file ctoks ok extra lines qn entry
  while IFS= read -r q; do
    [[ -n "$q" ]] && _trd_q+=("$q")
  done <<< "$qkey"
  qn="${#_trd_q[@]}"
  [[ "$qn" -gt 0 ]] || return 0
  for i in "${!TRD_CORPUS_FILES[@]}"; do
    file="${TRD_CORPUS_FILES[$i]}"
    [[ -n "$self" && "$file" == "$self" ]] && continue
    ctoks="${TRD_CORPUS_TOKENS[$i]}"
    ok=1
    for q in "${_trd_q[@]}"; do
      if [[ $'\n'"$ctoks"$'\n' != *$'\n'"$q"$'\n'* ]]; then ok=0; break; fi
    done
    [[ "$ok" -eq 1 ]] || continue
    if [[ -z "${TRD_CORPUS_LINES[i]-}" ]]; then
      TRD_CORPUS_LINES[i]="-"
      trd_file_lines "$file" >/dev/null && TRD_CORPUS_LINES[i]="$TRD_FILE_LINES"
    fi
    lines="${TRD_CORPUS_LINES[i]}"
    [[ "$lines" != "-" ]] || continue
    extra=$((TRD_CORPUS_NTOK[i] - qn))
    tdg_escape_field "$file" >/dev/null
    entry="$extra"$'\t'"$lines"$'\t'"$TDG_ESCAPED"
    eval "$_trd_cands_name+=(\"\$entry\")"
  done
  return 0
}

# trd_rank <inout-array> — extra_count asc, then lines asc, then path asc (C).
# Bash-3.2-compatible: writes via `eval` indirection instead of `local -n`
# (namerefs are Bash-4.3+ and crash on macOS stock bash, #1486's class of
# bug). The array-name argument is always a literal identifier at every call
# site in this repo, never external input, so eval is safe here.
# A fork-free bottom-up merge sort (#2455): candidates can number in the
# hundreds, so insertion sort's O(n^2) would cost seconds in bash.
trd_rank() {
  local _trd_arr_name="${1:?trd_rank: array name required}"
  local -a _trd_a=() _trd_b=()
  eval "_trd_a=(\"\${${_trd_arr_name}[@]}\")"
  local n="${#_trd_a[@]}" w lo mid hi i j k
  [[ "$n" -gt 1 ]] || return 0
  for ((w = 1; w < n; w *= 2)); do
    _trd_b=()
    for ((lo = 0; lo < n; lo += 2 * w)); do
      mid=$((lo + w < n ? lo + w : n))
      hi=$((lo + 2 * w < n ? lo + 2 * w : n))
      i="$lo"; j="$mid"; k="$lo"
      while [[ "$i" -lt "$mid" && "$j" -lt "$hi" ]]; do
        if _trd_rank_before "${_trd_a[j]}" "${_trd_a[i]}"; then
          _trd_b[k]="${_trd_a[j]}"; j=$((j + 1))
        else
          _trd_b[k]="${_trd_a[i]}"; i=$((i + 1))
        fi
        k=$((k + 1))
      done
      for ((; i < mid; i++, k++)); do _trd_b[k]="${_trd_a[i]}"; done
      for ((; j < hi; j++, k++)); do _trd_b[k]="${_trd_a[j]}"; done
    done
    _trd_a=("${_trd_b[@]}")
  done
  eval "$_trd_arr_name=(\"\${_trd_a[@]}\")"
  return 0
}

# _trd_rank_before <a> <b> — true when entry a sorts strictly before b under
# `LC_ALL=C sort -t<TAB> -k1,1n -k2,2n -k3,3` (paths are unique, so no tie).
_trd_rank_before() {
  local LC_ALL=C
  local ar="${1#*$'\t'}" br="${2#*$'\t'}"
  local a1="${1%%$'\t'*}" b1="${2%%$'\t'*}" a2="${ar%%$'\t'*}" b2="${br%%$'\t'*}"
  if [[ $((10#$a1)) -ne $((10#$b1)) ]]; then [[ $((10#$a1)) -lt $((10#$b1)) ]]; return; fi
  if [[ $((10#$a2)) -ne $((10#$b2)) ]]; then [[ $((10#$a2)) -lt $((10#$b2)) ]]; return; fi
  [[ "${ar#*$'\t'}" < "${br#*$'\t'}" ]]
}

# trd_viable_candidates <out-array> <ranked-array> <hard-max> — the SOLE
# `S ⊆ T and lines < hard-max` predicate. It is computed independently of the
# verdict so review-tests can read it as a gap signal (C1).
# Bash-3.2-compatible: writes via `eval` indirection instead of `local -n`
# (namerefs are Bash-4.3+ and crash on macOS stock bash, #1486's class of
# bug). The array-name arguments are always literal identifiers at every call
# site in this repo, never external input, so eval is safe here.
trd_viable_candidates() {
  local _trd_viable_name="${1:?trd_viable_candidates: array name required}"
  local _trd_src_name="${2:?trd_viable_candidates: source array required}"
  local hardmax="${3:?trd_viable_candidates: hard max required}"
  eval "$_trd_viable_name=()"
  local -a _trd_src_cur=()
  eval "_trd_src_cur=(\"\${${_trd_src_name}[@]}\")"
  local e lines entry
  for e in "${_trd_src_cur[@]+"${_trd_src_cur[@]}"}"; do
    lines="${e#*$'\t'}"
    lines="${lines%%$'\t'*}"
    if [[ "$lines" -le "$hardmax" ]]; then
      entry="$e"
      eval "$_trd_viable_name+=(\"\$entry\")"
    fi
  done
  return 0
}

# trd_decide <query-key> <self-exclude> <hard-max> — fills TRD_VERDICT /
# TRD_REASON / TRD_TARGET / TRD_TARGET_LINES and keeps all three lists.
trd_decide() {
  local qkey="${1-}" self="${2-}" hardmax="${3:-$TRD_HARD_MAX_DEFAULT}"
  TRD_VERDICT=""
  TRD_REASON=""
  TRD_TARGET="-"
  TRD_TARGET_LINES="-"
  TRD_CANDIDATES=()
  TRD_VIABLE=()
  TRD_EXCLUDED=()
  trd_candidates TRD_CANDIDATES "$qkey" "$self"
  trd_rank TRD_CANDIDATES
  trd_viable_candidates TRD_VIABLE TRD_CANDIDATES "$hardmax"
  local e lines head extra
  for e in "${TRD_CANDIDATES[@]+"${TRD_CANDIDATES[@]}"}"; do
    lines="${e#*$'\t'}"
    lines="${lines%%$'\t'*}"
    [[ "$lines" -gt "$hardmax" ]] && TRD_EXCLUDED+=("$e")
  done
  if [[ "${#TRD_VIABLE[@]}" -gt 0 ]]; then
    head="${TRD_VIABLE[0]}"
    extra="${head%%$'\t'*}"
    lines="${head#*$'\t'}"
    lines="${lines%%$'\t'*}"
    TRD_VERDICT="append"
    if [[ "$extra" -eq 0 ]]; then TRD_REASON="exact"; else TRD_REASON="superset"; fi
    TRD_TARGET_LINES="$lines"
    tdg_unescape_field "${head##*$'\t'}" >/dev/null
    TRD_TARGET="$TDG_UNESCAPED"
  elif [[ "${#TRD_CANDIDATES[@]}" -gt 0 ]]; then
    TRD_VERDICT="new"
    TRD_REASON="size-hard-limit"
  else
    TRD_VERDICT="new"
    TRD_REASON="no-candidate"
  fi
  return 0
}

# trd_list_column <array-name> — columns 6-8. No new escape rule is invented:
# the inner `file,lines,extra_count` string is escaped once more as a single
# outer element, so two tdg_split_escaped_csv passes recover it. Empty is `-`.
# Bash-3.2-compatible: reads via `eval` indirection instead of `local -n`
# (namerefs are Bash-4.3+ and crash on macOS stock bash, #1486's class of
# bug). The array-name argument is always a literal identifier at every call
# site in this repo, never external input, so eval is safe here.
trd_list_column() {
  local _trd_lc_name="${1:?trd_list_column: array name required}"
  local -a _trd_lc=()
  eval "_trd_lc=(\"\${${_trd_lc_name}[@]}\")"
  local out="" e extra lines path
  for e in "${_trd_lc[@]+"${_trd_lc[@]}"}"; do
    extra="${e%%$'\t'*}"
    lines="${e#*$'\t'}"
    lines="${lines%%$'\t'*}"
    path="${e##*$'\t'}"
    tdg_escape_field "$path,$lines,$extra" >/dev/null
    out="${out:+$out,}$TDG_ESCAPED"
  done
  [[ -n "$out" ]] || out='-'
  TRD_LIST_COLUMN="$out"
  printf '%s' "$out"
}

# trd_row <escaped-query> — the 8-column TSV line for the last trd_decide.
trd_row() {
  local query="${1-}" target="-" cands viable excluded
  if [[ "$TRD_TARGET" != "-" ]]; then
    tdg_escape_field "$TRD_TARGET" >/dev/null
    target="$TDG_ESCAPED"
  fi
  trd_list_column TRD_CANDIDATES >/dev/null; cands="$TRD_LIST_COLUMN"
  trd_list_column TRD_VIABLE >/dev/null; viable="$TRD_LIST_COLUMN"
  trd_list_column TRD_EXCLUDED >/dev/null; excluded="$TRD_LIST_COLUMN"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$query" "$TRD_VERDICT" "$TRD_REASON" "$target" "$TRD_TARGET_LINES" \
    "$cands" "$viable" "$excluded"
}
