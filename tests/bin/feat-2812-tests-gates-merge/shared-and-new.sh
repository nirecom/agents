# Tests: hooks/lib/precommit-tests-frontmatter.sh
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, self-impl, case-markers, test-language-match, scope:issue-specific
# R1 on a path both parents carry with different blobs (staged equal to MERGE_HEAD is existing for
# every gate, with the two parents' bodies mirrored), and R2 during a merge (a test neither parent has still blocks on every gate: a guard
# against waving everything through while MERGE_HEAD exists).
# Sourced by tests/bin/feat-2812-tests-gates-merge-shapes.sh after bodies.sh (ex-si, ex-nomark, ex-mm).
# shellcheck shell=bash

echo ""
echo "=== R1 on a shared path, R2 during a merge ==="

# Base: one bin/foo.sh case. Side X adds counter PASS=0 and a case on bin/foo.js; side Y adds counter
# FAIL=0 and a case on bin/bar.js. Each side carries a counter and a .js case the other lacks, so a
# HEAD-only gate reports both on whichever side came from MERGE_HEAD. The two cases swap X and Y.
H5="bin/foo.sh, bin/foo.js, bin/bar.js"
raw r1s-base "$(hdr "$H5")" "$(mcase a bin/foo.sh)"
raw r1s-x "$(hdr "$H5")" 'PASS=0' "$(mcase a bin/foo.sh)" "$(mcase j bin/foo.js)"
raw r1s-y "$(hdr "$H5")" 'FAIL=0' "$(mcase a bin/foo.sh)" "$(mcase k bin/bar.js)"

# r1s_expect <label> <repo> <side> — staged blob is the <side> blob, and no gate reports a detection.
r1s_expect() {
  local label="$1" repo="$2" side="$3"
  assert_eq "$label precondition: parents differ=$([ "$(git -C "$repo" rev-parse HEAD:tests/bin/s.sh)" != "$(git -C "$repo" rev-parse MERGE_HEAD:tests/bin/s.sh)" ] && echo yes)" \
    "$label precondition: parents differ=yes"
  assert_eq "$label precondition: staged is the $side blob=$(git -C "$repo" rev-parse :tests/bin/s.sh)" \
    "$label precondition: staged is the $side blob=$(git -C "$repo" rev-parse "$side:tests/bin/s.sh")"
  has "$label precondition: s.sh is in the staged diff" \
    "$(git -C "$repo" diff --cached --name-only)" "tests/bin/s.sh"
  gate "$repo" "$FG"
  expect_rc "$label frontmatter gate" 0 "$GATE_RC" "$GATE_ALL"
  expect_codes "$label frontmatter gate" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
  gate "$repo" "$LG"
  expect_rc "$label language-match gate" 0 "$GATE_RC" "$GATE_ALL"
  expect_codes "$label language-match gate" "$GATE_ALL" TEST_LANGUAGE_MISMATCH 0
}

# Staged equal to HEAD is absent from `git diff --cached`, so no gate sees it; JS R1-shared covers it.
case_begin "r1-shared-path-staged-equal-to-merge-head-x-side-is-existing" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/r1s-x"
mergefx "$R" "tests/bin/s.sh=r1s-base" "tests/bin/s.sh=r1s-x" "tests/bin/s.sh=r1s-y" "tests/bin/s.sh=r1s-x"
r1s_expect "R1 shared = MERGE_HEAD (X):" "$R" MERGE_HEAD
case_end

case_begin "r1-shared-path-staged-equal-to-merge-head-y-side-is-existing" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/r1s-y"
mergefx "$R" "tests/bin/s.sh=r1s-base" "tests/bin/s.sh=r1s-y" "tests/bin/s.sh=r1s-x" "tests/bin/s.sh=r1s-y"
r1s_expect "R1 shared = MERGE_HEAD (Y):" "$R" MERGE_HEAD
case_end

case_begin "r2-new-test-during-a-merge-blocks-on-every-gate" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/r2-merge"
raw r2-up '# upstream note'
mergefx "$R" "" "notes/up.txt=r2-up" "" "tests/bin/nsi.sh=ex-si tests/bin/nnomark.sh=ex-nomark tests/bin/nmm.sh=ex-mm"
assert_eq "precondition: merge in progress=$(git -C "$R" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && echo yes)" \
  "precondition: merge in progress=yes"
in_parent=no
for p in tests/bin/nsi.sh tests/bin/nnomark.sh tests/bin/nmm.sh; do
  git -C "$R" cat-file -e "HEAD:$p" 2>/dev/null && in_parent=yes
  git -C "$R" cat-file -e "MERGE_HEAD:$p" 2>/dev/null && in_parent=yes
done
assert_eq "precondition: no parent has the new tests=$in_parent" "precondition: no parent has the new tests=no"
gate "$R" "$FG"
expect_rc "R2 in a merge: frontmatter gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "R2 in a merge: nsi.sh" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
gate "$R" "$CM"
expect_rc "R2 in a merge: case-marker gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "R2 in a merge: nnomark.sh" "$GATE_OUT" MISSING_CASE_MARKERS 1
gate "$R" "$LG"
expect_rc "R2 in a merge: language-match gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "R2 in a merge: nmm.sh" "$GATE_OUT" TEST_LANGUAGE_MISMATCH 1
expect_codes "R2 in a merge: nnomark.sh" "$GATE_OUT" CASE_ADDED_WITHOUT_MARKERS 1
case_end
