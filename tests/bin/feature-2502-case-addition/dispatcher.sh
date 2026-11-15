# Split-suite dispatchers without markers (#2992 item 1): bash has no case unit, so the judgment
# compares code lines; an edit whose added code lines are all data (quoted literals, array
# elements, a closing paren) adds no case and passes, while any added command line still blocks.
# Sourced by tests/bin/feature-2502-case-addition.sh.
# shellcheck shell=bash
# shellcheck disable=SC2016 # fixture lines hold literal $0 and ${...} text on purpose

echo ""
echo "=== case addition: split-suite dispatchers ==="

# HEAD: 9 code lines (source, SPLIT_DIR, the array of two groups with its open and close, the loop).
D_PRE=('#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common' "$SRC"
  'SPLIT_DIR="$(dirname "$0")/d"' 'SPLIT_GROUPS=(' '  "g-one.sh"' '  "g-two.sh"')
D_POST=(')' 'for group in "${SPLIT_GROUPS[@]}"; do' '  bash "$SPLIT_DIR/$group"' 'done')
raw dp-head "${D_PRE[@]}" "${D_POST[@]}"

case_begin "dp-group-line-added-passes" "bin/check-test-language-match.sh"
raw dp-add-group "${D_PRE[@]}" '  "g-three.sh"' "${D_POST[@]}"
lm tests/bin/dp1.sh dp-add-group dp-head
expect_clean "dispatcher, one group line added"
case_end

case_begin "dp-group-named-like-a-harness-function-passes" "bin/check-test-language-match.sh"
raw dp-add-failopen "${D_PRE[@]}" '  "fail-open.sh"' '  "pass.sh"' "${D_POST[@]}"
lm tests/bin/dp2.sh dp-add-failopen dp-head
expect_clean "dispatcher, groups fail-open.sh and pass.sh added"
case_end

case_begin "dp-unquoted-word-inside-the-array-passes" "bin/check-test-language-match.sh"
raw dp-add-word "${D_PRE[@]}" '  g-three.sh' '  run_case' "${D_POST[@]}"
lm tests/bin/dp3.sh dp-add-word dp-head
expect_clean "dispatcher, unquoted words added inside the array"
case_end

case_begin "dp-new-file-array-only-passes" "bin/check-test-language-match.sh"
raw dp-new-data '#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common' 'SPLIT_GROUPS=(' '  "g-one.sh"' ')'
lm tests/bin/dp4.sh dp-new-data
expect_clean "new dispatcher, data lines only"
case_end

case_begin "dp-new-file-with-a-command-blocks" "bin/check-test-language-match.sh"
raw dp-new-cmd '#!/usr/bin/env bash' '# Tests: bin/a.sh, bin/foo.sh' '# Tags: scope:common' "$SRC" 'SPLIT_GROUPS=(' '  "g-one.sh"' ')'
lm tests/bin/dp5.sh dp-new-cmd
expect_added "new dispatcher, source line and array" tests/bin/dp5.sh bash "case count unavailable: no case unit; code lines 0 -> 4"
case_end

case_begin "dp-real-case-added-blocks" "bin/check-test-language-match.sh"
raw dp-add-pass "${D_PRE[@]}" "${D_POST[@]}" 'pass "dispatcher ran"'
lm tests/bin/dp6.sh dp-add-pass dp-head
expect_added "dispatcher, pass call added" tests/bin/dp6.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
raw dp-add-assert "${D_PRE[@]}" "${D_POST[@]}" 'assert_eq "$TOTAL_FAIL" 0'
lm tests/bin/dp7.sh dp-add-assert dp-head
expect_added "dispatcher, assert_eq added" tests/bin/dp7.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
raw dp-add-local "${D_PRE[@]}" "${D_POST[@]}" 'expect_clean "local helper"'
lm tests/bin/dp8.sh dp-add-local dp-head
expect_added "dispatcher, file-local expect_clean call added" tests/bin/dp8.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
case_end

case_begin "dp-group-and-real-case-added-blocks" "bin/check-test-language-match.sh"
raw dp-add-both "${D_PRE[@]}" '  "g-three.sh"' "${D_POST[@]}" 'pass "dispatcher ran"'
lm tests/bin/dp9.sh dp-add-both dp-head
expect_added "dispatcher, group line and pass call added" tests/bin/dp9.sh bash "case count unavailable: no case unit; code lines 9 -> 11"
case_end

case_begin "dp-bare-word-outside-the-array-blocks" "bin/check-test-language-match.sh"
# Outside the array one bare word is a function call, i.e. a new case.
raw dp-add-call "${D_PRE[@]}" "${D_POST[@]}" 'run_case'
lm tests/bin/dp10.sh dp-add-call dp-head
expect_added "dispatcher, run_case added after the array" tests/bin/dp10.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
case_end

case_begin "dp-element-with-command-substitution-blocks" "bin/check-test-language-match.sh"
# A quoted element that runs code is not a plain literal; doubtful lines count as commands.
raw dp-add-subst "${D_PRE[@]}" '  "$(run_hook)"' "${D_POST[@]}"
lm tests/bin/dp11.sh dp-add-subst dp-head
expect_added "dispatcher, element holding a command substitution" tests/bin/dp11.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
case_end

case_begin "dp-quoted-command-word-outside-the-array-blocks" "bin/check-test-language-match.sh"
# A quoted word at line start outside an array is a command ("$NODE" \), not a data literal.
raw dp-add-qcmd "${D_PRE[@]}" "${D_POST[@]}" '"$NODE" \'
lm tests/bin/dp12.sh dp-add-qcmd dp-head
expect_added "dispatcher, quoted command word added after the array" tests/bin/dp12.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
case_end

case_begin "dp-element-notation-variants-pass" "bin/check-test-language-match.sh"
raw dp-add-sq "${D_PRE[@]}" "  'g-three.sh'" "${D_POST[@]}"
lm tests/bin/dp13.sh dp-add-sq dp-head
expect_clean "dispatcher, single-quoted element added"
raw dp-add-two "${D_PRE[@]}" '  "g-three.sh" "g-four.sh"' "${D_POST[@]}"
lm tests/bin/dp14.sh dp-add-two dp-head
expect_clean "dispatcher, two elements on one line added"
raw dp-add-append "${D_PRE[@]}" "${D_POST[@]}" 'MORE+=(' '  "g-three.sh"' ')'
lm tests/bin/dp15.sh dp-add-append dp-head
expect_clean "dispatcher, a NAME+=( array with its element added"
case_end

case_begin "dp-element-with-backtick-blocks" "bin/check-test-language-match.sh"
# A backtick inside a double-quoted element runs code; doubtful lines count as commands.
raw dp-add-tick "${D_PRE[@]}" '  "`run_hook`"' "${D_POST[@]}"
lm tests/bin/dp16.sh dp-add-tick dp-head
expect_added "dispatcher, element holding a backtick substitution" tests/bin/dp16.sh bash "case count unavailable: no case unit; code lines 9 -> 10"
case_end

case_begin "dp-js-literal-line-still-blocks" "bin/check-test-language-match.sh"
# The data-line guard is bash only: js falls back to code lines unchanged.
DJ_PRE=('"use strict";' '// Tests: hooks/x.js, bin/foo.js' '// Tags: scope:common' 'const GROUPS = [' '  "a.js",')
DJ_POST=('];' 'for (const g of GROUPS) require(g);')
raw dpj-head "${DJ_PRE[@]}" "${DJ_POST[@]}"
raw dpj-add "${DJ_PRE[@]}" '  "b.js",' "${DJ_POST[@]}"
lm tests/bin/dpj.js dpj-add dpj-head
expect_added "js dispatcher, literal element added" tests/bin/dpj.js js "case count unavailable: no case unit; code lines 5 -> 6"
case_end
