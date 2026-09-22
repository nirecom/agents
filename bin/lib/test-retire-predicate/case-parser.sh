#!/usr/bin/env bash
# bin/lib/test-retire-predicate/case-parser.sh — source-only; not executable.
# Entrypoint-private sibling of test-retire-predicate.sh (file-split Pattern A):
# the case-boundary parser. GC decisioning stays in the predicate (CPR-SSOT).
# find_renamed_path + FRONTMATTER_TOKEN_VALID_RE come from the predicate's source.
# shellcheck shell=bash

# trp_enumerate_cases <repo-root> <file> — enumerate case_begin/case_end markers.
# Sets TRP_HAS_MARKERS, TRP_CASE_COUNT, TRP_CASE_{BEGIN,END}_LINES[],
# TRP_CASE_NAMES[], TRP_CASE_TARGETS[], TRP_CASE_ALIVE[], TRP_ORPHAN_CASE_IDX[],
# TRP_REFCOUNT, and _TRP_MARKER_MALFORMED. Never eval's marker input.
trp_enumerate_cases() {
  local repo_root="${1:?trp_enumerate_cases: repo root required}"
  local file="${2:?trp_enumerate_cases: test file required}"

  # Reset contract: unconditional first action — all output globals cleared so a
  # prior file's ranges/names can never leak into this file's verdict.
  TRP_CASE_BEGIN_LINES=(); TRP_CASE_END_LINES=(); TRP_CASE_TARGETS=()
  TRP_CASE_NAMES=(); TRP_CASE_ALIVE=(); TRP_ORPHAN_CASE_IDX=()
  TRP_CASE_COUNT=0; TRP_REFCOUNT=0; TRP_HAS_MARKERS=0
  TRP_UNIT_MODE="file"; TRP_GC=0; _TRP_MARKER_MALFORMED=0

  # C10 extension guard: bash grammar grep is meaningless for .ps1/.py, so the
  # file-level fallback (TRP_HAS_MARKERS=0) is a structural invariant, not luck.
  if [[ "$file" != *.sh ]]; then return 0; fi

  local abs="$file"
  [[ "$abs" != /* ]] && abs="$repo_root/$file" || true
  [[ -f "$abs" ]] || return 0

  local re_cand='(^|[^[:alnum:]_])case_(begin|end)([^[:alnum:]_]|$)'
  local re_begin='^case_begin[[:space:]]+"([^"$`\]*)"[[:space:]]+"([^"$`\]*)"([[:space:]]*\|\|[[:space:]]*true)?[[:space:]]*$'
  local re_end='^case_end([[:space:]].*)?$'

  # Single pass: depth tracking + strict grammar + candidate detection. Marker
  # candidate lines are recognised BEFORE the depth update and never change
  # depth, so case_begin/case_end can never be miscounted as the `case` keyword
  # (C6). Overcounting depth only pushes a marker to malformed → fallback (C8).
  local -a m_kind=() m_name=() m_target=() m_line=()
  local lineno=0 depth=0 line trimmed first body
  local in_heredoc=0 heredoc_term="" heredoc_strip=0
  local _hd_chk="" _hd_after="" _hd_pfx="" _hd_term=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$in_heredoc" -eq 1 ]]; then
      _hd_chk="$line"
      [[ "$heredoc_strip" -eq 1 ]] && _hd_chk="${_hd_chk#"${_hd_chk%%[![:blank:]]*}"}"
      if [[ "$_hd_chk" == "$heredoc_term" ]]; then in_heredoc=0 heredoc_term="" heredoc_strip=0; fi
      continue
    fi
    _hd_after="${line##*<<}"
    if [[ "$line" == *'<<'* && "$line" != *'<<<'* && "$_hd_after" != "$line" ]]; then
      _hd_after="${_hd_after#-}"
      _hd_pfx="${_hd_after%%[A-Za-z_]*}"
      _hd_after="${_hd_after#"$_hd_pfx"}"
      _hd_term="${_hd_after%%[^A-Za-z0-9_]*}"
      if [[ -n "$_hd_term" ]]; then
        heredoc_term="$_hd_term"
        [[ "${line##*<<}" == -* ]] && heredoc_strip=1 || heredoc_strip=0
        in_heredoc=1
      fi
    fi
    if [[ "$line" =~ $re_cand ]]; then
      TRP_HAS_MARKERS=1
      if [[ "$line" =~ $re_begin ]]; then
        local nm="${BASH_REMATCH[1]}" tgt="${BASH_REMATCH[2]}"
        if [[ ! "$tgt" =~ $FRONTMATTER_TOKEN_VALID_RE || "$depth" -ne 0 \
           || "$tgt" == /* || "$tgt" == '.' || "$tgt" == './' \
           || "$tgt" == '..' || "$tgt" == '../'* \
           || "$tgt" == *'/..' || "$tgt" == *'/../'* ]]; then
          _TRP_MARKER_MALFORMED=1; return 0
        fi
        m_kind+=(begin); m_name+=("$nm"); m_target+=("$tgt"); m_line+=("$lineno")
      elif [[ "$line" =~ $re_end ]]; then
        if [[ "$depth" -ne 0 ]]; then _TRP_MARKER_MALFORMED=1; return 0; fi
        m_kind+=(end); m_name+=(""); m_target+=(""); m_line+=("$lineno")
      else
        # Candidate word-boundary hit but not a strict column-0 marker: indented,
        # post-operator, expanded ($VAR), comment mention, or wrong arg shape.
        _TRP_MARKER_MALFORMED=1; return 0
      fi
      continue
    fi

    trimmed="${line#"${line%%[![:space:]]*}"}"
    first="${trimmed%%[[:space:]]*}"
    body="${trimmed%"${trimmed##*[![:space:]]}"}"
    case "$first" in
      if|while|until|for|case|function) depth=$((depth + 1)) ;;
      *)
        if [[ "$body" == "{" || "$body" == *" {" ]]; then
          depth=$((depth + 1))
        elif [[ "$body" == "fi" || "$body" == "done" || "$body" == "esac" || "$body" == "}" ]]; then
          depth=$((depth - 1))
        fi
        ;;
    esac
  done < "$abs"

  [[ "$TRP_HAS_MARKERS" -eq 1 ]] || return 0

  # Balance: strict begin,end,begin,end,… starting with begin, ending with end.
  local n="${#m_kind[@]}" i expect=begin
  for ((i = 0; i < n; i++)); do
    [[ "${m_kind[$i]}" == "$expect" ]] || { _TRP_MARKER_MALFORMED=1; return 0; }
    [[ "$expect" == begin ]] && expect=end || expect=begin
  done
  [[ "$expect" == begin ]] || { _TRP_MARKER_MALFORMED=1; return 0; }

  for ((i = 0; i < n; i += 2)); do
    TRP_CASE_BEGIN_LINES+=("${m_line[$i]}")
    TRP_CASE_END_LINES+=("${m_line[$((i + 1))]}")
    TRP_CASE_NAMES+=("${m_name[$i]}")
    TRP_CASE_TARGETS+=("${m_target[$i]}")
  done
  TRP_CASE_COUNT="${#TRP_CASE_BEGIN_LINES[@]}"

  # Survival: resolve each target against the repo root (rename-tracked, ORTH).
  local saved_pwd="$PWD"
  if ! cd "$repo_root" 2>/dev/null; then
    _TRP_MARKER_MALFORMED=1; return 0
  fi
  local alive_count=0 target
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
