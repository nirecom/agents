# shellcheck shell=bash
# bin/lib/test-language-match.sh — source-only. Whether a test is written in the language of the
# code it tests (#2502 S4). The test language is the registry entry its name matches; a target's
# code language is the entry whose codeLanguage takes it (test-route-destination/language.sh), so
# no language name is written here. A target no entry takes (docs, json) is not judged.
# Used by bin/check-test-language-match.sh; the merge 3-way is test-language-match/multi-baseline.sh.
#   tlm_lang_exception <file> <match-path>  the Tags: test-lang-exception declaration
#   tlm_added_cases <head-copy> <work-file> <match-path>  each work case: added or paired
#   tlm_judge <file> <match-path> <head-copy-or-empty>  TEST_LANGUAGE_MISMATCH / CASE_ADDED_WITHOUT_MARKERS
# Callers set TRD_ROOT to the repo root: Tests: tokens and case targets resolve from there.

_tlm_dir="${BASH_SOURCE[0]}"
case "$_tlm_dir" in */*) _tlm_dir="${_tlm_dir%/*}" ;; *) _tlm_dir=. ;; esac
declare -F tlr_load >/dev/null 2>&1 || . "$_tlm_dir/test-language-registry.sh" || return 1
declare -F _trl_token_index >/dev/null 2>&1 || . "$_tlm_dir/test-route-destination/language.sh" || return 1
declare -F crr_read >/dev/null 2>&1 || . "$_tlm_dir/case-record-reader.sh" || return 1
declare -F extract_headers_file >/dev/null 2>&1 || . "$_tlm_dir/test-frontmatter-headers.sh" || return 1
declare -F _tlm_case_addition >/dev/null 2>&1 || . "$_tlm_dir/test-language-match/case-addition.sh" || return 1
declare -F tlm_judge_multi >/dev/null 2>&1 || . "$_tlm_dir/test-language-match/multi-baseline.sh" || return 1

# Category list kept per tool, like test-dup-group.sh (consolidation: #2473); sourcing
# test-route-destination.sh for it costs about a second per hook run.
_TLM_CATEGORIES=" hooks bin skills agents install tests "
TLM_LANG_EXCEPTION=""
TLM_LANG_EXCEPTION_BAD=""
TLM_STATE=""
TLM_CODE_LANG=""
TLM_CODE_SHAPE=""
TLM_TOKENS=()
TLM_C_NAME=(); TLM_C_TARGET=(); TLM_C_LINE=()
TLM_P_KIND=(); TLM_P_HEAD_TARGET=()
_TLM_SEEN=""
_TLM_HITS=0
_TLM_KEYS=(); _TLM_LINES=()
_TLM_CA_REACHED=0

# _tlm_trim <var-name> — trims leading/trailing whitespace (and a CR) in place.
_tlm_trim() {
  local __v="${!1}"
  __v="${__v%$'\r'}"
  __v="${__v#"${__v%%[![:space:]]*}"}"
  __v="${__v%"${__v##*[![:space:]]}"}"
  printf -v "$1" '%s' "$__v"
}

# _tlm_csv_after <line> <label> — TLM_TOKENS: the trimmed, non-empty comma-separated values
# after "<label>:" on a header line (empty for an empty line).
_tlm_csv_after() {
  local csv tok
  local -a parts=()
  TLM_TOKENS=()
  [[ -n "$1" ]] || return 0
  csv="${1#*"$2":}"
  IFS=',' read -r -a parts <<< "$csv"
  for tok in "${parts[@]+"${parts[@]}"}"; do
    _tlm_trim tok
    [[ -n "$tok" ]] && TLM_TOKENS+=("$tok")
  done
  return 0
}

# tlm_lang_exception <file> <match-path> — reads the test-lang-exception:<value> tokens of the
# Tags: line (comment prefix of <match-path>'s entry). rc 0: no declaration, or one value listed
# in the registry's testLanguageExceptions (TLM_LANG_EXCEPTION holds it, empty for none).
# rc 1: a value not listed, or two or more declarations (TLM_LANG_EXCEPTION_BAD holds what was read).
tlm_lang_exception() {
  local tok val n=0 read_vals="" allowed
  TLM_LANG_EXCEPTION=""; TLM_LANG_EXCEPTION_BAD=""
  extract_headers_file "$1" "${2:-$1}"
  _tlm_csv_after "$EXT_TAGS" Tags
  for tok in "${TLM_TOKENS[@]+"${TLM_TOKENS[@]}"}"; do
    case "$tok" in
      test-lang-exception:*)
        val="${tok#test-lang-exception:}"
        _tlm_trim val
        n=$((n + 1))
        read_vals="${read_vals:+$read_vals,}$val" ;;
    esac
  done
  [[ "$n" -eq 0 ]] && return 0
  if [[ "$n" -eq 1 && -n "$read_vals" ]]; then
    for allowed in ${TLR_LANG_EXCEPTIONS-}; do
      if [[ "$allowed" == "$read_vals" ]]; then TLM_LANG_EXCEPTION="$read_vals"; return 0; fi
    done
  fi
  TLM_LANG_EXCEPTION_BAD="$read_vals"
  return 1
}

# _tlm_mismatch <test-language-id> <target> — rc 0 when the target's code language is known and
# is not the test language; sets TLM_CODE_LANG / TLM_CODE_SHAPE (that language's newFileNameShape).
_tlm_mismatch() {
  _trl_token_index "$2" || return 1
  [[ "${_TRL_ID[$_TRL_HIT]}" != "$1" ]] || return 1
  TLM_CODE_LANG="${_TRL_ID[$_TRL_HIT]}"
  TLM_CODE_SHAPE="${_TRL_SHAPE[$_TRL_HIT]}"
  return 0
}

# _tlm_cases <file> <match-path> — TLM_STATE: the crr_read FILE state; TLM_C_NAME / TLM_C_TARGET /
# TLM_C_LINE: the CASE records in file order (filled only when conforming). The fields are cut
# with parameter expansion: a tab is IFS whitespace, so read would merge empty fields.
_tlm_cases() {
  local out line rest tab=$'\t'
  TLM_STATE=""; TLM_C_NAME=(); TLM_C_TARGET=(); TLM_C_LINE=()
  out="$(crr_read "$1" "$2" || true)"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      FILE"$tab"*) rest="${line#FILE"$tab"}"; TLM_STATE="${rest%%"$tab"*}" ;;
      CASE"$tab"*)
        rest="${line#CASE"$tab"}"
        TLM_C_NAME+=("${rest%%"$tab"*}"); rest="${rest#*"$tab"}"
        TLM_C_TARGET+=("${rest%%"$tab"*}"); rest="${rest#*"$tab"}"
        TLM_C_LINE+=("${rest%%"$tab"*}") ;;
    esac
  done <<< "$out"
  if [[ "$TLM_STATE" != conforming ]]; then TLM_C_NAME=(); TLM_C_TARGET=(); TLM_C_LINE=(); fi
  return 0
}

# _tlm_pair <head-copy> <work-file> <match-path> — pairs each work case with its HEAD case.
# Leaves the work cases in TLM_C_* and sets TLM_P_KIND[i] (added|paired) and TLM_P_HEAD_TARGET[i].
# Same name → paired. A name HEAD lacks pairs, in file order and 1:1, with a vanished HEAD case
# (its name gone from the work version) of the same target; anything left is added.
# rc 1 when either version is not conforming.
_tlm_pair() {
  local i j found
  local -a h_name=() h_target=() h_used=()
  TLM_P_KIND=(); TLM_P_HEAD_TARGET=()
  _tlm_cases "$1" "$3"
  [[ "$TLM_STATE" == conforming ]] || return 1
  h_name=("${TLM_C_NAME[@]+"${TLM_C_NAME[@]}"}"); h_target=("${TLM_C_TARGET[@]+"${TLM_C_TARGET[@]}"}")
  _tlm_cases "$2" "$3"
  [[ "$TLM_STATE" == conforming ]] || return 1
  # A HEAD case whose name the work version still has is not vanished: mark it used.
  for i in "${!h_name[@]}"; do
    h_used[i]=0
    for j in "${!TLM_C_NAME[@]}"; do
      if [[ "${TLM_C_NAME[$j]}" == "${h_name[$i]}" ]]; then h_used[i]=1; break; fi
    done
  done
  for i in "${!TLM_C_NAME[@]}"; do
    found=""
    for j in "${!h_name[@]}"; do
      if [[ "${h_name[$j]}" == "${TLM_C_NAME[$i]}" ]]; then found="$j"; break; fi
    done
    if [[ -z "$found" ]]; then
      for j in "${!h_name[@]}"; do
        if [[ "${h_used[$j]}" -eq 0 && "${h_target[$j]}" == "${TLM_C_TARGET[$i]}" ]]; then
          found="$j"; h_used[j]=1; break
        fi
      done
    fi
    if [[ -n "$found" ]]; then
      TLM_P_KIND[i]=paired; TLM_P_HEAD_TARGET[i]="${h_target[$found]}"
    else
      TLM_P_KIND[i]=added; TLM_P_HEAD_TARGET[i]=""
    fi
  done
  return 0
}

# tlm_added_cases <head-copy> <work-file> <match-path> — one line per work case, in file order:
# added\t<name>\t<target>  or  paired\t<name>\t<target>\t<head-target>. rc 1 when either
# version is not conforming (nothing printed).
tlm_added_cases() {
  local i
  _tlm_pair "$1" "$2" "$3" || return 1
  for i in "${!TLM_C_NAME[@]}"; do
    if [[ "${TLM_P_KIND[$i]}" == added ]]; then
      printf 'added\t%s\t%s\n' "${TLM_C_NAME[$i]}" "${TLM_C_TARGET[$i]}"
    else
      printf 'paired\t%s\t%s\t%s\n' "${TLM_C_NAME[$i]}" "${TLM_C_TARGET[$i]}" "${TLM_P_HEAD_TARGET[$i]}"
    fi
  done
  return 0
}

# _tlm_report <name> <test-language-id> <line-or-empty> <target> — one HIGH line per target and
# file (the caller keeps _TLM_SEEN).
_tlm_report() {
  # Every occurrence is kept before the dedup: the merge 3-way (multi-baseline.sh) counts them.
  if [[ -n "$3" ]]; then _TLM_KEYS+=("case:$4"); else _TLM_KEYS+=("hdr:$4"); fi
  _TLM_LINES+=("HIGH: $1${3:+ line $3}: test language $2 does not match code language $TLM_CODE_LANG of $4 (new file shape: $TLM_CODE_SHAPE) code=TEST_LANGUAGE_MISMATCH")
  case "$_TLM_SEEN" in *$'\n'"$4"$'\n'*) return 0 ;; esac
  _TLM_SEEN="$_TLM_SEEN$4"$'\n'
  echo "${_TLM_LINES[${#_TLM_LINES[@]}-1]}"
  _TLM_HITS=1
}

# _tlm_entrypoint <match-path> <test-id> — rc 0 for a test entrypoint the case-marker gate also
# judges: exactly tests/<category>/<name>, an entry with a caseMarkerReader, and its helperLibrary
# present under TRD_ROOT.
_tlm_entrypoint() {
  local rest="${1#tests/}" name
  [[ "$rest" != "$1" && "$rest" == */* ]] || return 1
  name="${rest#*/}"
  [[ -n "$name" && "$name" != */* && "$_TLM_CATEGORIES" == *" ${rest%%/*} "* ]] || return 1
  _tlr_get "$2" caseMarkerReader.file && _tlr_get "$2" helperLibrary.path && [[ -f "${TRD_ROOT:-.}/$_TLR_V" ]]
}

# _tlm_header_targets <file> <match-path> — TLM_TOKENS: the Tests: header tokens.
_tlm_header_targets() {
  extract_headers_file "$1" "$2"
  _tlm_csv_after "$EXT_TESTS" Tests
}

# _tlm_header_new <head-copy-or-empty> <file> <match-path> <test-id> — reports each mismatched
# Tests: token of <file> whose key (one leading ./ dropped) HEAD's header lacks.
_tlm_header_new() {
  local tok key known=$'\n'
  if [[ -n "$1" ]]; then
    _tlm_header_targets "$1" "$3"
    for tok in "${TLM_TOKENS[@]+"${TLM_TOKENS[@]}"}"; do known="$known${tok#./}"$'\n'; done
  fi
  _tlm_header_targets "$2" "$3"
  for tok in "${TLM_TOKENS[@]+"${TLM_TOKENS[@]}"}"; do
    key="${tok#./}"
    case "$known" in *$'\n'"$key"$'\n'*) continue ;; esac
    if _tlm_mismatch "$4" "$tok"; then _tlm_report "$3" "$4" "" "$tok"; fi
  done
}

# _tlm_migration <head-copy> <work-file> <match-path> <test-id> — markers put into a HEAD that was
# not conforming: rc 1 unless that is the shape. Otherwise every work case target is judged
# (begin line attached), except a key HEAD's Tests: header already held — an existing state.
_tlm_migration() {
  local tok i known=$'\n'
  _tlm_cases "$1" "$3"
  [[ "$TLM_STATE" != conforming ]] || return 1
  _tlm_cases "$2" "$3"
  [[ "$TLM_STATE" == conforming ]] || return 1
  local -a w_target=("${TLM_C_TARGET[@]+"${TLM_C_TARGET[@]}"}") w_line=("${TLM_C_LINE[@]+"${TLM_C_LINE[@]}"}")
  _tlm_header_targets "$1" "$3"
  for tok in "${TLM_TOKENS[@]+"${TLM_TOKENS[@]}"}"; do known="$known${tok#./}"$'\n'; done
  for i in "${!w_target[@]}"; do
    case "$known" in *$'\n'"${w_target[$i]}"$'\n'*) continue ;; esac
    if _tlm_mismatch "$4" "${w_target[$i]}"; then _tlm_report "$3" "$4" "${w_line[$i]}" "${w_target[$i]}"; fi
  done
  return 0
}

# tlm_judge <file> <match-path> <head-copy-or-empty> — prints a TEST_LANGUAGE_MISMATCH line per
# mismatched target that is new — a Tests: token HEAD's header lacks (every token for a new file
# with an empty <head-copy>), an added case's target, a paired case's target turned mismatched —
# and, when either version is not conforming, a CASE_ADDED_WITHOUT_MARKERS line for a case added.
# Not by case addition: a file that is not a test entrypoint (_tlm_entrypoint; run-all.sh and
# suite parts are not), a file (new or existing) whose working Tests: has exactly one token, and
# markers put into a HEAD that had none valid (_tlm_migration).
# rc 0: none; 1: printed; 2: the code-language table is unreadable; 3: the test language is not
# a supported entry (nothing judged).
tlm_judge() {
  local file="$1" match="$2" head="${3:-}" test_id i n_tok entry=0
  _TLM_SEEN=$'\n'; _TLM_HITS=0; _TLM_KEYS=(); _TLM_LINES=(); _TLM_CA_REACHED=0
  _trl_init || return 2
  if ! tlr_match "$match" || [[ "$TLR_STATUS" != supported ]]; then return 3; fi
  test_id="$TLR_ID"
  _tlm_entrypoint "$match" "$test_id" && entry=1
  _tlm_header_new "$head" "$file" "$match" "$test_id"
  n_tok="${#TLM_TOKENS[@]}"
  if [[ -z "$head" ]]; then
    _tlm_cases "$file" "$match"
    if [[ "$entry" -eq 1 && "$TLM_STATE" != conforming && "$n_tok" -ne 1 ]]; then _tlm_case_addition "" "$file" "$match"; fi
    for i in "${!TLM_C_TARGET[@]}"; do
      if _tlm_mismatch "$test_id" "${TLM_C_TARGET[$i]}"; then
        _tlm_report "$match" "$test_id" "${TLM_C_LINE[$i]}" "${TLM_C_TARGET[$i]}"
      fi
    done
  elif _tlm_pair "$head" "$file" "$match"; then
    for i in "${!TLM_C_TARGET[@]}"; do
      _tlm_mismatch "$test_id" "${TLM_C_TARGET[$i]}" || continue
      if [[ "${TLM_P_KIND[$i]}" == paired ]]; then
        # The HEAD case already sat on mismatched code: an existing state, not a new one.
        # (A failed lookup leaves TLM_CODE_* as the work target set them.)
        if _tlm_mismatch "$test_id" "${TLM_P_HEAD_TARGET[$i]}"; then continue; fi
      fi
      _tlm_report "$match" "$test_id" "${TLM_C_LINE[$i]}" "${TLM_C_TARGET[$i]}"
    done
  elif ! _tlm_migration "$head" "$file" "$match" "$test_id" && [[ "$entry" -eq 1 && "$n_tok" -ne 1 ]]; then
    _tlm_case_addition "$head" "$file" "$match"
  fi
  [[ "$_TLM_HITS" -eq 1 ]] && return 1
  return 0
}
