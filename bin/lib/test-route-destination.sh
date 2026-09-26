#!/usr/bin/env bash
# bin/lib/test-route-destination.sh — source-only; not executable. Decides
# whether a planned test case appends to an existing categorized
# tests/<category>/<name>.sh file or needs a new one. The same-token-set rule lives in
# skills/_shared/test-design/append-vs-new.md. Corpus scanning is delegated to
# tdg_scan_corpus, structural validation to tdg_classify and token extraction to
# tfm_parse_tests_line (CPR-SSOT). The 500-line HARD default is owned by
# skills/_shared/test-design.md "Size Limits" — bin/review-code-size hardcodes
# the same number and no shared constant exists to reference instead.

_TRD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-dup-group.sh
source "$_TRD_DIR/test-dup-group.sh"

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
  local t norm
  local -a _trd_norm=()
  for t in "$@"; do
    norm="$(trd_normalize_token "$t")" || return 1
    _trd_norm+=("$norm")
  done
  [[ "${#_trd_norm[@]}" -gt 0 ]] || return 1
  while IFS= read -r t; do
    [[ -n "$t" ]] && eval "$_trd_set_name+=(\"\$t\")"
  done < <(printf '%s\n' "${_trd_norm[@]}" | LC_ALL=C sort -u)
  return 0
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

# trd_is_top_level_test <root-relative path> — is the path inside the corpus
# range contract: tests/<canonical-category>/<name>.sh (3 components only).
# Uses _TDG_CANONICAL_CATEGORIES (CPR-SSOT) — available because this file
# sources test-dup-group.sh above. Non-canonical directories (split-test
# fragments, _archive, lib) are rejected. Flat tests/<name>.sh (2 components)
# are NOT in the corpus range.
# "top_level" is a legacy name from the flat-structure era; it means "in corpus".
trd_is_top_level_test() {
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
    [[ "${parts[2]}" == *.sh && "${parts[2]}" != ".sh" ]] || return 1
  else
    return 1
  fi
  return 0
}

# trd_validate_test_file <file> — structural validation goes through
# tdg_classify, never through tfm_parse_tests_line alone: the parser accepts the
# first header it finds and would pass duplicate, late and malformed ones.
trd_validate_test_file() {
  local file="${1:?trd_validate_test_file: file required}"
  TRD_CLASSIFY_VERDICT=""
  tdg_classify "$file" >/dev/null
  # shellcheck disable=SC2153  # TDG_VERDICT is set by the sourced test-dup-group.sh
  TRD_CLASSIFY_VERDICT="$TDG_VERDICT"
  [[ "$TRD_CLASSIFY_VERDICT" == "ok" ]] || return 1
  tfm_parse_tests_line "$file"
  return 0
}

# trd_load_corpus <repo-root> — one tdg_scan_corpus pass, `full` rows only.
# Files tdg_classify rejected never reach this list (skip semantics inherited).
trd_load_corpus() {
  local root="${1:?trd_load_corpus: repo root required}"
  TRD_ROOT="$root"
  TRD_CORPUS_FILES=()
  TRD_CORPUS_TOKENS=()
  TRD_CORPUS_NTOK=()
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

# trd_file_lines <file> — the line count, or a non-zero status when unreadable.
trd_file_lines() {
  local f="${1:?trd_file_lines: file required}"
  if [[ "$f" != /* && ! -e "$f" && -n "$TRD_ROOT" ]]; then f="$TRD_ROOT/$f"; fi
  [[ -f "$f" && -r "$f" ]] || return 1
  local n
  n="$(wc -l < "$f" 2>/dev/null)" || return 1
  n="${n//[[:space:]]/}"
  [[ -n "$n" ]] || return 1
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
    lines="$(trd_file_lines "$file")" || continue
    extra=$((TRD_CORPUS_NTOK[i] - qn))
    entry="$extra"$'\t'"$lines"$'\t'"$(tdg_escape_field "$file")"
    eval "$_trd_cands_name+=(\"\$entry\")"
  done
  return 0
}

# trd_rank <inout-array> — extra_count asc, then lines asc, then path asc (C).
# Bash-3.2-compatible: writes via `eval` indirection instead of `local -n`
# (namerefs are Bash-4.3+ and crash on macOS stock bash, #1486's class of
# bug). The array-name argument is always a literal identifier at every call
# site in this repo, never external input, so eval is safe here.
trd_rank() {
  local _trd_arr_name="${1:?trd_rank: array name required}"
  local -a _trd_cur=()
  eval "_trd_cur=(\"\${${_trd_arr_name}[@]}\")"
  [[ "${#_trd_cur[@]}" -gt 0 ]] || return 0
  local -a _trd_sorted=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && _trd_sorted+=("$line")
  done < <(printf '%s\n' "${_trd_cur[@]}" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3)
  eval "$_trd_arr_name=(\"\${_trd_sorted[@]}\")"
  return 0
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
  local out="" e extra lines path inner
  for e in "${_trd_lc[@]+"${_trd_lc[@]}"}"; do
    extra="${e%%$'\t'*}"
    lines="${e#*$'\t'}"
    lines="${lines%%$'\t'*}"
    path="${e##*$'\t'}"
    inner="$path,$lines,$extra"
    out="${out:+$out,}$(tdg_escape_field "$inner")"
  done
  if [[ -z "$out" ]]; then printf '%s' '-'; else printf '%s' "$out"; fi
}

# trd_row <escaped-query> — the 8-column TSV line for the last trd_decide.
trd_row() {
  local query="${1-}" target="-"
  [[ "$TRD_TARGET" == "-" ]] || target="$(tdg_escape_field "$TRD_TARGET")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$query" "$TRD_VERDICT" "$TRD_REASON" "$target" "$TRD_TARGET_LINES" \
    "$(trd_list_column TRD_CANDIDATES)" \
    "$(trd_list_column TRD_VIABLE)" \
    "$(trd_list_column TRD_EXCLUDED)"
}
