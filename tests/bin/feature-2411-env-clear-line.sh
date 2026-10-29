#!/usr/bin/env bash
# tests/bin/feature-2411-env-clear-line.sh
# Tests: bin/lib/test-language-parts/bash.sh, bin/lib/test-language-parts/js.sh, bin/lib/test-language-parts/pester.sh, bin/lib/test-language-parts/pytest.sh, hooks/lib/test-language-registry.json, hooks/lib/test-language-registry.js
# Tags: TL1, bin, test-language-registry, session-id, tombstone, table-driven, scope:issue-specific, pwsh-not-required
# #2507 moved the envClearLine parts to Node: their row tables live in tests/bin/feature-2507-env-clear-line.js,
# so this file keeps the registry route through the bash loader and the tableDrivenDetector parts.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

# The registry route: the shell dump of every supported entry names its Node envClearLine part,
# and the recognized-only entry has none.
# reg_route <root> — a subshell, so the loader's state stays out of this shell.
reg_route() (
  . "$1/bin/lib/test-language-registry.sh" || exit 97
  tlr_load || exit 96
  local id
  for id in $(tlr_ids supported); do
    printf 'supported %s file=%s fn=%s\n' "$id" "$(tlr_field "$id" envClearLine.file)" "$(tlr_field "$id" envClearLine.function)"
  done
  for id in $(tlr_ids recognized-only); do
    printf 'recognized %s fn=%s\n' "$id" "$(tlr_field "$id" envClearLine.function)"
  done
)
REG_OUT="$(reg_route "$SCRIPT_CHECKOUT_ROOT" 2>"$TMPBASE/reg.err")"

case_begin "registry-routes-each-supported-entry-to-its-part" "hooks/lib/test-language-registry.json"
for reg_id in bash js pester pytest; do
  assert_eq "supported $reg_id: $(printf '%s\n' "$REG_OUT" | grep "^supported $reg_id ")" \
    "supported $reg_id: supported $reg_id file=hooks/lib/test-gates/parts/env-clear/$reg_id.js fn=envClearLine"
done
reg_recognized=0
while IFS= read -r reg_line; do
  if [[ "$reg_line" == "supported "* ]] && [[ "$reg_line" == *" file= "* || "$reg_line" == *" fn=" ]]; then
    fail "supported entry without envClearLine" "$reg_line"
  elif [[ "$reg_line" == "recognized "* && "$reg_line" == *" fn=" ]]; then
    reg_recognized=$((reg_recognized + 1))
    pass "recognized-only has no envClearLine: $reg_line"
  elif [[ "$reg_line" == "recognized "* ]]; then
    fail "recognized-only envClearLine" "$reg_line"
  fi
done <<<"$REG_OUT"
[[ "$reg_recognized" -gt 0 ]] || fail "recognized-only entries" "none listed by the loader: [$REG_OUT]"
case_end

# #2502 S5-5: tableDrivenDetector for pester (-ForEach / -TestCases on It) and pytest
# (@pytest.mark.parametrize), reached through the real registry like has_table_driven_js.
# td_route <id> <file>... — prints "fn=<function> rc=<rc per file...>"; rc 70 = no part.
td_route() {
  run_with_timeout 60 bash -c '. "$1/bin/lib/test-language-registry.sh" || exit 97
tlr_load || exit 96
id="$2"; shift 2; out=""
for f in "$@"; do tlr_call_part "$id" tableDrivenDetector "$f" >/dev/null 2>&1; out="$out $?"; done
printf "fn=%s rc=%s" "$(tlr_field "$id" tableDrivenDetector.function 2>/dev/null)" "${out# }"' _ "$SCRIPT_CHECKOUT_ROOT" "$@" 2>"$TMPBASE/td.err"
}
TD="$TMPBASE/td"
mkdir -p "$TD"
printf '%s\n' "Describe 'a' {" "    It 'adds <n>' -ForEach @(@{ n = 1 }, @{ n = 2 }) { \$n | Should -BeGreaterThan 0 }" "}" >"$TD/foreach.Tests.ps1"
printf '%s\n' "Describe 'a' {" "    It 'adds <n>' -TestCases @(@{ n = 1 }) { \$n | Should -Be 1 }" "}" >"$TD/testcases.Tests.ps1"
printf '%s\n' "Describe 'a' {" "    It 'plain' { 1..3 | ForEach-Object { \$_ | Should -BeGreaterThan 0 } }" "}" >"$TD/plain.Tests.ps1"
printf '%s\n' "import pytest" "" "" '@pytest.mark.parametrize("n", [1, 2])' "def test_n(n):" "    assert n > 0" >"$TD/test_param.py"
printf '%s\n' "import pytest" "" "" "def test_loop():" "    for n in [1, 2]:" "        assert n > 0" >"$TD/test_plain.py"

case_begin "pester-table-driven-detector" "bin/lib/test-language-parts/pester.sh"
# Positive: -ForEach and -TestCases on It; negative: a ForEach-Object pipeline in a plain It.
assert_eq "pester $(td_route pester "$TD/foreach.Tests.ps1" "$TD/testcases.Tests.ps1" "$TD/plain.Tests.ps1")" \
  "pester fn=has_table_driven_pester rc=0 0 1"
case_end

case_begin "pytest-table-driven-detector" "bin/lib/test-language-parts/pytest.sh"
# Positive: @pytest.mark.parametrize; negative: a for loop inside a plain test.
assert_eq "pytest $(td_route pytest "$TD/test_param.py" "$TD/test_plain.py")" \
  "pytest fn=has_table_driven_pytest rc=0 1"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
