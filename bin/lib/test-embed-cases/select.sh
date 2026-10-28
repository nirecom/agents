# shellcheck shell=bash
# bin/lib/test-embed-cases/select.sh — candidate discovery and skip reasons. Source only.
# tec_candidates fills TEC_CANDIDATES; tec_skip_reason <relpath> sets TEC_SKIP (empty = in band).
# Caller: PWD = repo root, TEC_TMP set, tec_retry_load already run.

# tec_candidates — every case-marker-language file directly in tests/<cat>. Top level only, so
# tests/_archive/ and suite part files in subdirectories never reach the band.
tec_candidates() {
  local cat f
  TEC_CANDIDATES=()
  for cat in $TEC_CATEGORIES; do
    tlr_list_dir_into "tests/$cat" case-marker || continue
    for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do TEC_CANDIDATES+=("$f"); done
  done
  return 0
}

# tec_is_candidate <relpath> — rc 0 when <relpath> is in TEC_CANDIDATES (stage 1 and stage 3).
tec_is_candidate() {
  local c
  for c in ${TEC_CANDIDATES[@]+"${TEC_CANDIDATES[@]}"}; do [[ "$c" != "$1" ]] || return 0; done
  return 1
}

# tec_only_file_select <relpath> — the --only-file band: rc 0 with TEC_ORDER_RELS /
# TEC_ORDER_METRICS set to the one candidate, else tec_die (rc 2) with the first failed check.
tec_only_file_select() {
  local p="$1" cat name
  case "$p" in "" | /* | [A-Za-z]:/* | ./*) tec_die "--only-file $p is not a repo-relative path"; return 2 ;; esac
  case "/$p/" in */../*) tec_die "--only-file $p is not a repo-relative path"; return 2 ;; esac
  [[ -f "$p" ]] || { tec_die "--only-file $p: no such file"; return 2; }
  if tec_is_candidate "$p"; then
    TEC_ORDER_RELS=("$p") TEC_ORDER_METRICS=(selected=only-file)
    return 0
  fi
  cat="${p#tests/}" name="${p#tests/*/}"
  cat="${cat%%/*}"
  if [[ "$p" != tests/* || "$name" == "$p" || "$name" == */* || " $TEC_CATEGORIES " != *" $cat "* ]]; then
    tec_die "--only-file $p is not directly under tests/<category>/ (categories: $TEC_CATEGORIES)"; return 2
  fi
  tlr_match "$p" || { tec_die "--only-file $p: no test language matches this name"; return 2; }
  # Two levels deep and a known language yet not a candidate: its language has no test case reader.
  tec_die "--only-file $p: language $TLR_ID has no test case reader (not an embed candidate)"; return 2
}

# tec_total_tests — the run-all denominator: supported files directly in tests/<cat>.
tec_total_tests() {
  local cat n=0
  for cat in $TEC_CATEGORIES; do
    tlr_list_dir_into "tests/$cat" supported || continue
    n=$((n + ${#TLR_LIST[@]}))
  done
  printf '%s\n' "$n"
}

# tec_marker_state <relpath> — sets TEC_STATE from crr_read (in this shell, so the
# language parts it loads stay loaded for the next file).
tec_marker_state() {
  local line
  crr_read "$PWD/$1" >"$TEC_TMP/crr.tsv"
  IFS= read -r line <"$TEC_TMP/crr.tsv" || line=""
  line="${line#FILE$'\t'}"
  TEC_STATE="${line%%$'\t'*}"
}

# tec_lang_rules <relpath> — rc 0 with TEC_LANG_ID set when the language has caseEmbedRules.
tec_lang_rules() {
  TEC_LANG_ID=""
  tlr_match "$1" || return 1
  [[ "$TLR_STATUS" == supported ]] || return 1
  _tlr_get "$TLR_ID" caseEmbedRules.file || return 1
  TEC_LANG_ID="$TLR_ID"
}

# tec_part <id> <op> <args...> — runs a caseEmbedRules op in this shell; output in TEC_PART_OUT.
tec_part() {
  local id="$1"
  shift
  TEC_PART_OUT=""
  tlr_call_part "$id" caseEmbedRules "$@" >"$TEC_TMP/part.out" || return 1
  TEC_PART_OUT="$(cat "$TEC_TMP/part.out")"
}

# tec_skip_reason <relpath> — the first matching reason in the documented order.
tec_skip_reason() {
  local rel="$1" h
  TEC_SKIP=""
  tec_marker_state "$rel"
  if [[ "$TEC_STATE" == conforming ]]; then TEC_SKIP=already-conforming; return 0; fi
  if ! tec_lang_rules "$rel"; then TEC_SKIP=no-embed-rules; return 0; fi
  if ! tec_part "$TEC_LANG_ID" skip-reason "$PWD/$rel"; then TEC_SKIP="lang-skip:part-failed"; return 0; fi
  if [[ -n "$TEC_PART_OUT" ]]; then TEC_SKIP="lang-skip:${TEC_PART_OUT%%$'\n'*}"; return 0; fi
  if [[ -n "$TEC_RETRY_KEYS" ]]; then
    h="$(git hash-object -- "$rel")"
    if tec_retry_capped "$h" "$rel"; then TEC_SKIP=retry-capped; return 0; fi
  fi
  classify_tests_header "$rel"
  if [[ "$TFM_PRESENT" -ne 1 || "${#TFM_TOKENS[@]}" -eq 0 ]]; then TEC_SKIP=no-tests-header; return 0; fi
  if [[ "$CHR_MULTI_PAREN" -eq 1 ]]; then TEC_SKIP=header-unfixable:multi-paren; return 0; fi
  if [[ "${#CHR_TOKENS_C_A[@]}" -gt 0 || "${#CHR_TOKENS_MRR[@]}" -gt 0 ]]; then
    TEC_SKIP=header-unfixable:has-ac
  fi
  return 0
}
