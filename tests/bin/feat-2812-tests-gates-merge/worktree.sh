# Tests: hooks/lib/precommit-tests-frontmatter.sh
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, worktree, scope:issue-specific
# Merge shapes on the hook path: a merge left in progress inside a linked worktree (MERGE_HEAD in the
# per-worktree gitdir), and a temporary GIT_INDEX_FILE during a merge (the staged oid is read from the
# index git was pointed at, not from .git/index).
# Sourced by tests/bin/feat-2812-tests-gates-merge-shapes.sh after bodies.sh (EX_PAIRS, ex-si).
# tab/newline paths in the merge-parents.sh record stream: nul-paths.sh.
# shellcheck shell=bash

echo ""
echo "=== merge shapes: linked worktree, temporary index ==="

# wtfx <main> <wt> <up-pairs> <staged-pairs> — `up` committed in <main>, a linked worktree <wt> on
# its own branch, and `git merge --no-commit --no-ff up` left in progress inside <wt>.
wtfx() {
  local d="$1" w="$2" gp
  mkrepo "$d"
  git -C "$d" checkout -q -b up
  apply "$d" "$3"; printf 'up\n' > "$d/up.txt"; commit_all "$d" up
  git -C "$d" checkout -q -
  git -C "$d" worktree add -q -b wt "$w" >/dev/null 2>&1
  printf 'head\n' > "$w/head.txt"; commit_all "$w" head
  git -C "$w" merge --no-commit --no-ff -q up >/dev/null 2>&1 || true
  apply "$w" "$4"
  git -C "$w" add -A >/dev/null 2>&1
  gp="$(git -C "$w" rev-parse --git-path MERGE_HEAD 2>/dev/null)"
  case "$gp" in
    *worktrees/*) pass "fixture ${w##*/}: MERGE_HEAD in the per-worktree gitdir" ;;
    *) fail "fixture ${w##*/}" "MERGE_HEAD git-path is $gp" ;;
  esac
  if git -C "$w" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && [ ! -e "$d/.git/MERGE_HEAD" ]; then
    pass "fixture ${w##*/}: merge in progress in the worktree only"
  else
    fail "fixture ${w##*/}" "want MERGE_HEAD in the worktree and none in the main checkout"
  fi
}

case_begin "linked-worktree-merge-head-only-files-pass-every-gate" "hooks/lib/precommit-tests-frontmatter.sh"
W="$TMPBASE/wt-linked"
wtfx "$TMPBASE/wt-main" "$W" "$EX_PAIRS" ""
gate "$W" "$FG"
expect_rc "worktree frontmatter gate" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "worktree frontmatter gate" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
gate "$W" "$CM"
expect_rc "worktree case-marker gate" 0 "$GATE_RC" "$GATE_ALL"
gate "$W" "$LG"
expect_rc "worktree language-match gate" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "worktree language-match gate" "$GATE_ALL" TEST_LANGUAGE_MISMATCH 0
case_end

case_begin "linked-worktree-merge-head-file-counts-only-the-added-counter" "bin/check-test-frontmatter/self-impl.sh"
raw wt-si2 "$(hdr bin/a.sh)" 'PASS=0' 'PASS=0' "$(mcase a bin/a.sh)"
W="$TMPBASE/wt-linked2"
wtfx "$TMPBASE/wt-main2" "$W" "tests/bin/si.sh=ex-si" "tests/bin/si.sh=wt-si2"
gate "$W" "$FG"
expect_rc "worktree R4: MERGE_HEAD 1 counter, staged 2" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "worktree R4: only the added counter" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "temporary-index-during-a-merge-is-the-staged-side" "bin/lib/merge-parents.sh"
# .git/index holds the MERGE_HEAD blob (1 counter); the temporary index holds a 3-counter edit of it.
# Expected x2 (R4: 3 - 1). Each wrong reading gives another count: .git/index judged R1 -> x0,
# .git/index judged against HEAD only -> x1, temporary index judged against HEAD only -> x3.
raw wt-si3 "$(hdr bin/a.sh)" 'PASS=0' 'PASS=0' 'PASS=0' "$(mcase a bin/a.sh)"
R="$TMPBASE/idx-merge"
ALT_INDEX="$TMPBASE/idx-merge.alt-index"
mergefx "$R" "" "tests/bin/si.sh=ex-si" "" ""
cp "$R/.git/index" "$ALT_INDEX"
apply "$R" "tests/bin/si.sh=wt-si3"
env GIT_INDEX_FILE="$ALT_INDEX" git -C "$R" add -- tests/bin/si.sh
assert_eq "precondition: .git/index si.sh is the MERGE_HEAD blob=$(git -C "$R" rev-parse :tests/bin/si.sh)" \
  "precondition: .git/index si.sh is the MERGE_HEAD blob=$(git -C "$R" rev-parse MERGE_HEAD:tests/bin/si.sh)"
alt_oid="$(env GIT_INDEX_FILE="$ALT_INDEX" git -C "$R" rev-parse :tests/bin/si.sh)"
assert_eq "precondition: temporary index differs from MERGE_HEAD=$([ "$alt_oid" != "$(git -C "$R" rev-parse MERGE_HEAD:tests/bin/si.sh)" ] && echo yes)" \
  "precondition: temporary index differs from MERGE_HEAD=yes"
export GIT_INDEX_FILE="$ALT_INDEX"
gate "$R" "$FG"
unset GIT_INDEX_FILE
expect_rc "temporary index: three counters against the MERGE_HEAD blob" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "temporary index: only the two added counters" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 2
case_end
