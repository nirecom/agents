#!/usr/bin/env bash
# Worktree change detection for tests/run-all.sh (#2590); sourced by bin/lib/run-all-launch.sh.
# Each test runs between two fingerprints of the protected trees (the main worktree and the
# checkout the launcher was loaded from); a difference is logged as "<tree>\t<test id>\t<kind>[\t<paths>]",
# kind one of tracked | content | head | index | config. Untracked files are not watched (-uno).
# Design: docs/architecture/claude-code/test-command-guard.md

_RUN_ALL_WCD_LOG=""
_RUN_ALL_WCD_GIT=""
_RUN_ALL_WCD_TREES=()
_RUN_ALL_WCD_GITDIRS=()
_RUN_ALL_WCD_COMMONS=()
_RUN_ALL_WCD_BEFORE=()
_RUN_ALL_WCD_T0=""
_RUN_ALL_WCD_SLOT_FILE=""
_RUN_ALL_WCD_REPORTED=0
# Above this many dirty tracked paths the content comparison is skipped (the report says so).
RUN_ALL_WCD_MAX_PATHS=500

_run_all_wcd_now() {
  local t="${EPOCHREALTIME:-$SECONDS}"
  printf '%s' "${t/[.,]/}"
}

_run_all_wcd_add_tree() {
  local tree="$1" low i
  low="$(printf '%s' "$tree" | tr 'A-Z\\' 'a-z/')"
  for i in ${_RUN_ALL_WCD_TREES[@]+"${!_RUN_ALL_WCD_TREES[@]}"}; do
    [ "$(printf '%s' "${_RUN_ALL_WCD_TREES[$i]}" | tr 'A-Z\\' 'a-z/')" = "$low" ] && return 0
  done
  _RUN_ALL_WCD_TREES+=("$tree")
  _RUN_ALL_WCD_GITDIRS+=("$2")
  _RUN_ALL_WCD_COMMONS+=("$3")
}

_run_all_wcd_write_slot_before() {
  local i
  [ -n "$_RUN_ALL_WCD_SLOT_FILE" ] || return 0
  for i in "${!_RUN_ALL_WCD_BEFORE[@]}"; do
    printf '%s' "${_RUN_ALL_WCD_BEFORE[$i]}" >"$_RUN_ALL_WCD_SLOT_FILE.$i.$$" 2>/dev/null \
      && mv -f "$_RUN_ALL_WCD_SLOT_FILE.$i.$$" "$_RUN_ALL_WCD_SLOT_FILE.$i" 2>/dev/null
  done
  return 0
}

_run_all_wcd_read_slot_before() {
  local i
  _RUN_ALL_WCD_BEFORE=()
  [ -n "$_RUN_ALL_WCD_SLOT_FILE" ] || return 0
  for i in "${!_RUN_ALL_WCD_TREES[@]}"; do
    [ -f "$_RUN_ALL_WCD_SLOT_FILE.$i" ] || return 1
    _RUN_ALL_WCD_BEFORE[$i]="$(cat "$_RUN_ALL_WCD_SLOT_FILE.$i")"
  done
}

# run_all_pin_worktree_change_detect <log> — protect the main worktree (the parent of the common
# git dir) and this checkout, collapsed to one tree when they are the same. Non-zero only when
# <log> cannot be written; a checkout that is not a git work tree turns detection off.
run_all_pin_worktree_change_detect() {
  local log="${1:-}" git checkout out top gitdir common
  [ -n "$log" ] || return 1
  case "$log" in */*) mkdir -p "${log%/*}" 2>/dev/null ;; esac
  : >"$log" 2>/dev/null || return 1
  : >"$log.span" 2>/dev/null || return 1
  rm -f "$log.skipped"
  _RUN_ALL_WCD_LOG="$log"
  _RUN_ALL_WCD_SLOT_FILE="$log.slot-before"
  _RUN_ALL_WCD_TREES=() _RUN_ALL_WCD_GITDIRS=() _RUN_ALL_WCD_COMMONS=()
  _RUN_ALL_WCD_REPORTED=0
  # The real git, never the command guard: a fingerprint is a read the guard need not judge.
  if declare -F _command_guard_strip_path >/dev/null 2>&1; then
    git="$(PATH="$(_command_guard_strip_path "$PATH")" command -v git)"
  else
    git="$(command -v git)"
  fi
  [ -n "$git" ] || { printf '[run-all] worktree change detection is off: no git on PATH\n' >&2; return 0; }
  _RUN_ALL_WCD_GIT="$git"
  checkout="$RUN_ALL_LAUNCH_DIR/../.."
  if ! out="$("$git" -C "$checkout" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir 2>/dev/null)"; then
    printf '[run-all] worktree change detection is off: %s is not a git work tree\n' "$checkout" >&2
    return 0
  fi
  out="${out//$'\r'/}"
  top="${out%%$'\n'*}"; out="${out#*$'\n'}"
  gitdir="${out%%$'\n'*}"; common="${out#*$'\n'}"
  _run_all_wcd_add_tree "$top" "$gitdir" "$common"
  case "$common" in */.git) _run_all_wcd_add_tree "${common%/.git}" "$common" "$common" ;; esac
  return 0
}

# run_all_worktree_fingerprint <tree> [<git dir> <common dir>] — the comparable state of <tree>:
#   H <branch header>   S <path>\t<XY>\t<status line>   W <path>\t<blob of the worktree file>
#   C <config file>\t<content>   X <reason> (the content comparison was skipped)
run_all_worktree_fingerprint() {
  local tree="$1" gitdir="${2:-}" common="${3:-}" git="${_RUN_ALL_WCD_GIT:-git}"
  local st line p k xy n=0 sums f hash
  local -a dirty=()
  if [ -z "$gitdir" ] || [ -z "$common" ]; then
    st="$("$git" -C "$tree" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)" || return 1
    st="${st//$'\r'/}"
    gitdir="${st%%$'\n'*}"; common="${st#*$'\n'}"
  fi
  st="$("$git" --no-optional-locks -C "$tree" -c core.quotePath=false status --porcelain=v2 --branch -uno 2>/dev/null)" || { printf 'X status failed\n'; return 0; }
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      '# branch.oid '*|'# branch.head '*) printf 'H %s\n' "$line"; continue ;;
      [12u]' '*) ;;
      *) continue ;;
    esac
    case "$line" in 1*) k=8 ;; 2*) k=9 ;; *) k=10 ;; esac
    p="$line"
    while [ "$k" -gt 0 ]; do p="${p#* }"; k=$((k - 1)); done
    p="${p%%$'\t'*}"
    xy="${line:2:2}"
    printf 'S %s\t%s\t%s\n' "$p" "$xy" "$line"
    case "${xy:1:1}" in .|D) continue ;; esac
    case "$p" in '"'*) continue ;; esac
    dirty+=("$p")
    n=$((n + 1))
  done <<<"$st"
  if [ "$n" -gt "$RUN_ALL_WCD_MAX_PATHS" ]; then
    printf 'X %s dirty paths\n' "$n"
  elif [ "$n" -gt 0 ]; then
    if sums="$(printf '%s\n' "${dirty[@]}" | "$git" -C "$tree" hash-object --stdin-paths 2>/dev/null)"; then
      k=0
      while IFS= read -r line; do
        printf 'W %s\t%s\n' "${dirty[$k]}" "${line%$'\r'}"
        k=$((k + 1))
      done <<<"$sums"
    else
      printf 'X a dirty file could not be read\n'
    fi
  fi
  for f in "$common/config" "$gitdir/config.worktree"; do
    if [ -f "$f" ]; then
      hash="$("$git" hash-object "$f" 2>/dev/null)" || hash="absent"
    else
      hash="absent"
    fi
    printf 'C %s\t%s\n' "$f" "$hash"
  done
}

# run_all_worktree_change_begin — the before fingerprints of every protected tree.
run_all_worktree_change_begin() {
  local i
  _RUN_ALL_WCD_BEFORE=()
  [ -n "$_RUN_ALL_WCD_LOG" ] && [ "${#_RUN_ALL_WCD_TREES[@]}" -gt 0 ] || return 0
  _RUN_ALL_WCD_T0="$(_run_all_wcd_now)"
  if [ -n "$_RUN_ALL_WCD_SLOT_FILE" ] && _run_all_wcd_read_slot_before; then
    return 0
  fi
  for i in "${!_RUN_ALL_WCD_TREES[@]}"; do
    _RUN_ALL_WCD_BEFORE[$i]="$(run_all_worktree_fingerprint "${_RUN_ALL_WCD_TREES[$i]}" "${_RUN_ALL_WCD_GITDIRS[$i]}" "${_RUN_ALL_WCD_COMMONS[$i]}")"
  done
}

# _run_all_wcd_kinds — reads "<before>\n@@AFTER@@\n<after>", prints one changed kind per line
# ("<kind>\t<paths>" for tracked / content / index: up to 5 paths joined by " | ", then "+N more"),
# and "skipped" when either side skipped the content comparison.
_run_all_wcd_kinds() {
  awk -F '\t' '
    function add(k, p) { n[k]++; if (n[k] <= 5) l[k] = l[k] (n[k] > 1 ? " | " : "") p }
    function out(k) { if (n[k]) print k "\t" l[k] (n[k] > 5 ? " | +" (n[k] - 5) " more" : "") }
    BEGIN { side = 0 }
    $0 == "@@AFTER@@" { side = 1; next }
    { tag = substr($0, 1, 1); $0 = substr($0, 3) }
    tag == "H" { h[side] = h[side] $0 "\n"; next }
    tag == "C" { c[side] = c[side] $0 "\n"; next }
    tag == "X" { skip = 1; next }
    tag == "S" { seen[$1] = 1; has[side, $1] = 1; xy[side, $1] = $2; ln[side, $1] = $3; next }
    tag == "W" { w[side, $1] = $2 }
    END {
      for (p in seen) {
        if (!has[0, p] || !has[1, p] || xy[0, p] != xy[1, p]) add("tracked", p)
        else if (ln[0, p] != ln[1, p]) add("index", p)
        else if (!skip && ((0, p) in w) && ((1, p) in w) && w[0, p] != w[1, p]) add("content", p)
      }
      out("tracked")
      out("content")
      if (h[0] != h[1]) print "head"
      out("index")
      if (c[0] != c[1]) print "config"
      if (skip) print "skipped"
    }'
}

# run_all_worktree_change_check <test id> — compares against the before fingerprints and appends
# one "<tree>\t<test id>\t<kind>[\t<paths>]" line per changed kind to the log.
run_all_worktree_change_check() {
  local id="$1" i after kind paths
  local -a afters=()
  [ -n "$_RUN_ALL_WCD_LOG" ] && [ "${#_RUN_ALL_WCD_BEFORE[@]}" -gt 0 ] || return 0
  for i in "${!_RUN_ALL_WCD_TREES[@]}"; do
    after="$(run_all_worktree_fingerprint "${_RUN_ALL_WCD_TREES[$i]}" "${_RUN_ALL_WCD_GITDIRS[$i]}" "${_RUN_ALL_WCD_COMMONS[$i]}")"
    afters[$i]="$after"
    # An unchanged fingerprint that skipped the content comparison proves nothing about content.
    case $'\n'"$after" in *$'\nX '*) printf '%s\n' "${_RUN_ALL_WCD_TREES[$i]}" >>"$_RUN_ALL_WCD_LOG.skipped" ;; esac
    [ "$after" = "${_RUN_ALL_WCD_BEFORE[$i]}" ] && continue
    while IFS=$'\t' read -r kind paths; do
      case "$kind" in
        '') ;;
        skipped) printf '%s\n' "${_RUN_ALL_WCD_TREES[$i]}" >>"$_RUN_ALL_WCD_LOG.skipped" ;;
        *) printf '%s\t%s\t%s%s\n' "${_RUN_ALL_WCD_TREES[$i]}" "$id" "$kind" "${paths:+$'\t'$paths}" >>"$_RUN_ALL_WCD_LOG" ;;
      esac
    done <<<"$(printf '%s\n@@AFTER@@\n%s\n' "${_RUN_ALL_WCD_BEFORE[$i]}" "$after" | _run_all_wcd_kinds)"
  done
  printf '%s\t%s\t%s\n' "$_RUN_ALL_WCD_T0" "$(_run_all_wcd_now)" "$id" >>"$_RUN_ALL_WCD_LOG.span"
  if [ -n "$_RUN_ALL_WCD_SLOT_FILE" ]; then
    _RUN_ALL_WCD_BEFORE=("${afters[@]}")
    _run_all_wcd_write_slot_before
  fi
  _RUN_ALL_WCD_BEFORE=()
}

# run_all_worktree_change_report — one stderr line per logged change, a note naming the tests
# that ran alongside a named one (each is then only a candidate), and a note per tree whose
# content comparison was skipped. Non-zero when a change was logged; runs once.
run_all_worktree_change_report() {
  local log="$_RUN_ALL_WCD_LOG" tree line n=0
  [ "$_RUN_ALL_WCD_REPORTED" -eq 0 ] || return 0
  _RUN_ALL_WCD_REPORTED=1
  [ -n "$log" ] || return 0
  if [ -s "$log.skipped" ]; then
    while IFS= read -r tree; do
      printf '[run-all] worktree change detection: content comparison skipped for %s (more than %s dirty tracked paths)\n' "$tree" "$RUN_ALL_WCD_MAX_PATHS" >&2
    done < <(sort -u "$log.skipped")
  fi
  [ -s "$log" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '[run-all] worktree change: %s\n' "$line" >&2
    n=$((n + 1))
  done <"$log"
  awk -F '\t' '
    FNR == NR { named[$2] = 1; next }
    { s[$3] = $1; e[$3] = $2; ids[++m] = $3 }
    END {
      for (i = 1; i <= m; i++) {
        a = ids[i]; if (!(a in named)) continue
        others = ""
        for (j = 1; j <= m; j++) { b = ids[j]; if (b != a && s[a] < e[b] && s[b] < e[a]) others = others " " b }
        if (others != "") printf "[run-all] worktree change candidates: %s ran alongside%s; any of them may have made the change\n", a, others
      }
    }' "$log" "$log.span" >&2
  printf '[run-all] %s worktree change(s): a test changed a protected tree; the run fails\n' "$n" >&2
  return 1
}
