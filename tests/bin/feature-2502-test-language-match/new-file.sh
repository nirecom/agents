# New files: no --head (#2502 S4-3, S4-5, S4-6). Sourced by tests/bin/feature-2502-test-language-match.sh.
# shellcheck shell=bash

echo ""
echo "=== new file ==="

body nf-hdr-js "scope:common" "bin/foo.sh, bin/bar.sh, bin/foo.js" a=bin/foo.sh b=bin/bar.sh
body nf-case-js "scope:common" "bin/foo.sh, bin/bar.sh" a=bin/foo.sh b=bin/foo.js
body nf-nomark-js "scope:common" "bin/foo.js"
body nf-same "scope:common" "bin/foo.sh, bin/bar.sh" a=bin/foo.sh b=bin/bar.sh
body nf-other-js "scope:common, test-lang-exception:other" "bin/foo.js"
body nf-other-sh "scope:common, test-lang-exception:other" "bin/foo.sh"
# The next two carry case markers: a new file without them also meets the case-addition
# judgment (S4-4b, tests/bin/feature-2502-case-addition.sh), which these rows are not about.
body nf-two-decl "scope:common, test-lang-exception:e2e, test-lang-exception:text-only" "bin/foo.sh" a=bin/foo.sh
body nf-docs "scope:common" "docs/x.md, hooks/lib/x.json" a=docs/x.md b=hooks/lib/x.json
printf '%s\n' '# Tests: bin/foo.js' '# Tags: scope:common' 'puts 1' > "$BODIES/nf-ruby"
# A `Tags:` line past headerMaxLines (10) is body text: its exception value must not count.
printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/foo.js' ': 3' ': 4' ': 5' ': 6' ': 7' ': 8' ': 9' ': 10' ': 11' \
  '# Tags: scope:common, test-lang-exception:e2e' > "$BODIES/nf-late-tags"

case_begin "nf-header-token-mismatch-blocks" "bin/check-test-language-match.sh"
lm tests/bin/x1.sh nf-hdr-js
expect_rc "header has a .js token" 1
expect_mismatch "header has a .js token" tests/bin/x1.sh bin/foo.js
assert_eq "$(count_code TEST_LANGUAGE_MISMATCH)" 1
case_end

case_begin "nf-case-target-mismatch-blocks" "bin/check-test-language-match.sh"
lm tests/bin/x2.sh nf-case-js
expect_rc "header .sh only, a case targets .js" 1
expect_mismatch "header .sh only, a case targets .js" tests/bin/x2.sh bin/foo.js
case_end

case_begin "nf-no-markers-header-mismatch-blocks" "bin/check-test-language-match.sh"
lm tests/bin/x3.sh nf-nomark-js
expect_rc "no markers, header .js" 1
expect_mismatch "no markers, header .js" tests/bin/x3.sh bin/foo.js
# One header token: S4-4b skips the new file (user decision D1), so only the mismatch is reported.
# Two or more tokens are covered in tests/bin/feature-2502-case-addition/existing-bash.sh.
assert_eq "no markers, header .js: CASE_ADDED_WITHOUT_MARKERS lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" \
  "no markers, header .js: CASE_ADDED_WITHOUT_MARKERS lines=0"
case_end

case_begin "nf-exception-past-header-ignored" "bin/check-test-language-match.sh"
lm tests/bin/x3b.sh nf-late-tags
expect_rc "exception Tags line at line 12" 1
expect_mismatch "exception Tags line at line 12" tests/bin/x3b.sh bin/foo.js
case_end

case_begin "nf-exception-value-table" "bin/check-test-language-match.sh"
# <value>|<verdict> on a new bash test naming JavaScript code. clean: the allowed value
# suppresses the mismatch. invalid: the value is reported and suppresses nothing.
_n=0
while IFS='|' read -r _val _want; do
  _n=$((_n + 1))
  body "nf-exc-$_n" "scope:common, test-lang-exception:$_val" "bin/foo.js"
  lm "tests/bin/x4-$_n.sh" "nf-exc-$_n"
  if [ "$_want" = clean ]; then
    expect_clean "test-lang-exception:$_val"
  else
    expect_rc "test-lang-exception:'$_val'" 1
    expect_invalid "test-lang-exception:'$_val'" "tests/bin/x4-$_n.sh" "$_val"
    expect_mismatch "test-lang-exception:'$_val' does not suppress" "tests/bin/x4-$_n.sh" bin/foo.js
  fi
done <<'ROWS'
text-only|clean
symmetry|clean
e2e|clean
|invalid
ROWS
assert_eq "exception rows read=$_n" "exception rows read=4"
unset _n _val _want
case_end

case_begin "nf-invalid-exception-and-mismatch-both-reported" "bin/check-test-language-match.sh"
lm tests/bin/x5.sh nf-other-js
expect_rc "other + .js" 1
expect_invalid "other + .js" tests/bin/x5.sh other
expect_mismatch "other + .js does not suppress" tests/bin/x5.sh bin/foo.js
case_end

case_begin "nf-invalid-exception-alone-blocks" "bin/check-test-language-match.sh"
lm tests/bin/x6.sh nf-other-sh
expect_rc "other, no mismatch" 1
expect_invalid "other, no mismatch" tests/bin/x6.sh other
assert_eq "$(count_code TEST_LANGUAGE_MISMATCH)" 0
case_end

case_begin "nf-two-declarations-invalid" "bin/check-test-language-match.sh"
lm tests/bin/x7.sh nf-two-decl
expect_rc "two declarations" 1
assert_eq "$(count_code INVALID_TEST_LANG_EXCEPTION)" 1
case "$LM_OUT" in
  "HIGH: tests/bin/x7.sh: invalid test-lang-exception value '"*"' (allowed: text-only symmetry e2e) code=INVALID_TEST_LANG_EXCEPTION") pass "two declarations: line shape" ;;
  *) fail "two declarations" "out=[$LM_OUT] err=[$LM_ERR]" ;;
esac
case_end

case_begin "nf-same-language-passes" "bin/check-test-language-match.sh"
lm tests/bin/x8.sh nf-same
expect_clean "bash test on bash code"
case_end

case_begin "nf-unregistered-language-warns" "bin/check-test-language-match.sh"
lm tests/bin/x.rb nf-ruby
expect_rc "unregistered language" 0
assert_eq "$(count_code TEST_LANGUAGE_UNSUPPORTED)" 1
case "$LM_OUT" in
  "WARN: tests/bin/x.rb: "*" code=TEST_LANGUAGE_UNSUPPORTED") pass "unregistered language: WARN names the rel path" ;;
  *) fail "unregistered language" "out=[$LM_OUT] err=[$LM_ERR]" ;;
esac
case_end

case_begin "nf-docs-and-json-tokens-not-judged" "bin/check-test-language-match.sh"
lm tests/bin/x9.sh nf-docs
expect_clean "docs and json tokens"
case_end

case_begin "nf-infra-error-exit-2" "bin/check-test-language-match.sh"
# A checkout holding the CLI alone: its lib is unreachable, an infra error rather than a verdict.
mkdir -p "$TMPBASE/lone/bin"
if cp "$LM_CLI_REAL" "$TMPBASE/lone/bin/check-test-language-match.sh" 2>/dev/null; then
  LM_CLI="$TMPBASE/lone/bin/check-test-language-match.sh"
  lm tests/bin/x1.sh nf-hdr-js
  expect_rc "lib unreachable" 2
  LM_CLI="$LM_CLI_REAL"
else
  fail "lib unreachable" "cannot copy $LM_CLI_REAL"
fi
case_end
