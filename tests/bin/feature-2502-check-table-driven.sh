#!/usr/bin/env bash
# tests/bin/feature-2502-check-table-driven.sh
# Tests: bin/check-table-driven.sh, bin/lib/test-language-parts/pester.sh, bin/lib/test-language-parts/pytest.sh
# Tags: TL2, bin, table-driven, test-language-registry, sweep-tests, pester, pytest, scope:issue-specific
# #2502 S5-5: the duplicate detection sweep runs through bin/check-table-driven.sh on a Pester
# and a pytest test whose # Tests: names a parser target. Copy-pasted cases (no table) are
# reported as MISSING table-driven; a -ForEach / -TestCases or @pytest.mark.parametrize table
# is not. The verdict comes from the file's own entry detector, never the bash fallback, so a
# bash `while IFS='|' read -r` line inside a Pester or pytest file does not count as a table.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

FX="$TMPBASE/tests/bin"
mkdir -p "$FX"
# The fixtures' header words, split so this file has a single header of its own.
FX_TESTS='# ''Tests: hooks/lib/command-parser.js'
FX_TAGS='# ''Tags: TL1, scope:issue-specific'
BASH_TABLE_LINE="while IFS='|' read -r name want; do :; done"

printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" \
  "    It 'parses a' { 'a' | Should -Be 'a' }" \
  "    It 'parses b' { 'b' | Should -Be 'b' }" \
  "    It 'parses c' { 'c' | Should -Be 'c' }" "}" >"$FX/feature-9999-dup.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" \
  "    It 'parses <v>' -ForEach @(@{ v = 'a' }, @{ v = 'b' }, @{ v = 'c' }) { \$v | Should -Be \$v }" "}" >"$FX/feature-9999-foreach.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" \
  "    It 'parses <v>' -TestCases @(@{ v = 'a' }, @{ v = 'b' }) { \$v | Should -Be \$v }" "}" >"$FX/feature-9999-testcases.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" \
  "    It 'parses a' { \"$BASH_TABLE_LINE\" | Should -Not -BeNullOrEmpty }" \
  "    It 'parses b' { 'b' | Should -Be 'b' }" "}" >"$FX/feature-9999-bashline.Tests.ps1"

printf '%s\n' "$FX_TESTS" "$FX_TAGS" "" "def test_parse_a():" "    assert 'a' == 'a'" "" "" \
  "def test_parse_b():" "    assert 'b' == 'b'" "" "" "def test_parse_c():" "    assert 'c' == 'c'" >"$FX/test_feature-9999-dup.py"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "import pytest" "" "" '@pytest.mark.parametrize("v", ["a", "b", "c"])' \
  "def test_parse(v):" "    assert v == v" >"$FX/test_feature-9999-param.py"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "" "def test_parse_a():" "    assert \"$BASH_TABLE_LINE\"" "" "" \
  "def test_parse_b():" "    assert 'b' == 'b'" >"$FX/test_feature-9999-bashline.py"
# Inactive tables: the -ForEach It line and the parametrize decorator are commented out.
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" \
  "    # It 'parses <v>' -ForEach @(@{ v = 'a' }, @{ v = 'b' }) { \$v | Should -Be \$v }" \
  "    It 'parses a' { 'a' | Should -Be 'a' }" \
  "    It 'parses b' { 'b' | Should -Be 'b' }" "}" >"$FX/feature-9999-commented.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "import pytest" "" "" '# @pytest.mark.parametrize("v", ["a", "b", "c"])' \
  "def test_parse(v='a'):" "    assert v == v" >"$FX/test_feature-9999-commented.py"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "from pytest import mark" "" "" '@mark.parametrize("v", ["a", "b", "c"])' \
  "def test_parse(v):" "    assert v == v" >"$FX/test_feature-9999-mark.py"
# Text that only looks like a table to a line scan (#2735): inside a Python triple-quoted string, a
# PowerShell block comment, a PowerShell here-string; and the lower-case spelling of a real table.
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "import pytest" "" "DOC = '''" '@pytest.mark.parametrize("v", ["a", "b", "c"])' "'''" "" "" \
  "def test_parse():" "    assert DOC" >"$FX/test_feature-9999-triple.py"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "<#" "    It 'parses <v>' -ForEach @(@{ v = 'a' }, @{ v = 'b' }) { \$v | Should -Be \$v }" "#>" \
  "Describe 'parse' {" "    It 'parses a' { 'a' | Should -Be 'a' }" "    It 'parses b' { 'b' | Should -Be 'b' }" "}" >"$FX/feature-9999-blockcomment.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "\$doc = @'" "    It 'parses <v>' -ForEach @(@{ v = 'a' }, @{ v = 'b' }) { \$v | Should -Be \$v }" "'@" \
  "Describe 'parse' {" "    It 'parses a' { 'a' | Should -Be 'a' }" "    It 'parses b' { 'b' | Should -Be 'b' }" "}" >"$FX/feature-9999-herestring.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" \
  "    It 'parses <v>' -testcases @(@{ v = 'a' }, @{ v = 'b' }) { \$v | Should -Be \$v }" "}" >"$FX/feature-9999-lowercase.Tests.ps1"
# Files that do not parse: the verdict cannot be given.
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "Describe 'parse' {" "    It 'parses a' { 'a' | Should -Be 'a'" >"$FX/feature-9999-broken.Tests.ps1"
printf '%s\n' "$FX_TESTS" "$FX_TAGS" "def test_parse(:" "    assert True" >"$FX/test_feature-9999-broken.py"

# ctd <fixture-basename> — "rc=<rc> out=<stdout with the fixture dir stripped>".
ctd() {
  local out rc=0
  out="$(run_with_timeout 60 bash "$SCRIPT_CHECKOUT_ROOT/bin/check-table-driven.sh" "$FX/$1" 2>"$TMPBASE/ctd.err" </dev/null)" || rc=$?
  out="${out//"$FX/"/}"
  printf 'rc=%s out=%s' "$rc" "$out"
}

MISSING_SUFFIX="(required: # Tests: points to parser target)"

# need_runtime <fixture basename> — the detector answers through pwsh (*.ps1) or uv (*.py); rc 1 and a SKIP
# when the host lacks it, never a pass made without it.
need_runtime() {
  local tool=uv
  [[ "$1" == *.ps1 ]] && tool=pwsh
  command -v "$tool" >/dev/null 2>&1 && return 0
  skip "$1: $tool is not on PATH"
  return 1
}

# ctd_table — reads rows `name | fixture basename | want` from stdin; want is `reported`
# (rc 1 and the MISSING line) or `clean` (rc 0, no output).
ctd_table() {
  local name fixture want expect
  while IFS='|' read -r name fixture want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    fixture="${fixture//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    need_runtime "$fixture" || continue
    if [[ "$want" == reported ]]; then
      expect="rc=1 out=MISSING table-driven in $fixture $MISSING_SUFFIX"
    elif [[ "$want" == clean ]]; then
      expect="rc=0 out="
    else
      fail "$name: table row want" "unknown want '$want'"
      continue
    fi
    assert_eq "$name: $(ctd "$fixture")" "$name: $expect"
  done
}

case_begin "pester-duplicate-cases-reported" "bin/check-table-driven.sh"
ctd_table <<'TABLE'
# Three copy-pasted It blocks and no table.
pester-dup | feature-9999-dup.Tests.ps1 | reported
TABLE
case_end

case_begin "pester-table-not-reported" "bin/lib/test-language-parts/pester.sh"
ctd_table <<'TABLE'
pester-foreach   | feature-9999-foreach.Tests.ps1   | clean
pester-testcases | feature-9999-testcases.Tests.ps1 | clean
TABLE
case_end

case_begin "pester-bash-table-line-not-a-table" "bin/lib/test-language-parts/pester.sh"
ctd_table <<'TABLE'
# The bash fallback pattern inside a Pester file is not a Pester table.
pester-bashline | feature-9999-bashline.Tests.ps1 | reported
TABLE
case_end

case_begin "pester-commented-table-inactive" "bin/lib/test-language-parts/pester.sh"
ctd_table <<'TABLE'
# A commented-out `It ... -ForEach` line is not an active table.
pester-commented | feature-9999-commented.Tests.ps1 | reported
TABLE
case_end

case_begin "pytest-duplicate-cases-reported" "bin/check-table-driven.sh"
ctd_table <<'TABLE'
# Three copy-pasted test functions and no parametrize.
pytest-dup | test_feature-9999-dup.py | reported
TABLE
case_end

case_begin "pytest-parametrize-not-reported" "bin/lib/test-language-parts/pytest.sh"
ctd_table <<'TABLE'
pytest-param | test_feature-9999-param.py | clean
pytest-mark  | test_feature-9999-mark.py  | clean
TABLE
case_end

case_begin "pytest-bash-table-line-not-a-table" "bin/lib/test-language-parts/pytest.sh"
ctd_table <<'TABLE'
# The bash fallback pattern inside a pytest file is not a parametrize table.
pytest-bashline | test_feature-9999-bashline.py | reported
TABLE
case_end

case_begin "pytest-commented-decorator-inactive" "bin/lib/test-language-parts/pytest.sh"
ctd_table <<'TABLE'
# A commented-out `@pytest.mark.parametrize` decorator is not an active table.
pytest-commented | test_feature-9999-commented.py | reported
TABLE
case_end

# #2735: the verdict is the syntax tree's, not a line scan's.
case_begin "pytest-decorator-text-in-triple-quotes-not-a-table" "bin/lib/test-language-parts/pytest.sh"
ctd_table <<'TABLE'
# A parametrize decorator line that only sits inside a triple-quoted string is not a table.
pytest-triple-quoted | test_feature-9999-triple.py | reported
# Control: the real decorator is still a table.
pytest-real-decorator | test_feature-9999-param.py | clean
TABLE
case_end

case_begin "pester-text-in-comment-or-here-string-not-a-table" "bin/lib/test-language-parts/pester.sh"
ctd_table <<'TABLE'
# An It -ForEach text inside a block comment or a here-string is not a table.
pester-block-comment | feature-9999-blockcomment.Tests.ps1 | reported
pester-here-string   | feature-9999-herestring.Tests.ps1   | reported
# The parameter name is case-insensitive in PowerShell, so a lower-case -testcases is a table.
pester-lowercase     | feature-9999-lowercase.Tests.ps1     | clean
TABLE
case_end

# ctd_error <fixture basename> <needle> [<PATH to run with>] — rc 2 and the needle on stderr.
ctd_error() {
  local rc=0 err
  if [[ $# -ge 3 ]]; then
    (PATH="$3"; bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 bash "$SCRIPT_CHECKOUT_ROOT/bin/check-table-driven.sh" "$FX/$1" >/dev/null 2>"$TMPBASE/ctd.err" </dev/null) || rc=$?
  else
    run_with_timeout 60 bash "$SCRIPT_CHECKOUT_ROOT/bin/check-table-driven.sh" "$FX/$1" >/dev/null 2>"$TMPBASE/ctd.err" </dev/null || rc=$?
  fi
  err="$(<"$TMPBASE/ctd.err")"
  assert_eq "$1: rc=$rc" "$1: rc=2"
  if [[ "$err" == *"$2"* ]]; then pass "$1: stderr has [$2]"; else fail "$1: stderr has [$2]" "$err"; fi
}

case_begin "unparsable-test-file-cannot-be-checked" "bin/check-table-driven.sh"
# A file the runtime cannot parse gives no verdict: exit 2, never a guessed 0 / 1.
for f in feature-9999-broken.Tests.ps1 test_feature-9999-broken.py; do
  need_runtime "$f" && ctd_error "$f" "cannot check"
done
case_end

case_begin "missing-runtime-detector-unavailable" "bin/check-table-driven.sh"
# PATH without uv and pwsh: the detector is unavailable, so exit 2 and say so.
# shellcheck source=../lib/tool-shim-path.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/tool-shim-path.sh"
NO_RT_PATH="$(tsp_base_path "$TMPBASE/shim-no-runtime" uv pwsh 2>"$TMPBASE/shim-no-runtime.err")" || NO_RT_PATH=""
if [[ -z "$NO_RT_PATH" ]]; then
  skip "no uv / pwsh-free PATH could be built: $(<"$TMPBASE/shim-no-runtime.err")"
else
  ctd_error feature-9999-dup.Tests.ps1 "detector is unavailable" "$NO_RT_PATH"
  ctd_error test_feature-9999-dup.py "detector is unavailable" "$NO_RT_PATH"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
