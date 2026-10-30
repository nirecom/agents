#!/usr/bin/env bash
# tests/bin/feature-2631-review-size-bins/merge-incoming.sh — #2631 stage 9 bodies of
# tests/bin/feature-2631-review-size-bins.sh: each review bin's --staged run, during an uncommitted
# merge, passes a HARD+1 file staged equal to MERGE_HEAD and blocks one that differs from it.
# Sourced after the dispatcher's helpers (TREE, run_bin, RC, OUT); the merge repo comes from
# tests/lib/size-merge-fixture.sh. review-prompt-size has no --staged mode; its kind is covered
# through bin/size-check --kind prompt in tests/bin/feature-2631-size-check-merge.js (K2).

# shellcheck source=../../lib/size-merge-fixture.sh
. "$ROOT/tests/lib/size-merge-fixture.sh"
MI_SEQ=0

# mi_case_merge <bin> <kind> <path> — the K2 and K3 equivalents through <bin> --staged.
mi_case_merge() {
  local bin="$1" kind="$2" path="$3" hard repo
  hard="$(smf_hard "$kind")"
  MI_SEQ=$((MI_SEQ + 1))
  repo="$TMP_ROOT/mi-repo-$MI_SEQ"
  if ! make_merge_repo "$repo" "$path=$((hard + 1))"; then fail "$bin: fixture merge repo" "make_merge_repo failed"; return; fi
  run_bin "$TREE" "$repo" "$bin" --staged
  if [ "$RC" = 0 ] && ! printf '%s' "$OUT" | grep -q SKIPPED; then
    pass "$bin --staged: $path ($((hard + 1)) lines) staged equal to MERGE_HEAD passes (rc 0)"
  else
    fail "$bin --staged: $path staged equal to MERGE_HEAD passes (rc 0)" "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
  fi
  smf_grow "$repo" "$path"
  run_bin "$TREE" "$repo" "$bin" --staged
  if [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -qF "HARD: $path "; then
    pass "$bin --staged: $path differing from MERGE_HEAD by one line blocks (rc 1)"
  else
    fail "$bin --staged: $path differing from MERGE_HEAD by one line blocks (rc 1)" "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
  fi
}
