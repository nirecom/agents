# New files in every registered language (#2502 S4-3): a pester, pytest, js or bash test on code
# of its own language passes silently, on code of another language it is a mismatch. Code files
# cover each registered sourcePattern (.ps1/.psm1, .py, .js/.cjs/.mjs, .sh) and extensionless
# tools whose shebang interpreter alone names the language. Sourced by
# tests/bin/feature-2502-test-language-match.sh.
# shellcheck shell=bash

# Repeats _lib.sh's pin so the static isolation gate sees it in this file.
harness_isolate "$TMPBASE/iso"

echo ""
echo "=== new file, every language ==="

for _f in bin/m.ps1 bin/m.psm1 bin/m.py bin/m.cjs bin/m.mjs; do printf '\n' > "$REPO/$_f"; done
printf '%s\n' '#!/usr/bin/env node' 'console.log(1);' > "$REPO/bin/tool-node"
printf '%s\n' '#!/usr/bin/env pwsh' 'Write-Output 1' > "$REPO/bin/tool-pwsh"
printf '%s\n' '#!/usr/bin/env python3' 'print(1)' > "$REPO/bin/tool-py"
printf '%s\n' '#!/usr/bin/env bash' 'echo 1' > "$REPO/bin/tool-sh"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m languages >/dev/null 2>&1

# lbody <name> <test-language> <target> — a one-target body in that language with one case
# marked on <target>, so the file is conforming and only the language match decides (a file
# without markers also meets the S4-4b case-addition judgment).
LJB="case""Begin"  # split so this file's own reader never takes the fixture lines for markers
LJE="case""End"
lbody() {
  local out="$BODIES/$1"
  case "$2" in
    pester) printf '%s\n' "# Tests: $3" '# Tags: scope:common' "Describe 'a' -Tag 'target:$3' {" "    It 'runs' { 1 | Should -Be 1 }" '}' > "$out" ;;
    pytest) printf '%s\n' "# Tests: $3" '# Tags: scope:common' 'import pytest' '' '' "@pytest.mark.target(\"$3\")" 'def test_a():' '    assert True' > "$out" ;;
    js) printf '%s\n' '"use strict";' "// Tests: $3" '// Tags: scope:common' 'const { test } = require("node:test");' \
      "const { $LJB, $LJE } = require(\"../lib/harness\");" "$LJB(\"a\", \"$3\");" 'test("a", () => {});' "$LJE();" > "$out" ;;
    bash) printf '%s\n' '#!/usr/bin/env bash' "# Tests: $3" '# Tags: scope:common' 'source "$(dirname "$0")/../../tests/lib/harness.sh"' \
      "$MB \"a\" \"$3\"" 'echo a' "$ME" > "$out" ;;
  esac
}

# lang_rows <test-language> <rel> — every row of $LANG_ROWS for that test language. A row is
# "<test-language> <target> <code-language|same>"; same = passes silently, otherwise exactly one
# TEST_LANGUAGE_MISMATCH line naming both languages and the target.
lang_rows() {
  local tl cl tgt line found n=0
  while read -r tl tgt cl; do
    [ "$tl" = "$1" ] || continue
    n=$((n + 1))
    lbody "lang-$tl-$n" "$tl" "$tgt"
    lm "$2" "lang-$tl-$n"
    if [ "$cl" = same ]; then
      expect_clean "$tl test on $tgt"
      continue
    fi
    expect_rc "$tl test on $tgt ($cl)" 1
    assert_eq "$tl test on $tgt: mismatch lines=$(count_code TEST_LANGUAGE_MISMATCH)" "$tl test on $tgt: mismatch lines=1"
    found=0
    while IFS= read -r line; do
      case "$line" in
        "HIGH: $2"*"test language $tl does not match code language $cl of $tgt (new file shape: "*") code=TEST_LANGUAGE_MISMATCH") found=1 ;;
      esac
    done <<< "$LM_OUT"
    if [ "$found" = 1 ]; then pass "$tl test on $tgt: names $cl"; else fail "$tl test on $tgt" "no $tl/$cl mismatch line: out=[$LM_OUT] err=[$LM_ERR]"; fi
  done <<< "$LANG_ROWS"
  [ "$n" -gt 0 ] || fail "$1 rows" "no row for $1"
}

LANG_ROWS='pester bin/m.ps1 same
pester bin/m.psm1 same
pester bin/tool-pwsh same
pester bin/m.cjs js
pester bin/tool-sh bash
pytest bin/m.py same
pytest bin/tool-py same
pytest bin/m.mjs js
pytest bin/tool-pwsh pester
js bin/m.cjs same
js bin/m.mjs same
js bin/tool-node same
js bin/m.py pytest
js bin/tool-pwsh pester
bash bin/tool-sh same
bash bin/tool-node js
bash bin/m.psm1 pester
bash bin/tool-py pytest'

case_begin "nf-pester-test-language-rows" "bin/check-test-language-match.sh"
lang_rows pester tests/bin/l1.Tests.ps1
case_end

case_begin "nf-pytest-test-language-rows" "bin/check-test-language-match.sh"
lang_rows pytest tests/bin/test_l2.py
case_end

case_begin "nf-js-test-language-rows" "bin/check-test-language-match.sh"
lang_rows js tests/bin/l3.js
case_end

case_begin "nf-bash-test-on-other-languages" "bin/check-test-language-match.sh"
lang_rows bash tests/bin/l4.sh
case_end
