# bin/lib/review-size.sh — sourced by bin/review-{code,prompt,doc}-size (#2631).
# review_size_check <hdr> <kind> <pre> <post> runs bin/size-check once over the NUL-separated
# paths on stdin and sets RS_TARGETS (count) and RS_RECORDS (tab records, one per line).
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
  rm -f "$err"
  RS_TARGETS=0
  RS_RECORDS=""
  while IFS= read -r line; do
    if [[ "$line" == TARGETS$'\t'* ]]; then
      RS_TARGETS="${line#TARGETS$'\t'}"
      # A newline-bearing filename can forge this line; the count reaches an arithmetic test, so reject non-digits.
      if [[ ! "$RS_TARGETS" =~ ^[0-9]+$ ]]; then
        printf '%s: ERROR — bin/size-check printed a non-numeric TARGETS count\n' "$hdr"
        exit 2
      fi
    elif [[ -n "$line" ]]; then
      RS_RECORDS+="$line"$'\n'
    fi
  done <<< "$out"
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
