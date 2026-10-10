# shellcheck shell=bash
# Home-reference check for bin/run-tests-baseline (#2505). Source-only.
# rtb_has_home_ref <path...> returns 0 when a file (or any file under a directory) holds an
# RTB_HOME_REFS literal outside whole-line comments of its own language, or when that cannot be
# decided (fail-closed); 1 only when no such reference is confirmed. The comment prefix is the
# registry's header.commentPrefix for a matching entry, else none (every line is checked).
# Requires bin/lib/test-language-registry.sh sourced; bash 3.2 compatible.

# shellcheck disable=SC2016,SC2088  # literal patterns, never expanded
RTB_HOME_REFS=('$HOME/.claude' '${HOME}/.claude' '~/.claude' '$env:USERPROFILE' '$env:HOME' 'Path.home()' 'expanduser("~')

RTB_HOMEREF_BATCH=200

# _rtb_homeref_awk <prefix> <file...> — rc 0 none, 10 reference on a non-comment line, else error.
_rtb_homeref_awk() {
  local pfx="$1" refs="" r
  shift
  for r in "${RTB_HOME_REFS[@]}"; do refs="$refs$r"$'\n'; done
  RTB_REFS="$refs" RTB_PFX="$pfx" awk '
    BEGIN { n = split(ENVIRON["RTB_REFS"], refs, "\n"); pfx = ENVIRON["RTB_PFX"]; plen = length(pfx) }
    {
      s = $0
      sub(/^[ \t]+/, "", s)
      if (plen > 0 && substr(s, 1, plen) == pfx) next
      for (i = 1; i <= n; i++) if (refs[i] != "" && index($0, refs[i]) > 0) exit 10
    }
  ' "$@"
}

rtb_has_home_ref() {
  local p f listing find_rc pfx i j rc saved_id saved_st
  local files=() pfxs=() uniq=() batch=()
  declare -F tlr_match >/dev/null 2>&1 || return 0
  [ -n "${TLR_LOADED_KEY:-}" ] || tlr_load || return 0

  for p in "$@"; do
    if [ -f "$p" ]; then
      files+=("$p")
    elif [ -d "$p" ]; then
      listing="$(find "$p" -type f 2>/dev/null)"
      find_rc=$?
      [ "$find_rc" -eq 0 ] || return 0
      while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
      done <<<"$listing"
    else
      return 0
    fi
  done
  [ "${#files[@]}" -gt 0 ] || return 0

  saved_id="${TLR_ID:-}" saved_st="${TLR_STATUS:-}"
  for f in "${files[@]}"; do
    [ -r "$f" ] || { TLR_ID="$saved_id"; TLR_STATUS="$saved_st"; return 0; }
    pfx=""
    if tlr_match "$f"; then pfx="$(tlr_field "$TLR_ID" header.commentPrefix)"; fi
    pfxs+=("$pfx")
    j=0
    while [ "$j" -lt "${#uniq[@]}" ] && [ "${uniq[$j]}" != "$pfx" ]; do j=$((j + 1)); done
    [ "$j" -lt "${#uniq[@]}" ] || uniq+=("$pfx")
  done
  TLR_ID="$saved_id"; TLR_STATUS="$saved_st"

  for pfx in "${uniq[@]}"; do
    i=0
    while [ "$i" -lt "${#files[@]}" ]; do
      if [ "${pfxs[$i]}" = "$pfx" ]; then
        f="${files[$i]}"
        # awk reads a relative `name=value` operand as an assignment, not a file.
        case "$f" in /* | ./* | ../* | [A-Za-z]:/*) ;; *) f="./$f" ;; esac
        batch+=("$f")
      fi
      i=$((i + 1))
      if [ "${#batch[@]}" -ge "$RTB_HOMEREF_BATCH" ] || { [ "$i" -eq "${#files[@]}" ] && [ "${#batch[@]}" -gt 0 ]; }; then
        rc=0
        _rtb_homeref_awk "$pfx" "${batch[@]}" || rc=$?
        [ "$rc" -eq 0 ] || return 0
        batch=()
      fi
    done
  done
  return 1
}
