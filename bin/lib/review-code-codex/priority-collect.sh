#!/usr/bin/env bash
# shellcheck disable=SC2034  # the CP_* globals are read by the entrypoint
# bin/lib/review-code-codex/priority-collect.sh — path-priority diff collection for
# bin/review-code-codex (sourced, not executed). Reads REPO_ROOT, BASE, BASE_STATE and
# MAX_DIFF_LINES from the entrypoint and calls lib/codex-core.sh, which the entrypoint sources
# first; fills the CP_* globals below.
# Per-path, not one diff cut with `head -n`: a raw line cut keeps whatever git sorted first, so
# the session's own files can fall past the budget unseen (#1976). Paths are listed, ordered,
# and whole chunks adopted until the budget stops adoption.

CP_DIFF=""
CP_DIFF_LINES=0
CP_TOTAL=0
CP_ADOPTED=()
CP_DROPPED=()
CP_PARTIAL=""
CP_FALLBACK=0
CP_TRUNCATED=0
CP_UNTRACKED=0
CP_UNTRACKED_WITHHELD=0
CP_WITHHELD=()
CP_ERR=""
CP_CHUNK=""
CP_MB=""
CP_NAMES=()

_cp_read_names() { # <NUL-delimited file> ; fills CP_NAMES
  CP_NAMES=()
  local p
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] && CP_NAMES+=("$p")
  done < "$1"
}

_cp_contains() { # <needle> [haystack...]
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

_cp_lines() { # <text> ; the #1750-correct line count (a final line with no newline counts)
  [[ -n "$1" ]] || { printf '0'; return 0; }
  printf '%s\n' "$1" | wc -l | tr -d '[:space:]'
}

# A credential-shaped path (any kind: committed, staged, intent-to-add, untracked) or an
# untracked symlink (whose target may sit outside the repository) is disclosed by name only;
# its content never reaches the prompt. The match runs over the full repo-relative path
# (codex_core_credential_shaped_path in lib/codex-core.sh owns the patterns). Succeeds when withheld.
_cp_withheld() { # <kind> <path>
  [[ "$1" == *untracked && -L "$REPO_ROOT/$2" ]] && return 0
  codex_core_credential_shaped_path "$2"
}

# The path is passed as an argv element, never interpolated into a command string.
# --no-renames throughout: with rename detection on, a pathspec-filtered diff resolves to the
# new path alone and its chunk reads as a plain addition, so the reviewer never learns which
# file the content came from. Turning detection off lists both sides as ordinary paths.
_cp_chunk() { # <kind> <path> ; sets CP_CHUNK, returns 1 on a real git failure
  local kind="$1" path="$2" rc=0 head_part=""
  CP_CHUNK=""
  case "$kind" in
    committed)
      CP_CHUNK=$(git -C "$REPO_ROOT" -c core.quotePath=false --literal-pathspecs diff --no-renames "${CP_MB:?merge-base unset}" -- "$path" 2>/dev/null) || rc=$? ;;
    committed+untracked|uncommitted+untracked)
      # A commit-to-working-tree diff only sees index entries, so a tracked path recreated as
      # an untracked file reads as a bare deletion; its new content is appended as the untracked
      # chunk. This kind only exists when untracked files were enumerated (never while degraded).
      _cp_chunk "${kind%+untracked}" "$path" || return 1
      head_part="$CP_CHUNK"
      _cp_chunk untracked "$path" || return 1
      if [[ -n "$head_part" && -n "$CP_CHUNK" ]]; then
        CP_CHUNK="${head_part}"$'\n'"${CP_CHUNK}"
      else
        CP_CHUNK="${head_part}${CP_CHUNK}"
      fi
      return 0 ;;
    uncommitted)
      CP_CHUNK=$(git -C "$REPO_ROOT" -c core.quotePath=false --literal-pathspecs diff --no-renames HEAD -- "$path" 2>/dev/null) || rc=$? ;;
    untracked)
      # --no-index exits 1 both when the two files differ (the expected case here) and when
      # "$path" has disappeared or become inaccessible since enumeration — the latter prints no
      # stdout, so treating every rc==1 as "differs" silently records a vanished file as an
      # empty-but-reviewed diff. Checking existence first (relative to REPO_ROOT, matching how
      # the name was enumerated) tells the two cases apart; a path that no longer exists is a
      # genuine failure, not a zero-line diff. The -- terminator stops a leading-dash filename
      # (e.g. "--output=victim") from being parsed as a git option.
      # Withheld paths never get here: codex_priority_collect filters them out first.
      if [[ ! -e "$REPO_ROOT/$path" ]]; then
        rc=1
      else
        CP_CHUNK=$(git -C "$REPO_ROOT" -c core.quotePath=false --literal-pathspecs diff --no-index -- /dev/null "$path" 2>/dev/null) || rc=$?
        (( rc == 1 )) && rc=0
      fi ;;
  esac
  if (( rc != 0 )); then
    CP_CHUNK=""
    return 1
  fi
  return 0
}

# Report-side path rendering: C0 controls, DEL and the bidi controls U+202A-U+202E /
# U+2066-U+2069 become '?' (a newline would forge a report line, a bidi override would make
# the line read differently than it is), the list is capped, and entries are separated by
# ", " so a filename's own comma cannot read as a delimiter.
_CP_BIDI=()
for _cp_b in $'\xaa' $'\xab' $'\xac' $'\xad' $'\xae'; do _CP_BIDI+=($'\xe2\x80'"$_cp_b"); done
for _cp_b in $'\xa6' $'\xa7' $'\xa8' $'\xa9'; do _CP_BIDI+=($'\xe2\x81'"$_cp_b"); done
unset _cp_b

cp_format_paths() { # <cap> [path...]
  local cap="$1"; shift
  local total=$# n=0 out="" p r b
  for p in "$@"; do
    n=$(( n + 1 ))
    (( n > cap )) && break
    [[ -n "$out" ]] && out+=", "
    r="$(printf '%s' "$p" | LC_ALL=C tr '\000-\037\177' '[?*]')"
    for b in "${_CP_BIDI[@]}"; do r="${r//"$b"/?}"; done
    out+="$r"
  done
  (( total > cap )) && out+=", … and $(( total - cap )) more"
  printf '%s' "$out"
}

codex_priority_collect() { # <workdir>
  local wd="$1" err="$1/git-err"
  local -a committed=() unc=() unt=() ord_paths=() ord_kinds=()
  local p i n total=0 stopped=0 first_over=-1 fallback=0

  if ! git -C "$REPO_ROOT" -c core.quotePath=false diff --no-renames --name-only -z "${BASE}...HEAD" >"$wd/committed" 2>"$err"; then
    CP_ERR="git diff failed: $(tr '\n' ' ' <"$err")"
    return 1
  fi
  if ! git -C "$REPO_ROOT" -c core.quotePath=false diff --no-renames --name-only -z HEAD >"$wd/uncommitted" 2>"$err"; then
    CP_ERR="git diff HEAD failed: $(tr '\n' ' ' <"$err")"
    return 1
  fi
  : >"$wd/untracked"
  # Untracked files are enumerated only under a trusted base state (RECORDED/RESOLVED); every
  # other state — degraded, omitted, or an invalid value normalised to UNKNOWN — withholds them
  # (fail-closed). Their content is arbitrary and unscanned, and with an unverified range it can
  # become most or all of the review target, so shipping its full text to an external LLM is an
  # information-leak risk. Committed chunks never carry untracked content (see _cp_chunk).
  # Under the other states only the COUNT is taken (CP_UNTRACKED_WITHHELD; -1 when even that
  # failed), so the caller never claims "no untracked files" for files it simply did not read.
  case "$BASE_STATE" in
    RECORDED|RESOLVED)
      CP_UNTRACKED=1
      if ! git -C "$REPO_ROOT" -c core.quotePath=false ls-files --others --exclude-standard -z >"$wd/untracked" 2>"$err"; then
        CP_ERR="git ls-files failed: $(tr '\n' ' ' <"$err")"
        return 1
      fi ;;
    *)
      if git -C "$REPO_ROOT" -c core.quotePath=false ls-files --others --exclude-standard -z >"$wd/untracked-withheld" 2>"$err"; then
        _cp_read_names "$wd/untracked-withheld"
        CP_UNTRACKED_WITHHELD=${#CP_NAMES[@]}
      else
        CP_UNTRACKED_WITHHELD=-1
      fi ;;
  esac

  _cp_read_names "$wd/committed";   committed=( ${CP_NAMES[@]+"${CP_NAMES[@]}"} )
  _cp_read_names "$wd/uncommitted"; unc=( ${CP_NAMES[@]+"${CP_NAMES[@]}"} )
  _cp_read_names "$wd/untracked";   unt=( ${CP_NAMES[@]+"${CP_NAMES[@]}"} )

  if [[ ${#committed[@]} -gt 0 ]]; then
    # E24 (redefined; origin #1702): with a committed diff, the review target is the WORKING
    # TREE against merge-base(BASE, HEAD). Excluding uncommitted/untracked files left staged
    # fixes unreviewable, so a review loop could never confirm one. Anchoring on the merge-base
    # rather than BASE's tip keeps changes made only on BASE after the branch point out.
    if ! CP_MB=$(git -C "$REPO_ROOT" merge-base "$BASE" HEAD 2>"$err"); then
      CP_ERR="git merge-base failed: $(tr '\n' ' ' <"$err")"
      return 1
    fi
    # Four stable tiers, each path once: committed paths still being edited, uncommitted-only,
    # untracked-only, then the remaining committed paths. Deterministic for one tree.
    for p in "${committed[@]}"; do
      if _cp_contains "$p" ${unt[@]+"${unt[@]}"}; then
        ord_paths+=("$p"); ord_kinds+=("committed+untracked")
      elif _cp_contains "$p" ${unc[@]+"${unc[@]}"}; then
        ord_paths+=("$p"); ord_kinds+=("committed")
      fi
    done
    for p in ${unc[@]+"${unc[@]}"}; do
      _cp_contains "$p" "${committed[@]}" && continue
      if _cp_contains "$p" ${unt[@]+"${unt[@]}"}; then
        ord_paths+=("$p"); ord_kinds+=("uncommitted+untracked")
      else
        ord_paths+=("$p"); ord_kinds+=("uncommitted")
      fi
    done
    for p in ${unt[@]+"${unt[@]}"}; do
      _cp_contains "$p" "${committed[@]}" ${unc[@]+"${unc[@]}"} || { ord_paths+=("$p"); ord_kinds+=("untracked"); }
    done
    for p in "${committed[@]}"; do
      if ! _cp_contains "$p" ${unc[@]+"${unc[@]}"} ${unt[@]+"${unt[@]}"}; then
        ord_paths+=("$p"); ord_kinds+=("committed")
      fi
    done
  else
    # Same dedup as the committed branch: a path both uncommitted and untracked (git rm --cached,
    # then re-created) is counted and listed once.
    for p in ${unc[@]+"${unc[@]}"}; do
      if _cp_contains "$p" ${unt[@]+"${unt[@]}"}; then
        ord_paths+=("$p"); ord_kinds+=("uncommitted+untracked")
      else
        ord_paths+=("$p"); ord_kinds+=("uncommitted")
      fi
    done
    for p in ${unt[@]+"${unt[@]}"}; do
      _cp_contains "$p" ${unc[@]+"${unc[@]}"} || { ord_paths+=("$p"); ord_kinds+=("untracked"); }
    done
    fallback=1
  fi

  # Withheld paths leave the ordering before adoption, so neither their content nor their
  # path can reach CP_DIFF; the caller reports them by name on stdout only.
  local -a kept_paths=() kept_kinds=()
  for (( i = 0; i < ${#ord_paths[@]}; i++ )); do
    if _cp_withheld "${ord_kinds[$i]}" "${ord_paths[$i]}"; then
      CP_WITHHELD+=("${ord_paths[$i]}")
    else
      kept_paths+=("${ord_paths[$i]}"); kept_kinds+=("${ord_kinds[$i]}")
    fi
  done
  ord_paths=( ${kept_paths[@]+"${kept_paths[@]}"} )
  ord_kinds=( ${kept_kinds[@]+"${kept_kinds[@]}"} )
  (( fallback )) && [[ ${#ord_paths[@]} -gt 0 ]] && CP_FALLBACK=1
  CP_TOTAL=${#ord_paths[@]}

  # Stop-at-first-skip adoption. A chunk that does not fit ends adoption outright: leapfrogging
  # it to take a smaller chunk further down would report a review of "the small files" while the
  # larger change it skipped is the one that mattered. The leftover budget is left unspent on
  # purpose.
  for (( i = 0; i < ${#ord_paths[@]}; i++ )); do
    p="${ord_paths[$i]}"
    if (( stopped )); then
      CP_DROPPED+=("$p")
      continue
    fi
    if ! _cp_chunk "${ord_kinds[$i]}" "$p"; then
      CP_ERR="git diff failed while extracting the diff chunk for a changed path"
      return 1
    fi
    n=$(_cp_lines "$CP_CHUNK")
    if (( total + n <= MAX_DIFF_LINES )); then
      if [[ -n "$CP_CHUNK" ]]; then
        [[ -n "$CP_DIFF" ]] && CP_DIFF+=$'\n'
        CP_DIFF+="$CP_CHUNK"
      fi
      total=$(( total + n ))
      CP_ADOPTED+=("$p")
    elif (( total == 0 )); then
      # Nothing has been adopted yet and this path alone is past the whole budget. Stopping
      # here would make the review empty, so the path is dropped and the scan continues; the
      # anti-leapfrog rule only has to hold once adoption has actually begun. The first such
      # path is remembered as the fallback in case no path ever fits.
      (( first_over < 0 )) && first_over=$i
      CP_TRUNCATED=1
      CP_DROPPED+=("$p")
    else
      CP_TRUNCATED=1
      stopped=1
      CP_DROPPED+=("$p")
    fi
  done

  # No path fit the budget at all: review the head of the first oversized one rather than
  # nothing, and declare it partial. It is CP_DROPPED[0] — it was dropped before any other.
  if [[ ${#CP_ADOPTED[@]} -eq 0 && $first_over -ge 0 ]]; then
    p="${ord_paths[$first_over]}"
    if ! _cp_chunk "${ord_kinds[$first_over]}" "$p"; then
      CP_ERR="git diff failed while extracting the diff chunk for a changed path"
      return 1
    fi
    CP_DIFF=$(printf '%s\n' "$CP_CHUNK" | head -n "$MAX_DIFF_LINES")
    CP_ADOPTED+=("$p")
    CP_PARTIAL="$p"
    CP_DROPPED=( ${CP_DROPPED[@]+"${CP_DROPPED[@]:1}"} )
  fi

  CP_DIFF_LINES=$(_cp_lines "$CP_DIFF")
  [[ ${#CP_DROPPED[@]} -gt 0 ]] && CP_TRUNCATED=1
  return 0
}
