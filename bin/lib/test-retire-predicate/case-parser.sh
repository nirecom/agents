#!/usr/bin/env bash
# bin/lib/test-retire-predicate/case-parser.sh — source-only; not executable.
# Entrypoint-private sibling of test-retire-predicate.sh (file-split Pattern A):
# the case-boundary parser. GC decisioning stays in the predicate (CPR-SSOT).
# find_renamed_path + FRONTMATTER_TOKEN_VALID_RE come from the predicate's source.
# shellcheck shell=bash

# _trp_parse_fail <line> <reason> — record the first violation (parse phase).
_trp_parse_fail() {
  _TRP_MARKER_MALFORMED=1
  _TRP_MARKER_MALFORMED_LINE="$1"
  _TRP_MARKER_MALFORMED_REASON="$2"
}

# _trp_scan_line <line> — sets _TRP_CODE to the line minus its unquoted comment;
# rc 0 when the line ends inside a ' or " quote. Scans quote state (a ' inside
# "..." is literal, and vice versa; backslash escapes outside single quotes; an
# unquoted word-leading # starts the comment), so balanced mixed quotes such as
# "it's" are not a risk and `; fi` inside a comment is not a closer.
_trp_scan_line() {
  local s="$1" c prev=" " state=0 i n
  _TRP_CODE="$s"
  # Fast path: no comment and no escapes, with no quotes or one kind evenly paired.
  if [[ "$s" != *'#'* && "$s" != *\\* ]]; then
    [[ "$s" != *[\'\"]* ]] && return 1
    local sq="${s//[!\']/}" dq="${s//[!\"]/}"
    if [[ -z "$sq" && $(( ${#dq} % 2 )) -eq 0 ]] || [[ -z "$dq" && $(( ${#sq} % 2 )) -eq 0 ]]; then
      return 1
    fi
  fi
  # state: 0 = unquoted, 1 = in '...', 2 = in "..."
  n="${#s}"
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    case "$state" in
      0)
        case "$c" in
          \\) i=$((i + 1)) ;;
          \') state=1 ;;
          \") state=2 ;;
          '#') if [[ "$prev" == [[:space:]\;\&\|\(\)] ]]; then _TRP_CODE="${s:0:i}"; break; fi ;;
        esac ;;
      1) [[ "$c" == \' ]] && state=0 ;;
      2)
        case "$c" in
          \\) i=$((i + 1)) ;;
          \") state=0 ;;
        esac ;;
    esac
    prev="$c"
  done
  [[ "$state" -ne 0 ]]
}

# _trp_heredoc_term <line> — rc 0 when the line opens a heredoc at an unquoted,
# uncommented `<<` (`<<<` is a herestring). Sets _TRP_HD_TERM to the last such
# terminator (bash reads the bodies in order, so the last one ends them all)
# and _TRP_HD_STRIP to 1 for the `<<-` form.
_trp_heredoc_term() {
  local s="$1" c prev=" " state=0 i n rest arith=0
  # Quoted delimiters take any text (`<<'fixture-text'`), unquoted ones any word
  # (`<<123`, `<<.END`); a `<<` inside (( )) is an arithmetic shift, not a heredoc.
  local re_hd='^(-?)[[:space:]]*('\''([^'\'']*)'\''|"([^"]*)"|\\?([^[:space:];&|<>()'\''"]+))'
  _TRP_HD_TERM=""; _TRP_HD_STRIP=0
  [[ "$s" == *'<<'* ]] || return 1
  n="${#s}"
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    case "$state" in
      0)
        case "$c" in
          \\) i=$((i + 1)) ;;
          \') state=1 ;;
          \") state=2 ;;
          '#') [[ "$prev" == [[:space:]\;\&\|\(\)] ]] && break ;;
          '(') [[ "${s:i+1:1}" == '(' ]] && { arith=$((arith + 1)); i=$((i + 1)); } ;;
          ')') [[ "$arith" -gt 0 && "${s:i+1:1}" == ')' ]] && { arith=$((arith - 1)); i=$((i + 1)); } ;;
          '<')
            if [[ "$arith" -eq 0 && "${s:i+1:1}" == '<' ]]; then
              if [[ "${s:i+2:1}" == '<' ]]; then
                i=$((i + 2))
              else
                rest="${s:i+2}"
                if [[ "$rest" =~ $re_hd ]]; then
                  _TRP_HD_TERM="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
                  [[ -n "${BASH_REMATCH[1]}" ]] && _TRP_HD_STRIP=1 || _TRP_HD_STRIP=0
                fi
                i=$((i + 1))
              fi
            fi ;;
        esac ;;
      1) [[ "$c" == \' ]] && state=0 ;;
      2)
        case "$c" in
          \\) i=$((i + 1)) ;;
          \") state=0 ;;
        esac ;;
    esac
    prev="$c"
  done
  [[ -n "$_TRP_HD_TERM" ]]
}

# trp_parse_case_markers <file> — analysis phase only (no repo root, no survival).
# Sets TRP_HAS_MARKERS, TRP_CASE_COUNT, TRP_CASE_{BEGIN,END}_LINES[],
# TRP_CASE_NAMES[], TRP_CASE_TARGETS[], _TRP_MARKER_MALFORMED,
# _TRP_MARKER_MALFORMED_LINE, _TRP_MARKER_MALFORMED_REASON
# (grammar|depth|target|balance) and _TRP_MARKER_UNCERTAIN (a depth violation
# seen after a possibly multi-line quote). Never eval's marker input.
trp_parse_case_markers() {
  local abs="${1:?trp_parse_case_markers: file required}"

  # Reset contract: every parse-phase output global is cleared first.
  TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_TARGETS=()
  TRP_CASE_NAMES=(); TRP_CASE_COUNT=0; TRP_HAS_MARKERS=0
  _TRP_MARKER_MALFORMED=0; _TRP_MARKER_MALFORMED_LINE=""
  _TRP_MARKER_MALFORMED_REASON=""; _TRP_MARKER_UNCERTAIN=0

  [[ -f "$abs" ]] || return 0

  local re_cand='(^|[^[:alnum:]_])case_(begin|end)([^[:alnum:]_]|$)'
  local re_begin='^case_begin[[:space:]]+"([^"$`\]*)"[[:space:]]+"([^"$`\]*)"([[:space:]]*\|\|[[:space:]]*true)?[[:space:]]*$'
  local re_end='^case_end([[:space:]].*)?$'
  # D1: a body ending in `; fi|done|esac|}` (optionally followed by a redirect,
  # pipe, list tail, further command or comment) closes a block on the same line.
  local re_closer=';[[:space:]]*(fi|done|esac|\})([[:space:]]*([0-9]*[<>]|\||&&|;|#).*)?$'
  # The greedy prefix makes group 1 the LAST closer (`do { :; }; done` → done).
  local re_last_closer="^.*${re_closer}"
  local re_brace_close=';[[:space:]]*\}([[:space:]]*([0-9]*[<>]|\||&&|;|#).*)?$'
  # A line led by a closer word, whatever follows it (`fi # x`, `done < f`, `};`).
  local re_lead_closer='^(fi|done|esac|\})([[:space:]]|;|$)'
  # A brace group or function body opened at the end of the line (`{`, `f() {`,
  # `f(){`), and one opened mid-line (paired with re_brace_close: `f() { :; }`).
  local re_brace_open='(^|[[:space:]]|\))\{$'
  local re_brace_inline='(^|[[:space:]]|\))\{[[:space:]]'

  # Single pass: depth tracking + strict grammar + candidate detection. Marker
  # candidate lines are recognised BEFORE the depth update and never change
  # depth, so case_begin/case_end can never be miscounted as the `case` keyword
  # (C6). Overcounting depth only pushes a marker to malformed → fallback (C8).
  local -a m_kind=() m_name=() m_target=() m_line=()
  local lineno=0 depth=0 quote_risk=0 line trimmed first body own
  local in_heredoc=0 heredoc_term="" heredoc_strip=0 _hd_chk=""
  local _TRP_HD_TERM="" _TRP_HD_STRIP=0 _TRP_CODE=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$in_heredoc" -eq 1 ]]; then
      _hd_chk="$line"
      [[ "$heredoc_strip" -eq 1 ]] && _hd_chk="${_hd_chk#"${_hd_chk%%[![:blank:]]*}"}"
      if [[ "$_hd_chk" == "$heredoc_term" ]]; then in_heredoc=0 heredoc_term="" heredoc_strip=0; fi
      continue
    fi
    if _trp_heredoc_term "$line"; then
      heredoc_term="$_TRP_HD_TERM" heredoc_strip="$_TRP_HD_STRIP" in_heredoc=1
    fi
    if [[ "$line" =~ $re_cand ]]; then
      TRP_HAS_MARKERS=1
      if [[ "$line" =~ $re_begin ]]; then
        local nm="${BASH_REMATCH[1]}" tgt="${BASH_REMATCH[2]}"
        if [[ "$depth" -ne 0 ]]; then
          _trp_parse_fail "$lineno" depth; _TRP_MARKER_UNCERTAIN="$quote_risk"; return 0
        fi
        if [[ ! "$tgt" =~ $FRONTMATTER_TOKEN_VALID_RE \
           || "$tgt" == /* || "$tgt" == '.' || "$tgt" == './' \
           || "$tgt" == '..' || "$tgt" == '../'* \
           || "$tgt" == *'/..' || "$tgt" == *'/../'* ]]; then
          _trp_parse_fail "$lineno" target; return 0
        fi
        m_kind+=(begin); m_name+=("$nm"); m_target+=("$tgt"); m_line+=("$lineno")
      elif [[ "$line" =~ $re_end ]]; then
        if [[ "$depth" -ne 0 ]]; then
          _trp_parse_fail "$lineno" depth; _TRP_MARKER_UNCERTAIN="$quote_risk"; return 0
        fi
        m_kind+=(end); m_name+=(""); m_target+=(""); m_line+=("$lineno")
      else
        # Candidate word-boundary hit but not a strict column-0 marker: indented,
        # post-operator, expanded ($VAR), comment mention, or wrong arg shape.
        _trp_parse_fail "$lineno" grammar; return 0
      fi
      continue
    fi

    # D2: a line that leaves a quote open may start a multi-line quote whose
    # content skews depth from here on (sticky for the rest of the file).
    # Depth is judged on the code alone, so `; fi` in a comment closes nothing.
    _trp_scan_line "$line" && quote_risk=1
    trimmed="${_TRP_CODE#"${_TRP_CODE%%[![:space:]]*}"}"
    first="${trimmed%%[[:space:]]*}"
    body="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$first" in
      if|while|until|for|select|case|function)
        # One-line only when the trailing closer is this opener's own: in
        # `if x; then { :; }` the `}` closes the inner group, not the `if`.
        case "$first" in
          if) own='fi' ;; case) own='esac' ;; function) own='}' ;; *) own='done' ;;
        esac
        [[ "$body" =~ $re_last_closer && "${BASH_REMATCH[1]}" == "$own" ]] || depth=$((depth + 1)) ;;
      *)
        if [[ "$body" =~ $re_brace_open ]]; then
          depth=$((depth + 1))
        elif [[ "$body" =~ $re_brace_inline && "$body" =~ $re_brace_close ]]; then
          :  # opened and closed on this line (`f() { :; }`, `{ a; } > f`)
        elif [[ "$body" =~ $re_lead_closer || "$body" =~ $re_closer ]]; then
          depth=$((depth - 1))
        fi
        ;;
    esac
  done < "$abs"

  [[ "$TRP_HAS_MARKERS" -eq 1 ]] || return 0

  # Balance: strict begin,end,begin,end,… starting with begin, ending with end.
  # A balance violation reports the file's last line.
  local n="${#m_kind[@]}" i expect=begin
  for ((i = 0; i < n; i++)); do
    if [[ "${m_kind[$i]}" != "$expect" ]]; then _trp_parse_fail "$lineno" balance; return 0; fi
    [[ "$expect" == begin ]] && expect=end || expect=begin
  done
  if [[ "$expect" != begin ]]; then _trp_parse_fail "$lineno" balance; return 0; fi

  for ((i = 0; i < n; i += 2)); do
    TRP_CASE_BEGIN_LINES+=("${m_line[$i]}")
    TRP_CASE_END_LINES+=("${m_line[$((i + 1))]}")
    TRP_CASE_NAMES+=("${m_name[$i]}")
    TRP_CASE_TARGETS+=("${m_target[$i]}")
  done
  TRP_CASE_COUNT="${#TRP_CASE_BEGIN_LINES[@]}"
  return 0
}

# trp_enumerate_cases <repo-root> <file> — parse the markers, then resolve each
# case target's survival. Sets the trp_parse_case_markers globals plus
# TRP_CASE_ALIVE[], TRP_ORPHAN_CASE_IDX[] and TRP_REFCOUNT.
trp_enumerate_cases() {
  local repo_root="${1:?trp_enumerate_cases: repo root required}"
  local file="${2:?trp_enumerate_cases: test file required}"

  # Reset contract: unconditional first action — all output globals cleared so a
  # prior file's ranges/names can never leak into this file's verdict.
  TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_TARGETS=()
  TRP_CASE_NAMES=(); TRP_CASE_ALIVE=(); TRP_ORPHAN_CASE_IDX=()
  TRP_CASE_COUNT=0; TRP_REFCOUNT=0; TRP_HAS_MARKERS=0
  TRP_UNIT_MODE="file"; TRP_GC=0; _TRP_MARKER_MALFORMED=0
  _TRP_MARKER_MALFORMED_LINE=""; _TRP_MARKER_MALFORMED_REASON=""; _TRP_MARKER_UNCERTAIN=0

  # C10 extension guard: bash grammar grep is meaningless for .ps1/.py, so the
  # file-level fallback (TRP_HAS_MARKERS=0) is a structural invariant, not luck.
  if [[ "$file" != *.sh ]]; then return 0; fi

  local abs="$file"
  [[ "$abs" != /* ]] && abs="$repo_root/$file" || true
  [[ -f "$abs" ]] || return 0

  trp_parse_case_markers "$abs"
  [[ "$_TRP_MARKER_MALFORMED" -eq 0 && "$TRP_HAS_MARKERS" -eq 1 ]] || return 0

  # Survival: resolve each target against the repo root (rename-tracked, ORTH).
  local saved_pwd="$PWD"
  if ! cd "$repo_root" 2>/dev/null; then
    _TRP_MARKER_MALFORMED=1; _TRP_MARKER_MALFORMED_REASON=target; return 0
  fi
  local alive_count=0 target i
  for i in "${!TRP_CASE_TARGETS[@]}"; do
    target="${TRP_CASE_TARGETS[$i]}"
    if [[ -e "$target" ]] || [[ -n "$(find_renamed_path "$target")" ]]; then
      TRP_CASE_ALIVE+=(1); alive_count=$((alive_count + 1))
    else
      TRP_CASE_ALIVE+=(0); TRP_ORPHAN_CASE_IDX+=("$i")
    fi
  done
  cd "$saved_pwd" 2>/dev/null || true
  TRP_REFCOUNT="$alive_count"
  return 0
}
