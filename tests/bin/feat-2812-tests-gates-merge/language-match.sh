# Tests: bin/check-test-language-match.sh, hooks/pre-commit
# Tags: TL2, bin, merge, tests-gates, test-language-match, scope:issue-specific
# Language match during a merge: identical parents keep the single-baseline judgment (R5), differing
# parents compose per-key counts a + b - c (D6a) and case-addition sizes H + M - B (D6b), and a file
# equal to a parent still has its test-lang-exception declaration validated (D6c).
# Sourced by tests/bin/feat-2812-tests-gates-merge.sh after fixture.sh.
# shellcheck shell=bash

echo ""
echo "=== language match against the merge parents ==="

# lb <name> <tests-csv> <case>=<target>[=<echo-word>]... — a conforming bash test; LB_TAGS overrides Tags.
LB_TAGS=""
lb() {
  local name="$1" tests="$2" c n r t w
  local -a lines=("$(hdr "$tests" "${LB_TAGS:-scope:issue-specific}")")
  shift 2
  for c in "$@"; do
    n="${c%%=*}"; r="${c#*=}"; t="${r%%=*}"; w="$n"
    [ "$r" != "$t" ] && w="${r#*=}"
    lines+=("$(mcase "$n" "$t" "$w")")
  done
  raw "$name" "${lines[@]}"
}

# lm_merge <tag> <rel> <base|-> <up|-> <head|-> <staged> — a merge fixture for <rel>, then the gate.
lm_merge() {
  local tag="$1" rel="$2" b="" u="" h=""
  [ "$3" = "-" ] || b="$rel=$3"
  [ "$4" = "-" ] || u="$rel=$4"
  [ "$5" = "-" ] || h="$rel=$5"
  mergefx "$TMPBASE/lm-$tag" "$b" "$u" "$h" "$rel=$6"
  gate "$TMPBASE/lm-$tag" "$LG"
}
# expect_lm_pass <label> / expect_lm_block <label> <code> <count>
expect_lm_pass() {
  expect_rc "$1" 0 "$GATE_RC" "$GATE_ALL"
  expect_codes "$1" "$GATE_ALL" TEST_LANGUAGE_MISMATCH 0
  expect_codes "$1" "$GATE_ALL" CASE_ADDED_WITHOUT_MARKERS 0
}
expect_lm_block() {
  expect_rc "$1" 1 "$GATE_RC" "$GATE_ALL"
  expect_codes "$1" "$GATE_OUT" "$2" "$3"
}

H3="bin/foo.sh, bin/bar.sh, bin/foo.js"

case_begin "r5-identical-parents-keep-their-mismatch" "hooks/pre-commit"
lb l5-same "$H3" a=bin/foo.sh j=bin/foo.js
lb l5-edit "$H3" a=bin/foo.sh=edited j=bin/foo.js
lm_merge r5c tests/bin/l.sh - l5-same l5-same l5-edit
expect_lm_pass "R5 (c): both parents have the .js case, staged edits another case"
case_end

case_begin "r5-identical-parents-block-a-new-mismatch-target" "hooks/pre-commit"
lb l5-new "$H3" a=bin/foo.sh j=bin/foo.js k=bin/bar.js
lm_merge r5c2 tests/bin/l.sh - l5-same l5-same l5-new
expect_lm_block "R5 (c): new case on bin/bar.js" TEST_LANGUAGE_MISMATCH 1
has "R5 (c): names the new target" "$GATE_OUT" "of bin/bar.js"
case_end

case_begin "r6-case-renamed-on-the-merge-head-side-is-existing" "bin/check-test-language-match.sh"
lb lr-base "$H3" a=bin/foo.sh j=bin/foo.js
lb lr-head "$H3" a=bin/foo.sh=ah j=bin/foo.js
lb lr-up "$H3" a=bin/foo.sh j2=bin/foo.js
lb lr-staged "$H3" a=bin/foo.sh=ah j2=bin/foo.js
lm_merge rename tests/bin/l.sh lr-base lr-up lr-head lr-staged
expect_lm_pass "case j renamed to j2 on MERGE_HEAD"
case_end

case_begin "r6-mismatch-fixed-in-both-parents-blocks-when-it-returns" "bin/check-test-language-match.sh"
lb lf-head "$H3" a=bin/foo.sh
lb lf-up "$H3" a=bin/foo.sh j=bin/bar.sh
lm_merge fixed tests/bin/l.sh lr-base lf-up lf-head lr-base
expect_lm_block "HEAD dropped j, MERGE_HEAD moved it to .sh, staged has j on .js" TEST_LANGUAGE_MISMATCH 1
case_end

case_begin "r6-e3-mismatch-merge-head-removed-blocks" "bin/check-test-language-match.sh"
lb le-up "$H3" a=bin/foo.sh m=bin/bar.sh
lb le-staged "$H3" a=bin/foo.sh=ah j=bin/foo.js m=bin/bar.sh
lm_merge e3 tests/bin/l.sh lr-base le-up lr-head le-staged
expect_lm_block "E3: base and HEAD have j on .js, MERGE_HEAD removed it, staged keeps it" TEST_LANGUAGE_MISMATCH 1
case_end

case_begin "r6-l-two-parents-cases-on-one-mismatch-target-pass" "bin/check-test-language-match.sh"
lb ll-head "$H3" a=bin/foo.sh h1=bin/foo.js
lb ll-up "$H3" a=bin/foo.sh m1=bin/foo.js
lb ll-staged "$H3" a=bin/foo.sh h1=bin/foo.js m1=bin/foo.js
lm_merge l tests/bin/l.sh - ll-up ll-head ll-staged
expect_lm_pass "(l) no base, each parent one .js case, staged both"
case_end

case_begin "r6-l-a-third-case-on-the-target-blocks" "bin/check-test-language-match.sh"
lb ll-extra "$H3" a=bin/foo.sh h1=bin/foo.js m1=bin/foo.js x1=bin/foo.js
lm_merge l2 tests/bin/l.sh - ll-up ll-head ll-extra
expect_lm_block "(l) a third .js case" TEST_LANGUAGE_MISMATCH 1
case_end

# Two mismatch targets (keys case:bin/foo.js and case:bin/bar.js): the a + b - c count is per key.
H4="bin/foo.sh, bin/foo.js, bin/bar.js"
# expect_foo_only <label> — exactly one MISMATCH, on bin/foo.js, none on bin/bar.js.
expect_foo_only() {
  expect_lm_block "$1" TEST_LANGUAGE_MISMATCH 1
  has "$1: names bin/foo.js" "$GATE_OUT" "of bin/foo.js"
  case "$GATE_OUT" in
    *"of bin/bar.js"*) fail "$1" "bin/bar.js reported: $GATE_OUT" ;;
    *) pass "$1: bin/bar.js not reported" ;;
  esac
}
lb lt-head "$H4" a=bin/foo.sh h1=bin/foo.js
lb lt-up "$H4" a=bin/foo.sh m1=bin/bar.js
lb lt-ok "$H4" a=bin/foo.sh h1=bin/foo.js m1=bin/bar.js
lb lt-extra "$H4" a=bin/foo.sh h1=bin/foo.js h2=bin/foo.js m1=bin/bar.js

case_begin "r6-two-targets-one-case-from-each-parent-passes" "bin/check-test-language-match.sh"
lm_merge t1 tests/bin/l.sh - lt-up lt-head lt-ok
expect_lm_pass "two targets: H has foo.js, M has bar.js, staged both"
case_end

case_begin "r6-two-targets-extra-case-blocks-on-its-target-only" "bin/check-test-language-match.sh"
lm_merge t2 tests/bin/l.sh - lt-up lt-head lt-extra
expect_foo_only "two targets: a second foo.js case"
case_end

case_begin "r6-two-targets-shared-target-does-not-absorb-an-extra-case" "bin/check-test-language-match.sh"
# Per key: foo.js 1+2-2=1 (blocks), bar.js 0+0-1 (clamped to 0). A cross-key sum would give 0.
lb ln-head "$H4" a=bin/foo.sh j=bin/bar.js=jh h1=bin/foo.js
lb ln-up "$H4" a=bin/foo.sh j=bin/bar.js=jm
lb ln-staged "$H4" a=bin/foo.sh j=bin/bar.js=jh h1=bin/foo.js h2=bin/foo.js
lm_merge t3 tests/bin/l.sh - ln-up ln-head ln-staged
expect_foo_only "two targets: both parents have j on bar.js, staged adds a foo.js case"
case_end

# Marker-less (not conforming) bodies: bash has no case unit, so sizes are code lines (setup: 1).
raw lj-head "$(hdr 'bin/a.sh, bin/foo.sh')" 'echo one' 'assert_eq 1 1'
raw lj-up "$(hdr 'bin/a.sh, bin/foo.sh')" 'echo two' 'assert_eq 2 2'
raw lj-staged "$(hdr 'bin/a.sh, bin/foo.sh')" 'echo one' 'assert_eq 1 1' 'echo two' 'assert_eq 2 2'
raw lj-extra "$(hdr 'bin/a.sh, bin/foo.sh')" 'echo one' 'assert_eq 1 1' 'echo two' 'assert_eq 2 2' 'echo three' 'assert_eq 3 3'

case_begin "r6-j-markerless-cases-from-both-parents-pass" "bin/check-test-language-match.sh"
lm_merge j tests/bin/l.sh - lj-up lj-head lj-staged
expect_lm_pass "(j) no base, each parent one marker-less case, staged both (3+3-0 >= 5)"
case_end

case_begin "r6-k-markerless-third-case-blocks" "bin/check-test-language-match.sh"
lm_merge k tests/bin/l.sh - lj-up lj-head lj-extra
expect_lm_block "(k) a third marker-less case (7 > 3+3-0)" CASE_ADDED_WITHOUT_MARKERS 1
has "(k) basis names the 3-way sizes" "$GATE_OUT" "H+M"
case_end

# Tests: header tokens (keys hdr:<target>): each parent declares one mismatch token, staged their union.
lb lh-head "bin/foo.sh, bin/foo.js" a=bin/foo.sh
lb lh-up "bin/foo.sh, bin/bar.js" a=bin/foo.sh
lb lh-ok "bin/foo.sh, bin/foo.js, bin/bar.js" a=bin/foo.sh
lb lh-extra "bin/foo.sh, bin/foo.js, bin/bar.js, bin/baz.js" a=bin/foo.sh

case_begin "r6-header-tokens-union-of-both-parents-passes" "bin/check-test-language-match.sh"
lm_merge h1 tests/bin/l.sh - lh-up lh-head lh-ok
expect_lm_pass "header: H declares foo.js, M declares bar.js, staged both"
case_end

case_begin "r6-header-token-beyond-the-union-blocks" "bin/check-test-language-match.sh"
lm_merge h2 tests/bin/l.sh - lh-up lh-head lh-extra
expect_lm_block "header: staged adds bin/baz.js to the union" TEST_LANGUAGE_MISMATCH 1
has "header: names the new token" "$GATE_OUT" "bin/baz.js"
case "$GATE_OUT" in
  *"bin/foo.js"*|*"bin/bar.js"*) fail "header: parent tokens not reported" "$GATE_OUT" ;;
  *) pass "header: parent tokens not reported" ;;
esac
case_end

# A file only MERGE_HEAD has (R4): the merge-head blob is the single baseline of an edit during the merge.
case_begin "r4-merge-head-only-file-edit-keeps-its-mismatch" "hooks/pre-commit"
lm_merge r4a tests/bin/l.sh - l5-same - l5-edit
expect_lm_pass "R4: MERGE_HEAD-only file, staged edits the .sh case, keeps the .js case"
case_end

case_begin "r4-merge-head-only-file-edit-blocks-a-new-mismatch" "hooks/pre-commit"
lm_merge r4b tests/bin/l.sh - l5-same - l5-new
expect_lm_block "R4: MERGE_HEAD-only file, staged adds a case on bin/bar.js" TEST_LANGUAGE_MISMATCH 1
has "R4: names the new target" "$GATE_OUT" "of bin/bar.js"
case_end

# The same R4 merge with the MERGE_HEAD blob object gone: judging it as new could block a mismatch the
# parent already had, so the gate skips the file with a diagnostic instead.
case_begin "r4-unreadable-parent-blob-skips-with-a-diagnostic" "hooks/pre-commit"
R="$TMPBASE/lm-r4gone"
mergefx "$R" "" "tests/bin/l.sh=l5-same" "" "tests/bin/l.sh=l5-new"
M_OID="$(git -C "$R" rev-parse MERGE_HEAD:tests/bin/l.sh)"
rm -f "$R/.git/objects/${M_OID:0:2}/${M_OID:2}"
assert_eq "precondition: MERGE_HEAD blob unreadable=$(git -C "$R" cat-file -e "$M_OID" 2>/dev/null || echo yes)" \
  "precondition: MERGE_HEAD blob unreadable=yes"
gate "$R" "$LG"
expect_rc "R4 blob gone: skipped, not blocked" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "R4 blob gone" "$GATE_ALL" TEST_LANGUAGE_MISMATCH 0
has "R4 blob gone: diagnostic" "$GATE_ERR" "cannot read a parent blob for tests/bin/l.sh — language-match check skipped for it"
case_end

case_begin "r1-invalid-exception-is-still-reported" "bin/check-test-language-match.sh"
LB_TAGS="scope:issue-specific, test-lang-exception:other"
lb lm-bad "bin/foo.sh" a=bin/foo.sh
LB_TAGS=""
lm_merge m1 tests/bin/l.sh - lm-bad - lm-bad
expect_lm_block "(m) staged equals MERGE_HEAD, test-lang-exception:other" INVALID_TEST_LANG_EXCEPTION 1
case_end

case_begin "r1-valid-exception-with-a-parent-mismatch-passes" "bin/check-test-language-match.sh"
LB_TAGS="scope:issue-specific, test-lang-exception:e2e"
lb lm-ok "bin/foo.js" j=bin/foo.js
LB_TAGS=""
lm_merge m2 tests/bin/l.sh - lm-ok - lm-ok
expect_lm_pass "(m) staged equals MERGE_HEAD, valid exception, .js case"
expect_codes "(m) valid exception" "$GATE_ALL" TEST_LANGUAGE_UNSUPPORTED 0
case_end

case_begin "r1-unsupported-language-file-gets-no-warn" "bin/check-test-language-match.sh"
raw lm-rb '# Tests: bin/a.sh' 'puts 1'
lm_merge m3 tests/bin/u.rb - lm-rb - lm-rb
expect_rc "(m) staged .rb equals MERGE_HEAD" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "(m) declaration-only skips the language check" "$GATE_ALL" TEST_LANGUAGE_UNSUPPORTED 0
case_end

# Per-baseline clamping: base has two .js cases, each parent keeps a different one (blobs differ), so the
# 3-way existing count is H + M - B = 1 + 1 - 2 = 0. Each per-baseline "not existing" count clamps at 0,
# which would hide a staged .js case unless the surplus max(0, P - S) is added back.
lb lc-base "$H3" a=bin/foo.sh j1=bin/foo.js j2=bin/foo.js
lb lc-head "$H3" a=bin/foo.sh j1=bin/foo.js
lb lc-up "$H3" a=bin/foo.sh j2=bin/foo.js
lb lc-one "$H3" a=bin/foo.sh=edited j1=bin/foo.js
lb lc-none "$H3" a=bin/foo.sh=edited
lb lc-head2 "$H3" a=bin/foo.sh=ah j1=bin/foo.js j2=bin/foo.js

case_begin "r6-clamped-b2-h1-m1-staged-1-blocks" "bin/check-test-language-match.sh"
lm_merge cl1 tests/bin/l.sh lc-base lc-up lc-head lc-one
expect_lm_block "B=2 H=1 M=1 differing, staged keeps one .js case (1+1-2=0 existing)" TEST_LANGUAGE_MISMATCH 1
has "B=2 H=1 M=1: names bin/foo.js" "$GATE_OUT" "of bin/foo.js"
case_end

case_begin "r6-clamped-b2-h1-m1-staged-0-passes" "bin/check-test-language-match.sh"
lm_merge cl2 tests/bin/l.sh lc-base lc-up lc-head lc-none
expect_lm_pass "B=2 H=1 M=1 differing, staged has no .js case"
case_end

case_begin "r6-clamped-b2-h2-m1-staged-1-passes" "bin/check-test-language-match.sh"
lm_merge cl3 tests/bin/l.sh lc-base lc-up lc-head2 lc-one
expect_lm_pass "B=2 H=2 M=1 differing, staged 1 (2+1-2=1 existing)"
case_end

# A normal (non-merge) commit keeps its --head run: a mode-only change (staged blob == HEAD blob)
# must not turn into --declaration-only, which would drop the WARN pre-#2812 printed.
# nm_modechange <tag> <rel> <body> — a repo whose HEAD holds <rel>, then <rel> staged as executable.
nm_modechange() {
  local r="$TMPBASE/nm-$1"
  mkrepo "$r"
  apply "$r" "$2=$3"; commit_all "$r" file
  git -C "$r" update-index --chmod=+x "$2" >/dev/null 2>&1
  assert_eq "fixture nm-$1: mode-only change staged=$(git -C "$r" diff --cached --raw "$2" | grep -c '^:100644 100755')" \
    "fixture nm-$1: mode-only change staged=1"
  gate "$r" "$LG"
}

case_begin "normal-commit-mode-only-unsupported-language-keeps-its-warn" "hooks/pre-commit"
nm_modechange rb tests/bin/u.rb lm-rb
expect_rc "normal commit, mode-only .rb" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "normal commit, mode-only .rb keeps the WARN" "$GATE_ALL" TEST_LANGUAGE_UNSUPPORTED 1
has "normal commit, mode-only .rb: WARN names the path" "$GATE_ALL" "tests/bin/u.rb"
case_end

case_begin "normal-commit-mode-only-keeps-head-mismatch-parity" "hooks/pre-commit"
nm_modechange sh tests/bin/l.sh l5-same
expect_lm_pass "normal commit, mode-only .sh with a HEAD mismatch case"
case_end

# Declaration-only is for a merge path staged equal to a parent only (case m3 above); the normal
# commit keeps --head (the two cases above), and so does a merge path that differs from its parent.
case_begin "merge-edit-of-a-parent-file-keeps-the-head-run" "bin/check-test-language-match.sh"
raw lm-rb2 '# Tests: bin/a.sh' 'puts 2'
lm_merge m4 tests/bin/u.rb - lm-rb - lm-rb2
expect_rc "(m) staged .rb differs from MERGE_HEAD" 0 "$GATE_RC" "$GATE_ALL"
expect_codes "(m) differing .rb keeps the WARN" "$GATE_ALL" TEST_LANGUAGE_UNSUPPORTED 1
case_end
