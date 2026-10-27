# Tests: hooks/lib/precommit-tests-frontmatter.sh, bin/check-test-frontmatter.sh
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, case-markers, scope:issue-specific
# #2748 reproduction: a test file only MERGE_HEAD has, staged unchanged, is an existing file for
# every tests/ gate; the same bodies staged as new files still block (the false-green control).
# Sourced by tests/bin/feat-2812-tests-gates-merge-shapes.sh after fixture.sh and bodies.sh (EX_PAIRS).
# shellcheck shell=bash

echo ""
echo "=== existence: files that came from MERGE_HEAD ==="

case_begin "merge-head-only-files-pass-every-gate" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/ex-merge"
mergefx "$R" "" "$EX_PAIRS" "" ""
git -C "$R" update-index --chmod=+x -- tests/bin/mode.sh
head_has=no
git -C "$R" cat-file -e HEAD:tests/bin/si.sh 2>/dev/null && head_has=yes
assert_eq "precondition: HEAD has tests/bin/si.sh=$head_has" "precondition: HEAD has tests/bin/si.sh=no"
assert_eq "precondition: staged si.sh is the MERGE_HEAD blob $(git -C "$R" rev-parse MERGE_HEAD:tests/bin/si.sh)" \
  "precondition: staged si.sh is the MERGE_HEAD blob $(git -C "$R" rev-parse :tests/bin/si.sh)"
has "precondition: mode.sh staged executable" "$(git -C "$R" ls-files -s -- tests/bin/mode.sh)" "100755 "
gate "$R" "$FG"
expect_rc "frontmatter gate, MERGE_HEAD-only files" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "frontmatter gate" "$GATE_ALL" SELF_IMPLEMENTED_HARNESS 0
expect_codes "frontmatter gate" "$GATE_ALL" FLAT_TEST_SH_REJECTED 0
expect_codes "frontmatter gate" "$GATE_ALL" MISSING_HARNESS_SOURCE 0
gate "$R" "$CM"
expect_rc "case-marker gate, MERGE_HEAD-only files" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "case-marker gate" "$GATE_ALL" MISSING_CASE_MARKERS 0
gate "$R" "$LG"
expect_rc "language-match gate, MERGE_HEAD-only files" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "language-match gate" "$GATE_ALL" TEST_LANGUAGE_MISMATCH 0
expect_codes "language-match gate" "$GATE_ALL" CASE_ADDED_WITHOUT_MARKERS 0
gate "$R" "$FG" "$CM" "$LG"
expect_rc "all three gates in one shell" 0 "$GATE_RC" "$GATE_ALL"
case_end

case_begin "same-bodies-staged-as-new-files-still-block" "hooks/lib/precommit-tests-frontmatter.sh"
R="$TMPBASE/ex-plain"
mkrepo "$R"
apply "$R" "$EX_PAIRS"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" update-index --chmod=+x -- tests/bin/mode.sh
gate "$R" "$FG"
expect_rc "control frontmatter gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "control frontmatter gate (si.sh, mode.sh)" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 2
expect_codes "control frontmatter gate (flat.sh)" "$GATE_OUT" FLAT_TEST_SH_REJECTED 1
expect_codes "control frontmatter gate (nosrc.sh)" "$GATE_OUT" MISSING_HARNESS_SOURCE 1
gate "$R" "$CM"
expect_rc "control case-marker gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "control case-marker gate (nomark.sh)" "$GATE_OUT" MISSING_CASE_MARKERS 1
gate "$R" "$LG"
expect_rc "control language-match gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "control language-match gate (mm.sh)" "$GATE_OUT" TEST_LANGUAGE_MISMATCH 1
expect_codes "control language-match gate (nomark.sh)" "$GATE_OUT" CASE_ADDED_WITHOUT_MARKERS 1
case_end

case_begin "non-merge-edit-of-an-existing-file-blocks-as-before" "bin/check-test-frontmatter.sh"
raw ex-one "$(hdr bin/a.sh)" 'PASS=0' "$(mcase a bin/a.sh)"
raw ex-two "$(hdr bin/a.sh)" 'PASS=0' 'PASS=0' "$(mcase a bin/a.sh)"
raw ex-edit "$(hdr bin/a.sh)" 'PASS=0' "$(mcase a bin/a.sh edited)"
R="$TMPBASE/ex-nonmerge"
mkrepo "$R"
apply "$R" "tests/bin/e.sh=ex-one"
commit_all "$R" e
apply "$R" "tests/bin/e.sh=ex-two"
git -C "$R" add -A >/dev/null 2>&1
gate "$R" "$FG" "$CM" "$LG"
expect_rc "non-merge: one counter added" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "non-merge: one counter added" "$GATE_OUT" SELF_IMPLEMENTED_HARNESS 1
apply "$R" "tests/bin/e.sh=ex-edit"
git -C "$R" add -A >/dev/null 2>&1
gate "$R" "$FG" "$CM" "$LG"
expect_rc "non-merge: unrelated line edited" 0 "$GATE_RC" "$GATE_ALL"
assert_eq "non-merge: merge-parents note lines=$(count_note "$GATE_ALL")" "non-merge: merge-parents note lines=0"
case_end

# MERGE_HEAD-only files edited during the merge (staged blob != MERGE_HEAD blob): the flat-test
# rejection, the helper-library check and the case-marker check still see a parent that has them.
# Each edit changes one existing line only, so no counter, case or code line is added.
raw ex-flat-ed "$(hdr bin/a.sh)" "$(mcase a bin/a.sh edited)"
raw ex-nosrc-ed '#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:issue-specific' "$(mcase a bin/a.sh edited)"
raw ex-nomark-ed "$(hdr 'bin/a.sh, bin/foo.sh')" 'echo uno'
EX_UP_PAIRS="tests/flat.sh=ex-flat tests/bin/nosrc.sh=ex-nosrc tests/bin/nomark.sh=ex-nomark"
EX_ED_PAIRS="tests/flat.sh=ex-flat-ed tests/bin/nosrc.sh=ex-nosrc-ed tests/bin/nomark.sh=ex-nomark-ed"

case_begin "merge-head-only-files-edited-in-the-merge-skip-the-new-file-checks" "bin/check-test-frontmatter.sh"
R="$TMPBASE/ex-merge-ed"
mergefx "$R" "" "$EX_UP_PAIRS" "" "$EX_ED_PAIRS"
for EX_REL in tests/flat.sh tests/bin/nosrc.sh tests/bin/nomark.sh; do
  EX_HEAD_HAS=no
  git -C "$R" cat-file -e "HEAD:$EX_REL" 2>/dev/null && EX_HEAD_HAS=yes
  assert_eq "precondition: HEAD has $EX_REL=$EX_HEAD_HAS" "precondition: HEAD has $EX_REL=no"
  EX_SAME=yes
  [ "$(git -C "$R" rev-parse "MERGE_HEAD:$EX_REL")" = "$(git -C "$R" rev-parse ":$EX_REL")" ] || EX_SAME=no
  assert_eq "precondition: staged $EX_REL equals the MERGE_HEAD blob=$EX_SAME" \
    "precondition: staged $EX_REL equals the MERGE_HEAD blob=no"
done
gate "$R" "$FG"
expect_rc "frontmatter gate, edited MERGE_HEAD-only files" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "frontmatter gate, edited flat.sh in a parent" "$GATE_ALL" FLAT_TEST_SH_REJECTED 0
expect_codes "frontmatter gate, edited nosrc.sh in a parent" "$GATE_ALL" MISSING_HARNESS_SOURCE 0
gate "$R" "$CM"
expect_rc "case-marker gate, edited MERGE_HEAD-only files" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "case-marker gate, edited nomark.sh in a parent" "$GATE_ALL" MISSING_CASE_MARKERS 0
case_end

case_begin "edited-bodies-in-no-parent-still-block-during-a-merge" "bin/check-test-frontmatter.sh"
# Contrast: the same edited bodies during a merge where neither HEAD nor MERGE_HEAD has the paths.
R="$TMPBASE/ex-merge-none"
mergefx "$R" "" "" "" "$EX_ED_PAIRS"
EX_MP_HAS=no
git -C "$R" cat-file -e "MERGE_HEAD:tests/flat.sh" 2>/dev/null && EX_MP_HAS=yes
assert_eq "precondition: MERGE_HEAD has tests/flat.sh=$EX_MP_HAS" "precondition: MERGE_HEAD has tests/flat.sh=no"
gate "$R" "$FG"
expect_rc "contrast frontmatter gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "contrast frontmatter gate (flat.sh)" "$GATE_OUT" FLAT_TEST_SH_REJECTED 1
expect_codes "contrast frontmatter gate (nosrc.sh)" "$GATE_OUT" MISSING_HARNESS_SOURCE 1
gate "$R" "$CM"
expect_rc "contrast case-marker gate" 1 "$GATE_RC" "$GATE_ALL"
expect_codes "contrast case-marker gate (nomark.sh)" "$GATE_OUT" MISSING_CASE_MARKERS 1
case_end
