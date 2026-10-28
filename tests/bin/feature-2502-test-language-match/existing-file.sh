# Files HEAD already has: --head carries the HEAD copy, and only a mismatch HEAD did not have
# blocks (#2502 S4-4, S4-6). Sourced by tests/bin/feature-2502-test-language-match.sh.
# shellcheck shell=bash

echo ""
echo "=== existing file ==="

HDR="bin/foo.sh, bin/bar.sh"
body ef-base "scope:common" "$HDR" a=bin/foo.sh b=bin/bar.sh
# HEAD already has one case on JavaScript code (an existing mismatch).
body ef-base-js "scope:common" "$HDR" a=bin/foo.sh j=bin/foo.js

case_begin "ef-tags-changed-to-invalid-exception" "bin/check-test-language-match.sh"
body ef-tags-other "scope:common, test-lang-exception:other" "$HDR" a=bin/foo.sh b=bin/bar.sh
lm tests/bin/e1.sh ef-tags-other ef-base
expect_rc "Tags now test-lang-exception:other" 1
expect_invalid "Tags now test-lang-exception:other" tests/bin/e1.sh other
assert_eq "$(count_code TEST_LANGUAGE_MISMATCH)" 0
case_end

case_begin "ef-added-case-on-js-blocks" "bin/check-test-language-match.sh"
body ef-add-js "scope:common" "$HDR" a=bin/foo.sh b=bin/bar.sh c=bin/foo.js
lm tests/bin/e2.sh ef-add-js ef-base
expect_rc "new case c targets .js" 1
expect_mismatch "new case c targets .js" tests/bin/e2.sh bin/foo.js
case_end

case_begin "ef-added-case-sharing-a-kept-js-target-blocks" "bin/check-test-language-match.sh"
body ef-add-js-kept "scope:common" "$HDR" a=bin/foo.sh j=bin/foo.js k=bin/foo.js
lm tests/bin/e3.sh ef-add-js-kept ef-base-js
expect_rc "new case k, HEAD case j kept on the same target" 1
expect_mismatch "new case k" tests/bin/e3.sh bin/foo.js
assert_eq "$(count_code TEST_LANGUAGE_MISMATCH)" 1
case_end

case_begin "ef-rename-only-passes" "bin/check-test-language-match.sh"
body ef-rename "scope:common" "$HDR" a=bin/foo.sh j2=bin/foo.js
lm tests/bin/e4.sh ef-rename ef-base-js
expect_clean "case j renamed to j2, same target"
case_end

case_begin "ef-body-change-passes" "bin/check-test-language-match.sh"
body ef-body "scope:common" "$HDR" a=bin/foo.sh j=bin/foo.js=changed
lm tests/bin/e5.sh ef-body ef-base-js
expect_clean "body of the .js case changed"
case_end

case_begin "ef-deletion-passes" "bin/check-test-language-match.sh"
body ef-delete "scope:common" "$HDR" a=bin/foo.sh
lm tests/bin/e6.sh ef-delete ef-base-js
expect_clean "the .js case deleted"
case_end

case_begin "ef-target-moved-to-js-blocks" "bin/check-test-language-match.sh"
body ef-retarget "scope:common" "$HDR" a=bin/foo.sh b=bin/bar.js
lm tests/bin/e7.sh ef-retarget ef-base
expect_rc "case b moved from .sh to .js" 1
expect_mismatch "case b moved from .sh to .js" tests/bin/e7.sh bin/bar.js
case_end

case_begin "ef-js-mismatch-retargeted-to-py-passes" "bin/check-test-language-match.sh"
# Plan S4-4: the paired HEAD case j already sat on mismatched code (.js), so moving it to other
# mismatched code (.py) is an existing state; the count of mismatched cases does not grow.
body ef-retarget-py "scope:common" "$HDR" a=bin/foo.sh j=bin/m.py
lm tests/bin/e11.sh ef-retarget-py ef-base-js
expect_clean "case j moved from .js to .py, HEAD already mismatched"
case_end

case_begin "ef-no-markers-header-gains-js-blocks" "bin/check-test-language-match.sh"
body ef-nm-head "scope:common" "bin/foo.sh"
body ef-nm-work "scope:common" "bin/foo.sh, bin/foo.js"
lm tests/bin/e8.sh ef-nm-work ef-nm-head
expect_rc "no markers, header gains bin/foo.js" 1
expect_mismatch "no markers, header gains bin/foo.js" tests/bin/e8.sh bin/foo.js
# No case and no code line was added, so the S4-4b case-addition judgment stays quiet.
assert_eq "header gains bin/foo.js: CASE_ADDED_WITHOUT_MARKERS lines=$(count_code CASE_ADDED_WITHOUT_MARKERS)" \
  "header gains bin/foo.js: CASE_ADDED_WITHOUT_MARKERS lines=0"
case_end

case_begin "ef-no-markers-header-already-had-js-passes" "bin/check-test-language-match.sh"
# A value rewrite keeps the code-line count, so the S4-4b case-addition judgment stays quiet too.
body ef-nm-head-js "scope:common" "bin/foo.sh, bin/foo.js"
cp "$BODIES/ef-nm-head-js" "$BODIES/ef-nm-work-js"
printf 'echo before\n' >> "$BODIES/ef-nm-head-js"
printf 'echo changed\n' >> "$BODIES/ef-nm-work-js"
lm tests/bin/e9.sh ef-nm-work-js ef-nm-head-js
expect_clean "no markers, bin/foo.js already in the HEAD header"
case_end

case_begin "ef-valid-exception-lets-a-js-case-in" "bin/check-test-language-match.sh"
body ef-exc-add-js "scope:common, test-lang-exception:e2e" "$HDR" a=bin/foo.sh b=bin/bar.sh c=bin/foo.js
lm tests/bin/e10.sh ef-exc-add-js ef-base
expect_clean "test-lang-exception:e2e, new .js case"
case_end

echo ""
echo "=== existing file, pester / pytest / js ==="

# mbody <name> <test-language> <tests-csv> <case>=<target>... — a conforming multi-case body in
# that language (the lbody notation of languages.sh, one marked case per argument).
mbody() {
  local out="$BODIES/$1" tl="$2" tests="$3" c n t
  shift 3
  case "$tl" in
    pester) printf '%s\n' "# Tests: $tests" '# Tags: scope:common' > "$out" ;;
    pytest) printf '%s\n' "# Tests: $tests" '# Tags: scope:common' 'import pytest' > "$out" ;;
    js) printf '%s\n' '"use strict";' "// Tests: $tests" '// Tags: scope:common' 'const { test } = require("node:test");' \
      "const { $LJB, $LJE } = require(\"../lib/harness\");" > "$out" ;;
  esac
  for c in "$@"; do
    n="${c%%=*}"; t="${c#*=}"
    case "$tl" in
      pester) printf '%s\n' "Describe '$n' -Tag 'target:$t' {" "    It 'runs' { 1 | Should -Be 1 }" '}' >> "$out" ;;
      pytest) printf '%s\n' '' '' "@pytest.mark.target(\"$t\")" "def test_$n():" '    assert True' >> "$out" ;;
      js) printf '%s\n' "$LJB(\"$n\", \"$t\");" "test(\"$n\", () => {});" "$LJE();" >> "$out" ;;
    esac
  done
}

# A row is "<test-language> <rel> <same-1> <same-2> <other-target> <other-code-language>".
EF_LANG_ROWS='pester tests/bin/ef1.Tests.ps1 bin/m.ps1 bin/m.psm1 bin/m.py pytest
pytest tests/bin/test_ef2.py bin/m.py bin/tool-py bin/m.cjs js
js tests/bin/ef3.js bin/m.cjs bin/m.mjs bin/m.ps1 pester'

# ef_row <test-language> — sets EF_REL EF_S1 EF_S2 EF_OTHER EF_OL from $EF_LANG_ROWS.
ef_row() {
  local tl
  EF_REL=""
  while read -r tl EF_REL EF_S1 EF_S2 EF_OTHER EF_OL; do
    [ "$tl" = "$1" ] && return 0
  done <<< "$EF_LANG_ROWS"
  fail "$1 row" "no EF_LANG_ROWS row for $1"
  return 1
}

# expect_lang_mismatch <label> <test-language> <code-language> <target> — exactly one
# TEST_LANGUAGE_MISMATCH line, naming both languages and <target>.
expect_lang_mismatch() {
  local line found=0
  expect_rc "$1" 1
  assert_eq "$1: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "$1: mismatch lines=1"
  while IFS= read -r line; do
    case "$line" in
      "HIGH: $EF_REL"*"test language $2 does not match code language $3 of $4 (new file shape: "*") code=TEST_LANGUAGE_MISMATCH") found=1 ;;
    esac
  done <<< "$LM_OUT"
  if [ "$found" = 1 ]; then pass "$1: mismatch on $4"; else fail "$1" "no $2/$3 mismatch line for $4: out=[$LM_OUT] err=[$LM_ERR]"; fi
}

# ef_added_other / ef_added_same / ef_retarget <test-language> — the three existing-file shapes.
ef_added_other() {
  ef_row "$1" || return 0
  mbody "ef-$1-ao-head" "$1" "$EF_S1, $EF_S2" a="$EF_S1"
  mbody "ef-$1-ao-work" "$1" "$EF_S1, $EF_S2" a="$EF_S1" b="$EF_OTHER"
  lm "$EF_REL" "ef-$1-ao-work" "ef-$1-ao-head"
  expect_lang_mismatch "$1: new case b targets $EF_OTHER" "$1" "$EF_OL" "$EF_OTHER"
}
ef_added_same() {
  ef_row "$1" || return 0
  mbody "ef-$1-as-head" "$1" "$EF_S1, $EF_S2" a="$EF_S1"
  mbody "ef-$1-as-work" "$1" "$EF_S1, $EF_S2" a="$EF_S1" b="$EF_S2"
  lm "$EF_REL" "ef-$1-as-work" "ef-$1-as-head"
  expect_clean "$1: new case b targets $EF_S2"
}
ef_retarget() {
  ef_row "$1" || return 0
  mbody "ef-$1-rt-head" "$1" "$EF_S1, $EF_S2" a="$EF_S1" b="$EF_S2"
  mbody "ef-$1-rt-work" "$1" "$EF_S1, $EF_S2" a="$EF_S1" b="$EF_OTHER"
  lm "$EF_REL" "ef-$1-rt-work" "ef-$1-rt-head"
  expect_lang_mismatch "$1: case b moved from $EF_S2 to $EF_OTHER" "$1" "$EF_OL" "$EF_OTHER"
}

case_begin "ef-pester-added-case-on-other-language-blocks" "bin/check-test-language-match.sh"
ef_added_other pester
case_end

case_begin "ef-pester-added-case-on-same-language-passes" "bin/check-test-language-match.sh"
ef_added_same pester
case_end

case_begin "ef-pester-case-retargeted-to-other-language-blocks" "bin/check-test-language-match.sh"
ef_retarget pester
case_end

case_begin "ef-pytest-added-case-on-other-language-blocks" "bin/check-test-language-match.sh"
ef_added_other pytest
case_end

case_begin "ef-pytest-added-case-on-same-language-passes" "bin/check-test-language-match.sh"
ef_added_same pytest
case_end

case_begin "ef-pytest-case-retargeted-to-other-language-blocks" "bin/check-test-language-match.sh"
ef_retarget pytest
case_end

case_begin "ef-js-added-case-on-other-language-blocks" "bin/check-test-language-match.sh"
ef_added_other js
case_end

case_begin "ef-js-added-case-on-same-language-passes" "bin/check-test-language-match.sh"
ef_added_same js
case_end

case_begin "ef-js-case-retargeted-to-other-language-blocks" "bin/check-test-language-match.sh"
ef_retarget js
case_end
