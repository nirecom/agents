# New files and bash tests (#2502 S4-4b): a version that is not conforming (no markers or
# malformed) makes check-test-language-match.sh compare code lines, since bash
# has no case unit apart from its markers. Sourced by tests/bin/feature-2502-case-addition.sh.
# shellcheck shell=bash
# shellcheck disable=SC2016 # fixture lines hold literal $REPO and $(...) text on purpose

echo ""
echo "=== case addition: new files and bash ==="

SRC='source "$(dirname "$0")/../../tests/lib/harness.sh"'

# A new file whose header has exactly one Tests: token is a plain single-target test (rules/test.md
# needs no markers there), so 4b skips it; two or more tokens still go through 4b (user decision D1).
case_begin "ca-new-file-no-markers-one-js-token-mismatch-only" "bin/check-test-language-match.sh"
raw ca-nf-js '#!/usr/bin/env bash' '# Tests: bin/foo.js' '# Tags: scope:common' "$SRC"
lm tests/bin/n1.sh ca-nf-js
expect_rc "new file, no markers, header .js only" 1
expect_mismatch "new file, no markers, header .js only" tests/bin/n1.sh bin/foo.js
assert_eq "header .js only: CASE_ADDED lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" "header .js only: CASE_ADDED lines=0"
case_end

case_begin "ca-new-file-no-markers-two-tokens-with-js-blocks-both" "bin/check-test-language-match.sh"
raw ca-nf-js2 '#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.js' '# Tags: scope:common' "$SRC"
lm tests/bin/n3.sh ca-nf-js2
expect_mismatch "new file, no markers, header bin/a.sh + .js" tests/bin/n3.sh bin/foo.js
expect_added "new file, no markers, header bin/a.sh + .js" tests/bin/n3.sh bash "case count unavailable: no case unit; code lines 0 -> 1"
case_end

case_begin "ca-new-file-no-markers-one-sh-token-body-runs-js-passes" "bin/check-test-language-match.sh"
# One header token: 4b is skipped, and the body is never read, so starting JavaScript code passes.
raw ca-nf-body '#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:common' "$SRC" 'node "$REPO/hooks/x.js"'
lm tests/bin/n2.sh ca-nf-body
expect_clean "new file, header bin/a.sh only, body runs hooks/x.js"
case_end

case_begin "ca-new-file-no-markers-two-sh-tokens-blocks" "bin/check-test-language-match.sh"
raw ca-nf-two '#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common' "$SRC" 'node "$REPO/hooks/x.js"'
lm tests/bin/n4.sh ca-nf-two
expect_added "new file, header bin/a.sh + bin/foo.sh" tests/bin/n4.sh bash "case count unavailable: no case unit; code lines 0 -> 2"
assert_eq "two .sh tokens: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "two .sh tokens: mismatch lines=0"
case_end

# A marker-less existing bash test: two code lines of setup and two per case (6 in all). The
# shared headers list two paths, since an existing file whose Tests: has one path skips 4b.
H_SH=('#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common' "$SRC" 'run_hook() { node "$REPO/hooks/x.js"; }')
H_SH1=('#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:common' "$SRC" 'run_hook() { node "$REPO/hooks/x.js"; }')
H_SH0=('#!/usr/bin/env bash' '# Tags: scope:common' "$SRC" 'run_hook() { node "$REPO/hooks/x.js"; }')
H_E2E=('#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common, test-lang-exception:e2e' "$SRC" 'run_hook() { node "$REPO/hooks/x.js"; }')
H_OTHER=('#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common, test-lang-exception:other' "$SRC" 'run_hook() { node "$REPO/hooks/x.js"; }')
C1=('# case one' 'echo one' 'assert_eq 1 1')
C2=('# case two' 'echo two' 'assert_eq 2 2')
C3_HOOK=('# case three' 'run_hook' 'assert_eq 0 "$?"')
C3_SH=('# case three' 'bash "$REPO/bin/a.sh"' 'assert_eq 0 "$?"')
raw ca-nm-head "${H_SH[@]}" "${C1[@]}" "${C2[@]}"

case_begin "ca-no-markers-case-calling-a-helper-blocks" "bin/check-test-language-match.sh"
# codex round 2 C2: the new case reaches JavaScript code only through run_hook.
raw ca-nm-hook "${H_SH[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/b1.sh ca-nm-hook ca-nm-head
expect_added "no markers, case calls run_hook" tests/bin/b1.sh bash "case count unavailable: no case unit; code lines 6 -> 8"
assert_eq "case calls run_hook: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "case calls run_hook: mismatch lines=0"
case_end

case_begin "ca-no-markers-same-language-case-blocks" "bin/check-test-language-match.sh"
raw ca-nm-same "${H_SH[@]}" "${C1[@]}" "${C2[@]}" "${C3_SH[@]}"
lm tests/bin/b2.sh ca-nm-same ca-nm-head
expect_added "no markers, case on bin/a.sh" tests/bin/b2.sh bash "case count unavailable: no case unit; code lines 6 -> 8"
case_end

case_begin "ca-no-markers-edits-without-a-new-code-line-pass" "bin/check-test-language-match.sh"
raw ca-nm-values "${H_SH[@]}" '# case one' 'echo one' 'assert_eq 1 2' "${C2[@]}"
lm tests/bin/b3.sh ca-nm-values ca-nm-head
expect_clean "no markers, values rewritten"
raw ca-nm-delete "${H_SH[@]}" "${C1[@]}"
lm tests/bin/b4.sh ca-nm-delete ca-nm-head
expect_clean "no markers, case two deleted"
raw ca-nm-reorder "${H_SH[@]}" "${C2[@]}" '# case one' 'echo uno' 'assert_eq 1 1'
lm tests/bin/b5.sh ca-nm-reorder ca-nm-head
expect_clean "no markers, cases reordered, echo renamed"
raw ca-nm-comment "${H_SH[@]}" "${C1[@]}" '' '# a note on case two' '' "${C2[@]}"
lm tests/bin/b6.sh ca-nm-comment ca-nm-head
expect_clean "no markers, comment and blank lines only"
case_end

case_begin "ca-no-markers-assertion-added-in-a-case-blocks" "bin/check-test-language-match.sh"
# Without case identity one more code line cannot be told from a new case (Risks).
raw ca-nm-assert "${H_SH[@]}" '# case one' 'echo one' 'assert_eq 1 1' 'assert_eq 11 11' "${C2[@]}"
lm tests/bin/b7.sh ca-nm-assert ca-nm-head
expect_added "no markers, one assertion added" tests/bin/b7.sh bash "case count unavailable: no case unit; code lines 6 -> 7"
case_end

case_begin "ca-valid-exception-skips-the-judgment" "bin/check-test-language-match.sh"
raw ca-nm-e2e-head "${H_E2E[@]}" "${C1[@]}" "${C2[@]}"
raw ca-nm-e2e-work "${H_E2E[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/b8.sh ca-nm-e2e-work ca-nm-e2e-head
expect_clean "test-lang-exception:e2e, case added"
case_end

case_begin "ca-invalid-exception-still-judged" "bin/check-test-language-match.sh"
raw ca-nm-other-head "${H_OTHER[@]}" "${C1[@]}" "${C2[@]}"
raw ca-nm-other-work "${H_OTHER[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/b9.sh ca-nm-other-work ca-nm-other-head
expect_invalid "test-lang-exception:other, case added" tests/bin/b9.sh other
expect_added "test-lang-exception:other, case added" tests/bin/b9.sh bash "case count unavailable: no case unit; code lines 6 -> 8"
case_end

# Marker-adding migration (user decision D2): HEAD has no markers, the working version is
# conforming. 4b is skipped (the markers add code lines); every case target is judged instead,
# except a target whose key HEAD's header Tests: already named.
H_SHJS=('#!/usr/bin/env bash' '# Tests: bin/a.sh, hooks/x.js' '# Tags: scope:common' "$SRC" 'run_hook() { node "$REPO/hooks/x.js"; }')
MK_1=("$MB \"one\" \"bin/a.sh\"" 'echo one' 'assert_eq 1 1' "$ME")
MK_2=("$MB \"two\" \"bin/a.sh\"" 'echo two' 'assert_eq 2 2' "$ME")
MK_JS=("$MB \"three\" \"hooks/x.js\"" 'run_hook' 'assert_eq 0 "$?"' "$ME")

case_begin "ca-markers-added-all-sh-targets-pass" "bin/check-test-language-match.sh"
raw ca-mk-sh "${H_SH[@]}" "${MK_1[@]}" "${MK_2[@]}"
lm tests/bin/k1.sh ca-mk-sh ca-nm-head
expect_clean "markers added, every target bin/a.sh"
case_end

case_begin "ca-markers-added-js-target-not-in-head-header-blocks" "bin/check-test-language-match.sh"
raw ca-mk-js "${H_SH[@]}" "${MK_1[@]}" "${MK_2[@]}" "${MK_JS[@]}"
lm tests/bin/k2.sh ca-mk-js ca-nm-head
expect_rc "markers added, hooks/x.js target new to the header" 1
case "$LM_OUT" in
  *"HIGH: tests/bin/k2.sh"*"hooks/x.js"*"code=TEST_LANGUAGE_MISMATCH"*) pass "hooks/x.js target: TEST_LANGUAGE_MISMATCH" ;;
  *) fail "hooks/x.js target" "no TEST_LANGUAGE_MISMATCH line for hooks/x.js: out=[$LM_OUT] err=[$LM_ERR]" ;;
esac
assert_eq "hooks/x.js target: CASE_ADDED lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" "hooks/x.js target: CASE_ADDED lines=0"
case_end

case_begin "ca-markers-added-js-target-in-head-header-passes" "bin/check-test-language-match.sh"
raw ca-mk-js-head "${H_SHJS[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
raw ca-mk-js-work "${H_SHJS[@]}" "${MK_1[@]}" "${MK_2[@]}" "${MK_JS[@]}"
lm tests/bin/k3.sh ca-mk-js-work ca-mk-js-head
expect_clean "markers added, hooks/x.js already in HEAD's header"
case_end

# Malformed in both versions: the first case is never closed.
H_A=('#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common' "$SRC")
raw ca-mal-head "${H_A[@]}" "$MB \"a\" \"bin/a.sh\"" 'echo a'

# bash has no case unit apart from its markers (user decision 2026-10-24), so case-count is
# always rc 1 and every row below compares code lines.
case_begin "ca-malformed-case-added-uses-code-lines" "bin/check-test-language-match.sh"
raw ca-mal-add "${H_A[@]}" "$MB \"a\" \"bin/a.sh\"" 'echo a' "$MB \"n\" \"bin/a.sh\"" 'echo n' "$ME"
lm tests/bin/m1.sh ca-mal-add ca-mal-head
expect_added "malformed, case n added" tests/bin/m1.sh bash "case count unavailable: no case unit; code lines 3 -> 6"
case_end

case_begin "ca-malformed-line-rewritten-passes" "bin/check-test-language-match.sh"
raw ca-mal-edit "${H_A[@]}" "$MB \"a\" \"bin/a.sh\"" 'echo b'
lm tests/bin/m2.sh ca-mal-edit ca-mal-head
expect_clean "malformed, a line rewritten"
case_end

case_begin "ca-malformed-unclosed-marker-less-case-added-uses-code-lines" "bin/check-test-language-match.sh"
# Review F1: a marker-less case added after an unclosed one adds no marker line, only code lines.
raw ca-mal-nm-add "${H_A[@]}" "$MB \"a\" \"bin/a.sh\"" 'echo a' '# case n' 'echo n' 'assert_eq 1 1'
lm tests/bin/m5.sh ca-mal-nm-add ca-mal-head
expect_added "malformed, marker-less case n added" tests/bin/m5.sh bash "case count unavailable: no case unit; code lines 3 -> 5"
case_end

case_begin "ca-duplicate-name-marker-less-case-added-uses-code-lines" "bin/check-test-language-match.sh"
# Markers balanced and closed, but case a is named twice (duplicate-name), so neither version
# is conforming; a marker-less case adds no marker line, only code lines (7 -> 9).
DUP_A=("$MB \"a\" \"bin/a.sh\"" 'echo a' "$ME" "$MB \"a\" \"bin/a.sh\"" 'echo a2' "$ME")
raw ca-dup-head "${H_A[@]}" "${DUP_A[@]}"
raw ca-dup-nm-add "${H_A[@]}" "${DUP_A[@]}" '# case n' 'echo n' 'assert_eq 1 1'
lm tests/bin/m7.sh ca-dup-nm-add ca-dup-head
expect_added "duplicate name, marker-less case n added" tests/bin/m7.sh bash "case count unavailable: no case unit; code lines 7 -> 9"
case_end

# HEAD conforming (cases a and b), the working version malformed.
CF_A=("$MB \"a\" \"bin/a.sh\"" 'echo a' "$ME")
raw ca-cf-head "${H_A[@]}" "${CF_A[@]}" "$MB \"b\" \"bin/a.sh\"" 'echo b' "$ME"

case_begin "ca-conforming-to-malformed-no-case-passes" "bin/check-test-language-match.sh"
raw ca-cf-broken "${H_A[@]}" "${CF_A[@]}" "$MB \"b\" \"bin/a.sh\"" 'echo b'
lm tests/bin/m3.sh ca-cf-broken ca-cf-head
expect_clean "last end marker dropped"
case_end

case_begin "ca-conforming-to-malformed-case-added-blocks" "bin/check-test-language-match.sh"
raw ca-cf-broken-add "${H_A[@]}" "${CF_A[@]}" "$MB \"b\" \"bin/a.sh\"" 'echo b' "$MB \"c\" \"bin/a.sh\"" 'echo c' "$ME"
lm tests/bin/m4.sh ca-cf-broken-add ca-cf-head
expect_added "end marker dropped, case c added" tests/bin/m4.sh bash "case count unavailable: no case unit; code lines 7 -> 9"
case_end

case_begin "ca-conforming-marked-case-added-passes" "bin/check-test-language-match.sh"
# Review F1 control: both versions conforming, so the case-addition judgment never runs.
raw ca-cf-add "${H_A[@]}" "${CF_A[@]}" "$MB \"b\" \"bin/a.sh\"" 'echo b' "$ME" "$MB \"c\" \"bin/a.sh\"" 'echo c' "$ME"
lm tests/bin/m6.sh ca-cf-add ca-cf-head
expect_clean "conforming, marked case c added"
case_end

# A deps op that fails (the version counts as not conforming): tests/hooks/feature-2507-case-addition-node.js.

# Rule b (user decision 2026-10-22): the working version's Tests: token count decides 4b for an
# existing file too. Exactly one path skips it; zero tokens and two or more are still judged.
raw ca-nm1-head "${H_SH1[@]}" "${C1[@]}" "${C2[@]}"

case_begin "ca-no-markers-one-path-case-added-passes" "bin/check-test-language-match.sh"
raw ca-nm1-add "${H_SH1[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/t1.sh ca-nm1-add ca-nm1-head
expect_clean "no markers, one path, case calling run_hook added"
case_end

case_begin "ca-no-markers-tests-grown-to-two-paths-case-added-blocks" "bin/check-test-language-match.sh"
raw ca-nm1-grow "${H_SH[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/t2.sh ca-nm1-grow ca-nm1-head
expect_added "no markers, Tests: 1 -> 2 paths, case added" tests/bin/t2.sh bash "case count unavailable: no case unit; code lines 6 -> 8"
assert_eq "Tests: 1 -> 2 paths: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "Tests: 1 -> 2 paths: mismatch lines=0"
case_end

case_begin "ca-no-markers-tests-shrunk-to-one-path-case-added-passes" "bin/check-test-language-match.sh"
# The working version's token count decides, so dropping a path in the same edit skips 4b.
raw ca-nm2-shrink "${H_SH1[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/t3.sh ca-nm2-shrink ca-nm-head
expect_clean "no markers, Tests: 2 -> 1 path, case added"
case_end

case_begin "ca-no-markers-one-path-header-retargeted-to-js-mismatch-only" "bin/check-test-language-match.sh"
raw ca-nm1-js "${H_SH1[0]}" '# Tests: hooks/x.js' "${H_SH1[@]:2}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/t4.sh ca-nm1-js ca-nm1-head
expect_rc "no markers, one path retargeted to hooks/x.js" 1
expect_mismatch "no markers, one path retargeted to hooks/x.js" tests/bin/t4.sh hooks/x.js
assert_eq "retargeted to hooks/x.js: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "retargeted to hooks/x.js: mismatch lines=1"
assert_eq "retargeted to hooks/x.js: CASE_ADDED lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" "retargeted to hooks/x.js: CASE_ADDED lines=0"
case_end

case_begin "ca-markers-added-one-path-js-target-blocks" "bin/check-test-language-match.sh"
# Pins _tlm_migration ahead of the token count: the case on hooks/x.js begins on line 14.
raw ca-mk1-js "${H_SH1[@]}" "${MK_1[@]}" "${MK_2[@]}" "${MK_JS[@]}"
lm tests/bin/t5.sh ca-mk1-js ca-nm1-head
expect_rc "one path, markers added, hooks/x.js target" 1
case "$LM_OUT" in
  *"HIGH: tests/bin/t5.sh line 14: "*"of hooks/x.js "*"code=TEST_LANGUAGE_MISMATCH"*) pass "one path migration: mismatch on line 14" ;;
  *) fail "one path migration" "no line-14 TEST_LANGUAGE_MISMATCH for hooks/x.js: out=[$LM_OUT] err=[$LM_ERR]" ;;
esac
assert_eq "one path migration: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "one path migration: mismatch lines=1"
assert_eq "one path migration: CASE_ADDED lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" "one path migration: CASE_ADDED lines=0"
case_end

case_begin "ca-no-markers-no-tests-header-case-added-blocks" "bin/check-test-language-match.sh"
# Zero tokens stays fail-closed: the condition is "not exactly one", not "two or more".
raw ca-nm0-head "${H_SH0[@]}" "${C1[@]}" "${C2[@]}"
raw ca-nm0-add "${H_SH0[@]}" "${C1[@]}" "${C2[@]}" "${C3_HOOK[@]}"
lm tests/bin/t6.sh ca-nm0-add ca-nm0-head
expect_added "no markers, no Tests: line, case added" tests/bin/t6.sh bash "case count unavailable: no case unit; code lines 6 -> 8"
assert_eq "no Tests: line: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "no Tests: line: mismatch lines=0"
case_end
