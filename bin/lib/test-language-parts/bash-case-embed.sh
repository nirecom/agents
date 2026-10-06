# shellcheck shell=bash
# bin/lib/test-language-parts/bash-case-embed.sh — the bash entry's caseEmbedRules part. Source only.
# bash_case_embed <op> <abs-file> [args]: the per-language answers the case-embed verifier asks
# (rules-doc, deps, leftover-defs, self-impl, skip-reason, result-summary <rc> <stdout-file>).
# Same-shell contract: deps and leftover-defs read the TRP_CASE_* globals that the bash
# caseMarkerReader left for this file (crr_read calls it first); they never re-parse case ranges.
# The static analysis is an approximation: eval, indirect calls and sourced helpers stay unseen.

if ! declare -F _trp_heredoc_term >/dev/null 2>&1; then
  # shellcheck source=../test-retire-predicate/case-parser.sh
  . "${BASH_SOURCE[0]%/*}/../test-retire-predicate/case-parser.sh"
fi

_BCE_CODE=()
_BCE_DEF_NAME=()
_BCE_DEF_LINE=()

# _bce_in_case <line> — rc 0 when the line lies strictly inside a case range.
_bce_in_case() {
  local i=0 n="${#TRP_CASE_BEGIN_LINES[@]}"
  while [[ "$i" -lt "$n" ]]; do
    if [[ "$1" -gt "${TRP_CASE_BEGIN_LINES[$i]}" && "$1" -lt "${TRP_CASE_END_LINES[$i]}" ]]; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

# _bce_scan <file> — fills _BCE_CODE[line] (comment-stripped code; empty for a heredoc body or
# terminator) and the column-0 function definitions outside every case. A definition line keeps
# only the text after the definition, so a one-line body still references what it calls.
_bce_scan() {
  local line lineno=0 code in_hd=0 term="" strip=0 chk
  local re_def1='^([A-Za-z_][A-Za-z0-9_:.-]*)[[:space:]]*\(\)' re_def2='^function[[:space:]]+([A-Za-z_][A-Za-z0-9_:.-]*)'
  local _TRP_HD_TERM="" _TRP_HD_STRIP=0 _TRP_CODE=""
  _BCE_CODE=(""); _BCE_DEF_NAME=(); _BCE_DEF_LINE=()
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$in_hd" -eq 1 ]]; then
      chk="$line"
      [[ "$strip" -eq 1 ]] && chk="${chk#"${chk%%[![:blank:]]*}"}"
      [[ "$chk" == "$term" ]] && in_hd=0
      _BCE_CODE+=("")
      continue
    fi
    if _trp_heredoc_term "$line"; then in_hd=1; term="$_TRP_HD_TERM"; strip="$_TRP_HD_STRIP"; fi
    _trp_scan_line "$line" || true
    code="$_TRP_CODE"
    if [[ "$code" =~ $re_def1 || "$code" =~ $re_def2 ]] && ! _bce_in_case "$lineno"; then
      _BCE_DEF_NAME+=("${BASH_REMATCH[1]}"); _BCE_DEF_LINE+=("$lineno")
      code="${code:${#BASH_REMATCH[0]}}"
    fi
    while [[ "$code" =~ (\$\{?[A-Za-z_][A-Za-z0-9_]*) ]]; do code="${code/"${BASH_REMATCH[1]}"/\$}"; done
    _BCE_CODE+=("$code")
  done <"$1"
}

# _bce_refers <line> <name> — rc 0 when that code line calls <name> (word-bounded, not a variable).
_bce_refers() {
  local re="(^|[^A-Za-z0-9_])${2//./\\.}([^A-Za-z0-9_]|$)"
  [[ "${_BCE_CODE[$1]}" =~ $re ]]
}

_bce_deps() {
  local i=0 d l csv
  _bce_scan "$1"
  while [[ "$i" -lt "${#TRP_CASE_BEGIN_LINES[@]}" ]]; do
    csv=""; d=0
    while [[ "$d" -lt "${#_BCE_DEF_NAME[@]}" ]]; do
      l=$((TRP_CASE_BEGIN_LINES[i] + 1))
      while [[ "$l" -lt "${TRP_CASE_END_LINES[$i]}" ]]; do
        if _bce_refers "$l" "${_BCE_DEF_NAME[$d]}"; then csv="${csv:+$csv,}${_BCE_DEF_NAME[$d]}"; break; fi
        l=$((l + 1))
      done
      d=$((d + 1))
    done
    printf '%s\t%s\n' "$i" "$csv"
    i=$((i + 1))
  done
}

_bce_leftover_defs() {
  local d=0 l used
  _bce_scan "$1"
  while [[ "$d" -lt "${#_BCE_DEF_NAME[@]}" ]]; do
    used=0; l=1
    while [[ "$l" -lt "${#_BCE_CODE[@]}" ]]; do
      if _bce_refers "$l" "${_BCE_DEF_NAME[$d]}"; then used=1; break; fi
      l=$((l + 1))
    done
    [[ "$used" -eq 1 ]] || printf '%s\t%s\n' "${_BCE_DEF_LINE[$d]}" "${_BCE_DEF_NAME[$d]}"
    d=$((d + 1))
  done
}

# _bce_helper_path <file> — the helperLibrary.path of the file's registry entry (empty when none).
_bce_helper_path() {
  local id="${TLR_ID:-}" st="${TLR_STATUS:-}"
  _TLR_V=""
  tlr_match "$1" && { _tlr_get "$TLR_ID" helperLibrary.path || true; }
  TLR_ID="$id"; TLR_STATUS="$st"
  _BCE_HELPER="$_TLR_V"
}

_bce_self_impl() {
  local helper names=" " hl l code name re_def='^(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:.-]*)[[:space:]]*(\(\)|\{)'
  _bce_helper_path "$1"; helper="$_BCE_HELPER"
  if [[ -n "$helper" && -f "$TLR_REPO_ROOT/$helper" ]]; then
    while IFS= read -r hl || [[ -n "$hl" ]]; do
      [[ "$hl" =~ $re_def ]] && names="$names${BASH_REMATCH[2]} "
    done <"$TLR_REPO_ROOT/$helper"
  fi
  _bce_scan "$1"
  l=1
  while [[ "$l" -lt "${#_BCE_CODE[@]}" ]]; do
    code="${_BCE_CODE[$l]}"
    if [[ "$code" =~ ^[[:space:]]*(PASS|FAIL)=0([[:space:]\;]|$) ]]; then
      printf '%s\tcounter-init\t%s=0\n' "$l" "${BASH_REMATCH[1]}"
    fi
    l=$((l + 1))
  done
  local d=0
  while [[ "$d" -lt "${#_BCE_DEF_NAME[@]}" ]]; do
    name="${_BCE_DEF_NAME[$d]}"
    [[ "$names" == *" $name "* ]] && printf '%s\tharness-redef\t%s\n' "${_BCE_DEF_LINE[$d]}" "$name"
    d=$((d + 1))
  done
  return 0
}

# _bce_skip_reason <file> — narrow-harness when a sourced tests/lib/*harness*.sh is not the
# entry's shared helper library. A `../lib/x.sh` path counts as tests/lib/x.sh.
_bce_skip_reason() {
  local helper l code arg rel
  local re_src='^[[:space:]]*(source|\.)[[:space:]]+(.+)$' re_path='([^[:space:]"'\'']*/)?([^/[:space:]"'\'']+\.sh)'
  _bce_helper_path "$1"; helper="$_BCE_HELPER"
  _bce_scan "$1"
  l=1
  while [[ "$l" -lt "${#_BCE_CODE[@]}" ]]; do
    code="${_BCE_CODE[$l]}"
    l=$((l + 1))
    [[ "$code" =~ $re_src ]] || continue
    arg="${BASH_REMATCH[2]}"
    [[ "$arg" =~ $re_path ]] || continue
    case "${BASH_REMATCH[1]}" in
      */tests/lib/ | tests/lib/ | */../lib/ | ../lib/) rel="tests/lib/${BASH_REMATCH[2]}" ;;
      *) continue ;;
    esac
    # shellcheck disable=SC2053 # the glob is the bash part's narrow-harness rule
    if [[ "$rel" == tests/lib/*harness*.sh && "$rel" != "$helper" ]]; then
      printf 'narrow-harness\n'
      return 0
    fi
  done
  return 0
}

_bce_result_summary() {
  local rc="$1" out="$2" cls p="" f="" line re='Results:[[:space:]]*([0-9]+)[[:space:]]+passed,[[:space:]]*([0-9]+)[[:space:]]+failed'
  case "$rc" in 77) cls=skip ;; 0) cls=pass ;; *) cls=fail ;; esac
  if [[ -f "$out" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ $re ]] && { p="${BASH_REMATCH[1]}"; f="${BASH_REMATCH[2]}"; }
    done <"$out"
  fi
  printf '%s\t%s\t%s\n' "$cls" "$p" "$f"
}

bash_case_embed() {
  local op="${1:-}"
  shift || true
  case "$op" in
    rules-doc) printf '%s\n' "skills/sweep-tests/embed-rules/bash.md" ;;
    deps) _bce_deps "${1:?bash_case_embed deps: file required}" ;;
    leftover-defs) _bce_leftover_defs "${1:?bash_case_embed leftover-defs: file required}" ;;
    self-impl) _bce_self_impl "${1:?bash_case_embed self-impl: file required}" ;;
    skip-reason) _bce_skip_reason "${1:?bash_case_embed skip-reason: file required}" ;;
    result-summary) _bce_result_summary "${1:?bash_case_embed result-summary: rc required}" "${2:?bash_case_embed result-summary: stdout file required}" ;;
    *) printf '[bash-case-embed] unknown op: %s\n' "$op" >&2; return 2 ;;
  esac
}
