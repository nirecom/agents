# shellcheck shell=bash
# bin/lib/test-language-parts/case-embed-common.sh — the shared body of the caseEmbedRules parts
# whose answers come from an analyzer child process (pester, pytest, js). Source only.
# A part calls cec_dispatch <id> <op> [abs] [args] with CEC_LAUNCH set to the analyzer's launch
# command (runtime first); the analyzer is called as `<op> <native-abs> [args]`.
# Op contract and the case-order contract: docs/architecture/claude-code/test-language-registry/case-embed-ops.md.

declare -F crb_native_path >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../case-reader-bridge.sh"

# cec_helper_path <id> — sets CEC_HELPER to the native path of entry <id>'s helperLibrary.path
# (empty when none). Keyed by the part's entry, so a temp copy under any name finds the helper.
cec_helper_path() {
  _tlr_get "$1" helperLibrary.path || _TLR_V=""
  CEC_HELPER=""
  if [[ -n "$_TLR_V" ]]; then crb_native_path "$TLR_REPO_ROOT/$_TLR_V"; CEC_HELPER="$CRB_PATH"; fi
}

# cec_order_filter <deps-output> — checks the leading ORDER\t<idx>\t<begin>\t<end> lines against
# the TRP_CASE_BEGIN_LINES / TRP_CASE_END_LINES the test case reader left, then prints the other
# lines. rc 1 (and `case-embed: order mismatch` on stderr) when they disagree.
cec_order_filter() {
  local line n=0 tab=$'\t'
  local -a rest=() col=()
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    if [[ "$line" == "ORDER$tab"* ]]; then
      IFS="$tab" read -r -a col <<<"$line"
      if [[ "${col[1]:-}" != "$n" || "${col[2]:-}" != "${TRP_CASE_BEGIN_LINES[$n]:-}" || "${col[3]:-}" != "${TRP_CASE_END_LINES[$n]:-}" ]]; then
        n=-1; break
      fi
      n=$((n + 1))
    else
      rest+=("$line")
    fi
  done <<<"$1"
  if [[ "$n" -ne "${#TRP_CASE_BEGIN_LINES[@]}" ]]; then
    printf 'case-embed: order mismatch (the analyzer and the test case reader disagree on the cases)\n' >&2
    return 1
  fi
  [[ "${#rest[@]}" -eq 0 ]] || printf '%s\n' "${rest[@]}"
}

# cec_print <output> — the output's non-empty lines, a trailing CR dropped.
cec_print() {
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] || printf '%s\n' "$line"
  done <<<"$1"
}

# cec_launch <op> <abs> [args] — runs the analyzer once; its stdout in CEC_OUT. rc: the analyzer's.
cec_launch() {
  local op="$1" abs="$2"
  shift 2
  crb_native_path "$abs"
  CEC_OUT="$("${CEC_LAUNCH[@]}" "$op" "$CRB_PATH" "$@")"
}

# cec_analyzer_args <id> <op> — sets CEC_ARGS to the extra analyzer arguments of the op
# (self-impl takes the helper library path).
cec_analyzer_args() {
  CEC_ARGS=()
  if [[ "$2" == self-impl ]]; then cec_helper_path "$1"; CEC_ARGS=("$CEC_HELPER"); fi
}

# cec_answer <op> <output> — prints the op's answer from the analyzer's output (deps: checked).
cec_answer() {
  if [[ "$1" == deps ]]; then cec_order_filter "$2"; else cec_print "$2"; fi
}

# cec_result_summary <rc> <stdout-file> — `<class>\t<passed>\t<failed>` for one wrapper run: the
# class from the run-all exit rule (0 pass, 77 skip, else fail); the counts from CEC_COUNT
# `<fn> <stdout-file>`, which sets CEC_PASS / CEC_FAIL (both empty when the output has no count).
cec_result_summary() {
  local cls
  case "$1" in 0) cls=pass ;; 77) cls=skip ;; *) cls=fail ;; esac
  CEC_PASS="" CEC_FAIL=""
  if [[ -f "$2" && -n "${CEC_COUNT:-}" ]]; then "$CEC_COUNT" "$2"; fi
  printf '%s\t%s\t%s\n' "$cls" "$CEC_PASS" "$CEC_FAIL"
}

# cec_count_line <stdout-file> <regex> — CEC_PASS / CEC_FAIL from the last line matching <regex>,
# whose BASH_REMATCH[1] and [2] are the passed and failed counts. Colour codes (Pester writes
# them between the counts even into a file) and CR are removed before the match.
cec_count_line() {
  local line sgr=$'\e''\[[0-9;]*m'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    while [[ "$line" =~ $sgr ]]; do line="${line/"${BASH_REMATCH[0]}"/}"; done
    if [[ "$line" =~ $2 ]]; then CEC_PASS="${BASH_REMATCH[1]}" CEC_FAIL="${BASH_REMATCH[2]}"; fi
  done <"$1"
}

# cec_dispatch <id> <op> [abs] [args] — rc 0 answered, 1 the analyzer failed, the case order
# disagrees or the file does not parse (syntax-check; the reason on stderr), 2 unknown op or a
# missing argument, 69 the runtime (CEC_LAUNCH[0]) is not on PATH.
# CEC_FETCH, when set, names the function `<fn> <id> <op> <abs>` that fills CEC_OUT (the pester
# cache); syntax-check bypasses it, since its file is a fresh rewrite the cache never saw.
# deps checks the order against the TRP_CASE_* globals crr_read left; with none, it runs the reader.
cec_dispatch() {
  local id="$1" op="${2:-}" abs="${3:-}"
  case "$op" in
    rules-doc) printf 'skills/sweep-tests/embed-rules/%s.md\n' "$id"; return 0 ;;
    result-summary)
      if [[ -z "$abs" || -z "${4:-}" ]]; then printf '[%s-case-embed] result-summary: rc and stdout file required\n' "$id" >&2; return 2; fi
      cec_result_summary "$abs" "$4"; return 0 ;;
    deps | leftover-defs | self-impl | skip-reason | syntax-check | case-count) ;;
    *) printf '[%s-case-embed] unknown op: %s\n' "$id" "$op" >&2; return 2 ;;
  esac
  if [[ -z "$abs" ]]; then printf '[%s-case-embed] %s: file required\n' "$id" "$op" >&2; return 2; fi
  command -v "${CEC_LAUNCH[0]:?cec_dispatch: CEC_LAUNCH required}" >/dev/null 2>&1 || return 69
  if [[ "$op" == syntax-check ]]; then
    cec_launch syntax-check "$abs" >/dev/null || return 1
    return 0
  fi
  if [[ "$op" == deps && "${#TRP_CASE_BEGIN_LINES[@]}" -eq 0 ]]; then
    # Called outside crr_read: the test case reader fills locals that shadow the caller's globals.
    # shellcheck disable=SC2034  # the reader part sets them all; the order check reads two
    local -a TRP_CASE_BEGIN_LINES=() TRP_CASE_END_LINES=() TRP_CASE_NAMES=() TRP_CASE_TARGETS=()
    # shellcheck disable=SC2034
    local TRP_CASE_COUNT=0 TRP_HAS_MARKERS=0 _TRP_MARKER_MALFORMED=0 _TRP_MARKER_MALFORMED_LINE=""
    local _TRP_MARKER_MALFORMED_REASON="" _TRP_MARKER_UNCERTAIN=0
    tlr_call_part "$id" caseMarkerReader "$abs" || return 1
  fi
  if [[ -n "${CEC_FETCH:-}" ]]; then
    "$CEC_FETCH" "$id" "$op" "$abs" || return 1
  else
    cec_analyzer_args "$id" "$op"
    cec_launch "$op" "$abs" ${CEC_ARGS[@]+"${CEC_ARGS[@]}"} || return 1
  fi
  cec_answer "$op" "$CEC_OUT"
}
