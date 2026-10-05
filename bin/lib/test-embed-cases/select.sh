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
