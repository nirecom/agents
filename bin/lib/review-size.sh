# bin/lib/review-size.sh — sourced by bin/review-{code,prompt,doc}-size (#2631).
# review_size_check <hdr> <kind> <pre> <post> runs bin/size-check once over the NUL-separated
# paths on stdin and sets RS_TARGETS (count), RS_RECORDS (tab records, one per line) and RS_MERGE_EXCLUDED.
# An infrastructure error prints a non-SKIPPED diagnostic and exits 2, so callers fail closed.

RS_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

review_size_check() {
  local hdr="$1" out rc=0 err line
  err="$(mktemp)"
  out="$(node "$RS_BIN_DIR/size-check" --kind "$2" --pre "$3" --post "$4" 2>"$err")" || rc=$?
  if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    printf '%s: ERROR — bin/size-check failed (rc %s)\n' "$hdr" "$rc"
    while IFS= read -r line; do printf '  %s\n' "$line"; done < "$err"
    rm -f "$err"
    exit 2
  fi
  cat "$err" >&2
  # RS_MERGE_EXCLUDED: staged paths size-check left out as merge-incoming (its stderr notice), so a
  # --staged run whose every target was excluded still counts as performed, not skipped.
  # shellcheck disable=SC2034 # read by the sourcing bins
  RS_MERGE_EXCLUDED=0
  line="$(grep -m1 -oE 'merge in progress; [0-9]+ staged path' "$err" || true)"
  # shellcheck disable=SC2034
  [[ "$line" =~ ([0-9]+) ]] && RS_MERGE_EXCLUDED="${BASH_REMATCH[1]}"
  rm -f "$err"
  RS_TARGETS=0
  RS_RECORDS=""
  local seen_targets=0 has_hard=0
  while IFS= read -r line; do
    if [[ "$line" == TARGETS$'\t'* ]]; then
      # Only the first TARGETS line counts; later ones can only come from a newline-bearing filename.
      [[ "$seen_targets" -eq 1 ]] && continue
      seen_targets=1
      RS_TARGETS="${line#TARGETS$'\t'}"
      # The count reaches an arithmetic test, so reject non-digits.
      if [[ ! "$RS_TARGETS" =~ ^[0-9]+$ ]]; then
        printf '%s: ERROR — bin/size-check printed a non-numeric TARGETS count\n' "$hdr"
        exit 2
      fi
    elif [[ -n "$line" ]]; then
      [[ "${line%%$'\t'*}" == HARD ]] && has_hard=1
      RS_RECORDS+="$line"$'\n'
    fi
  done <<< "$out"
  if [[ "$seen_targets" -eq 0 ]]; then
    printf '%s: ERROR — bin/size-check printed no TARGETS line\n' "$hdr"
    exit 2
  fi
  # Fail closed: the exit code (1 = HARD found) and the HARD records must agree.
  if [[ ( "$rc" -eq 1 && "$has_hard" -eq 0 ) || ( "$rc" -eq 0 && "$has_hard" -eq 1 ) ]]; then
    printf '%s: ERROR — bin/size-check exit code and HARD records disagree\n' "$hdr"
    exit 2
  fi
}

# review_size_worktree_nul — newline-separated paths on stdin to NUL-separated existing files.
review_size_worktree_nul() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && printf '%s\0' "$f"
  done
  return 0
}

# review_size_changed_nul <base-sha> — NUL-separated existing files changed since the base (committed, staged, unstaged, untracked).
# -z + core.quotePath=false keep non-ASCII and special-char paths intact.
review_size_changed_nul() {
  local f g=(git -c core.quotePath=false)
  {
    "${g[@]}" diff -z --name-only --diff-filter=ACMRT "$1"...HEAD
    "${g[@]}" diff -z --name-only --cached --diff-filter=ACMRT
    "${g[@]}" diff -z --name-only --diff-filter=ACMRT
    "${g[@]}" ls-files -z --others --exclude-standard
  } 2>/dev/null | sort -zu | while IFS= read -r -d '' f; do
    [[ -f "$f" ]] && printf '%s\0' "$f"
  done
  return 0
}

# review_size_pre_head —"rev:HEAD" when HEAD resolves to a commit, else "none" (an unborn branch).
review_size_pre_head() {
  if git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then echo "rev:HEAD"; else echo none; fi
}
