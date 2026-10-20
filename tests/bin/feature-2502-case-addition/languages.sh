# pester, pytest and js tests without markers (#2502 S4-4b): case-count runs for real (pester's
# top-level Describe, pytest's module-level test_* / Test*), and code lines take over where it
# cannot count (js without caseBegin, a pytest syntax error, the stub's pester rc 69).
# Sourced by tests/bin/feature-2502-case-addition.sh.
# shellcheck shell=bash
# shellcheck disable=SC2016 # fixture lines hold literal $PSScriptRoot text on purpose

echo ""
echo "=== case addition: pester, pytest, js ==="

# --- pester: tests/bin/foo.Tests.ps1, two top-level Describe blocks, 7 code lines ------------
P_H=('# Tests: bin/m.ps1' '# Tags: scope:common' 'BeforeAll { function Invoke-Tool { & pwsh -File "$PSScriptRoot/../../bin/m.ps1" } }')
P_D1=("Describe 'one' {" "    It 'runs' { 1 | Should -Be 1 }" '}')
P_D2=("Describe 'two' {" "    It 'runs' { 2 | Should -Be 2 }" '}')
P_D3=("Describe 'three' {" "    It 'calls' { Invoke-Tool }" '}')
raw ca-p-head "${P_H[@]}" "${P_D1[@]}" "${P_D2[@]}"

case_begin "ca-pester-top-level-describe-units" "bin/lib/test-language-match/case-addition.sh"
if command -v pwsh >/dev/null 2>&1; then
  raw ca-p-add "${P_H[@]}" "${P_D1[@]}" "${P_D2[@]}" "${P_D3[@]}"
  lm tests/bin/foo.Tests.ps1 ca-p-add ca-p-head
  expect_added "pester, Describe three added" tests/bin/foo.Tests.ps1 pester "case units 2 -> 3"
  raw ca-p-it "${P_H[@]}" "Describe 'one' {" "    It 'runs' { 1 | Should -Be 1 }" "    It 'calls' { Invoke-Tool }" '}' "${P_D2[@]}"
  lm tests/bin/foo.Tests.ps1 ca-p-it ca-p-head
  expect_clean "pester, It added inside Describe one"
  raw ca-p-del "${P_H[@]}" "${P_D1[@]}"
  lm tests/bin/foo.Tests.ps1 ca-p-del ca-p-head
  expect_clean "pester, Describe two deleted"
else
  skip "pester case units" "pwsh not available"
fi
case_end

case_begin "ca-pester-no-runtime-falls-back-to-code-lines" "bin/lib/test-language-match/case-addition.sh"
# The stub checkout answers rc 69 for both versions (the `# no-runtime` line is a comment).
LM_CLI="$STUB_CLI"
raw ca-p69-head "${P_H[@]}" '# no-runtime' "${P_D1[@]}" "${P_D2[@]}"
raw ca-p69-add "${P_H[@]}" '# no-runtime' "${P_D1[@]}" "${P_D2[@]}" "${P_D3[@]}"
lm tests/bin/foo.Tests.ps1 ca-p69-add ca-p69-head
expect_added "pester rc 69, Describe three added" tests/bin/foo.Tests.ps1 pester "case count unavailable: *; code lines 7 -> 10"
raw ca-p69-value "${P_H[@]}" '# no-runtime' "${P_D1[@]}" "Describe 'two' {" "    It 'runs' { 2 | Should -Be 3 }" '}'
lm tests/bin/foo.Tests.ps1 ca-p69-value ca-p69-head
expect_clean "pester rc 69, a value rewritten"
LM_CLI="$LM_CLI_REAL"
case_end

# --- pytest: tests/bin/test_foo.py, test_one and class TestGroup (2 units), 8 code lines -----
Y_H=('# Tests: bin/m.py' '# Tags: scope:common' 'import subprocess' '' '' 'def run_tool():' \
  '    return subprocess.run(["python", "bin/m.py"], check=False)' '' '')
Y_ONE=('def test_one():' '    assert 1 == 1' '' '')
Y_CLS=('class TestGroup:' '    def test_a(self):' '        assert True')
raw ca-y-head "${Y_H[@]}" "${Y_ONE[@]}" "${Y_CLS[@]}"

case_begin "ca-pytest-module-level-units" "bin/lib/test-language-match/case-addition.sh"
if command -v uv >/dev/null 2>&1; then
  raw ca-y-add "${Y_H[@]}" "${Y_ONE[@]}" "${Y_CLS[@]}" '' '' 'def test_three():' '    run_tool()'
  lm tests/bin/test_foo.py ca-y-add ca-y-head
  expect_added "pytest, test_three added" tests/bin/test_foo.py pytest "case units 2 -> 3"
  raw ca-y-method "${Y_H[@]}" "${Y_ONE[@]}" "${Y_CLS[@]}" '' '    def test_b(self):' '        run_tool()'
  lm tests/bin/test_foo.py ca-y-method ca-y-head
  expect_clean "pytest, method added to TestGroup"
  raw ca-y-line "${Y_H[@]}" 'def test_one():' '    assert 1 == 1' '    assert 2 == 2' '' '' "${Y_CLS[@]}"
  lm tests/bin/test_foo.py ca-y-line ca-y-head
  expect_clean "pytest, a line added inside test_one"
  # The working version does not parse (rc 1), so both versions fall back to code lines.
  raw ca-y-syntax "${Y_H[@]}" "${Y_ONE[@]}" "${Y_CLS[@]}" '' '' 'def test_bad(:' '    pass'
  lm tests/bin/test_foo.py ca-y-syntax ca-y-head
  expect_added "pytest, syntax error with more lines" tests/bin/test_foo.py pytest "case count unavailable: *; code lines 8 -> 10"
else
  skip "pytest case units" "uv not available"
fi
case_end

# --- js: tests/bin/foo.js, check() calls without caseBegin (no unit), 5 code lines -----------
J_H=('"use strict";' '// Tests: hooks/x.js' '// Tags: scope:common' 'const assert = require("node:assert");' \
  'function check(name, fn) { fn(); }')
J_1=('check("one", () => { assert.equal(1, 1); });')
J_2=('check("two", () => { assert.equal(2, 2); });')
raw ca-j-head "${J_H[@]}" "${J_1[@]}" "${J_2[@]}"

case_begin "ca-js-without-markers-uses-code-lines" "bin/lib/test-language-match/case-addition.sh"
raw ca-j-add "${J_H[@]}" "${J_1[@]}" "${J_2[@]}" 'check("three", () => { require("../../hooks/x.js"); });'
lm tests/bin/foo.js ca-j-add ca-j-head
expect_added "js, check three added" tests/bin/foo.js js "case count unavailable: no case unit; code lines 5 -> 6"
raw ca-j-value "${J_H[@]}" 'check("one", () => { assert.equal(1, 2); });' "${J_2[@]}"
lm tests/bin/foo.js ca-j-value ca-j-head
expect_clean "js, a value rewritten"
raw ca-j-comment "${J_H[@]}" "${J_1[@]}" '// a note on check two' "${J_2[@]}"
lm tests/bin/foo.js ca-j-comment ca-j-head
expect_clean "js, a comment line added"
case_end
