# shellcheck shell=bash
# bin/check-test-frontmatter/self-impl.sh — the --staged self-implemented harness check of
# bin/check-test-frontmatter.sh. Source only; needs SCRIPT_DIR (the bin directory).
# ctf_self_impl <rel> <content> — runs bin/check-self-impl.sh --rel <rel> on a copy of the staged
# content and prints its lines on stderr. rc 1 when it reports a HIGH; a WARN, or the check
# itself failing (its exit 2, printed with its reason), never blocks the commit.

ctf_self_impl() {
  local rel="$1" content="$2" dir rc=0 out
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ctf-self-impl.XXXXXX")" || return 0
  # The copy keeps the original basename, so every reader of it sees the same name.
  printf '%s\n' "$content" >"$dir/${rel##*/}"
  out="$(bash "$SCRIPT_DIR/check-self-impl.sh" --rel "$rel" "$dir/${rel##*/}" 2>&1)" || rc=$?
  rm -rf "$dir"
  [[ -z "$out" ]] || printf '%s\n' "$out" >&2
  [[ "$rc" -eq 1 ]] && return 1
  return 0
}
