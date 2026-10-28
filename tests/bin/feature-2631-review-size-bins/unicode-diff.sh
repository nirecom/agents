#!/usr/bin/env bash
# tests/bin/feature-2631-review-size-bins/unicode-diff.sh — the diff-mode non-ASCII path bodies of
# tests/bin/feature-2631-review-size-bins.sh (the case markers stay in the entry file).
# Sourced after the entry defines scenario, judge, expect and TREE. A Git-quoted name ("\346\227...")
# that reaches the file-system lookup is dropped as missing, so the over-HARD file goes unjudged.

# ud_case_non_ascii_diff_path <bin> <non-ascii path> <HARD> — HARD+1 blocks naming the path verbatim;
# the same path at 10 lines is still judged (rc 0, named), never silently skipped.
ud_case_non_ascii_diff_path() {
  local bin="$1" path="$2" hard="$3" repo
  repo="$(scenario diff - make_lines $((hard + 1)) "$path")"
  judge "$TREE" "$bin" diff "$repo"
  expect "$bin diff: a new non-ASCII $path at HARD+1 exits 1 with a HARD line naming it verbatim" 1 "$path"
  repo="$(scenario diff - make_lines 10 "$path")"
  judge "$TREE" "$bin" diff "$repo"
  expect "$bin diff: control: the same non-ASCII path at 10 lines is judged (rc 0, named)" 0 "$path"
}
