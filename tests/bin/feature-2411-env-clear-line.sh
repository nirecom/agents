#!/usr/bin/env bash
# tests/bin/feature-2411-env-clear-line.sh
# Tests: bin/lib/test-language-parts/bash.sh, bin/lib/test-language-parts/js.sh, bin/lib/test-language-parts/pester.sh, bin/lib/test-language-parts/pytest.sh, hooks/lib/test-language-registry.json, hooks/lib/test-language-registry.js
# Tags: TL1, bin, test-language-registry, session-id, tombstone, table-driven, scope:issue-specific, pwsh-not-required
# <lang>_env_clear_line <names-ERE> <line>: rc 0 when the line only clears env vars named by the
# ERE, rc 1 otherwise, nothing on stdout. Rows spell the retired names @S@ / @E@ (this file is not
# tombstone-exempt), a pipe @P@ and a trailing carriage return @CR@.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

RET_S="CLAUDE_""SESSION_ID"
RET_E="CLAUDE_""ENV_FILE"
GUARDED_ERE="$RET_S|$RET_E"
PARTS="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-parts"
RUNNER="$TMPBASE/run-part.sh"

# The runner sources one part file and calls one function; rc 96 = the function is not defined.
cat >"$RUNNER" <<'RUN'
part="$1"; fn="$2"; ere="$3"; line="$4"
. "$part" >/dev/null 2>&1 || { echo "rc=97 out=0"; exit 0; }
declare -F "$fn" >/dev/null || { echo "rc=96 out=0"; exit 0; }
"$fn" "$ere" "$line" >"${BASH_SOURCE[0]}.stdout" 2>/dev/null
rc=$?
echo "rc=$rc out=$(wc -c <"${BASH_SOURCE[0]}.stdout" | tr -d ' ')"
RUN

# expand <row-line> — the placeholders filled in.
expand() {
  local l="$1"
  l="${l//@S@/$RET_S}"
  l="${l//@E@/$RET_E}"
  l="${l//@P@/|}"
  l="${l//@CR@/$'\r'}"
  printf '%s' "$l"
}

# name | language | ERE (G = the retired names, O = OTHER_VAR) | want rc | the line
ROWS="$TMPBASE/rows.txt"
cat >"$ROWS" <<'TABLE'
# bash: whole-line unset, or every guarded name an operand of -u
sh-unset-one              | bash   | G | 0 | unset @S@
sh-unset-two              | bash   | G | 0 | unset @S@ @E@
sh-unset-among-others     | bash   | G | 0 | unset FOO @E@ BAR
sh-unset-quiet            | bash   | G | 0 |   unset @S@ @E@ 2>/dev/null @P@@P@ true
sh-env-dash-u-both        | bash   | G | 0 | env -u @E@ -u @S@ cmd
sh-env-dash-u-run         | bash   | G | 0 | env -u @E@ bash x.sh
sh-array-dash-u           | bash   | G | 0 | DENV=(env -u WORKFLOW_STATE_DIR -u @S@
sh-no-guarded-name        | bash   | G | 0 | echo hello
sh-suffix-name-only       | bash   | G | 0 | env -u @E@_X printenv
sh-export                 | bash   | G | 1 | export @E@=x
sh-assign                 | bash   | G | 1 | @E@=/tmp/x
sh-read                   | bash   | G | 1 | echo "$@S@"
sh-comment                | bash   | G | 1 | # @E@ is cleared above
sh-unset-then-use         | bash   | G | 1 | unset @S@ && echo "$@E@"
sh-dash-u-plus-bare-other | bash   | G | 1 | echo "$@S@" -u @E@
sh-dash-u-plus-bare-same  | bash   | G | 1 | env -u @S@ printenv @S@
sh-js-delete              | bash   | G | 1 | delete process.env.@S@;
sh-py-pop                 | bash   | G | 1 | os.environ.pop("@S@", None)
sh-ps-remove              | bash   | G | 1 | Remove-Item -Path Env:@E@ -ErrorAction SilentlyContinue
sh-ere-other-export       | bash   | O | 1 | export OTHER_VAR=1
sh-ere-other-unset        | bash   | O | 0 | unset OTHER_VAR
# js: delete process.env.NAME; alone on the line
js-delete-sid             | js     | G | 0 | delete process.env.@S@;
js-delete-no-semicolon    | js     | G | 0 | delete process.env.@E@
js-indented-space-semi    | js     | G | 0 |     delete process.env.@S@ ;
js-crlf                   | js     | G | 0 | delete process.env.@E@;@CR@
js-other-var              | js     | G | 1 | delete process.env.OTHER_VAR;
js-suffix-name            | js     | G | 1 | delete process.env.@E@_X;
js-prefix-name            | js     | G | 1 | delete process.env.X_@S@;
js-assign                 | js     | G | 1 | process.env.@S@ = "x";
js-read-assert            | js     | G | 1 | assert.strictEqual(process.env.@E@, undefined);
js-list-literal           | js     | G | 1 | const R = ["@S@", "@E@"];
js-bracket-delete         | js     | G | 1 | delete process.env["@S@"];
js-trailing-comment       | js     | G | 1 | delete process.env.@S@; // clear
js-two-on-one-line        | js     | G | 1 | delete process.env.@S@; delete process.env.@E@;
js-bash-unset             | js     | G | 1 | unset @S@
js-py-pop                 | js     | G | 1 | os.environ.pop("@S@", None)
js-ere-other-cleared      | js     | O | 0 | delete process.env.OTHER_VAR;
js-ere-other-guarded      | js     | O | 1 | delete process.env.@S@;
# pester: Remove-Item [-Path] Env:[\]NAME, then -ErrorAction SilentlyContinue and/or -Force
ps-path-form              | pester | G | 0 | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-bare-form              | pester | G | 0 | Remove-Item Env:@E@
ps-backslash-force        | pester | G | 0 | Remove-Item Env:\@S@ -Force
ps-both-switches          | pester | G | 0 | Remove-Item -Path Env:@E@ -ErrorAction SilentlyContinue -Force
ps-switches-reversed      | pester | G | 0 | Remove-Item Env:@E@ -Force -ErrorAction SilentlyContinue
ps-indented               | pester | G | 0 |         Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-crlf                   | pester | G | 0 | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue@CR@
ps-other-var              | pester | G | 1 | Remove-Item Env:OTHER_VAR -Force
ps-suffix-name            | pester | G | 1 | Remove-Item Env:@E@_X
ps-other-switch           | pester | G | 1 | Remove-Item Env:@S@ -Recurse
ps-assign                 | pester | G | 1 | $env:@S@ = 'x'
ps-read-assert            | pester | G | 1 | $env:@E@ @P@ Should -BeNullOrEmpty
ps-list-literal           | pester | G | 1 | $names = @('@S@', '@E@')
ps-trailing-comment       | pester | G | 1 | Remove-Item Env:@S@ -Force # clear
ps-two-on-one-line        | pester | G | 1 | Remove-Item Env:@S@; Remove-Item Env:@E@
ps-py-pop                 | pester | G | 1 | os.environ.pop("@S@", None)
ps-js-delete              | pester | G | 1 | delete process.env.@S@;
ps-ere-other-cleared      | pester | O | 0 | Remove-Item Env:OTHER_VAR
# pytest: os.environ.pop("NAME", None) with either quote, alone on the line
py-double-quote           | pytest | G | 0 | os.environ.pop("@S@", None)
py-single-quote           | pytest | G | 0 | os.environ.pop('@E@', None)
py-no-space-after-comma   | pytest | G | 0 | os.environ.pop("@S@",None)
py-indented               | pytest | G | 0 |         os.environ.pop("@E@", None)
py-crlf                   | pytest | G | 0 | os.environ.pop("@S@", None)@CR@
py-other-var              | pytest | G | 1 | os.environ.pop("OTHER_VAR", None)
py-suffix-name            | pytest | G | 1 | os.environ.pop("@E@_X", None)
py-mixed-quotes           | pytest | G | 1 | os.environ.pop("@S@', None)
py-no-default             | pytest | G | 1 | os.environ.pop("@S@")
py-del                    | pytest | G | 1 | del os.environ["@S@"]
py-assign                 | pytest | G | 1 | os.environ["@S@"] = "x"
py-read-assert            | pytest | G | 1 | assert "@E@" not in os.environ
py-tuple-literal          | pytest | G | 1 | _R = ("@S@", "@E@")
py-trailing-comment       | pytest | G | 1 | os.environ.pop("@S@", None)  # clear
py-two-on-one-line        | pytest | G | 1 | os.environ.pop("@S@", None); os.environ.pop("@E@", None)
py-ps-remove              | pytest | G | 1 | Remove-Item -Path Env:@S@ -Force
py-bash-unset             | pytest | G | 1 | unset @S@
py-ere-other-cleared      | pytest | O | 0 | os.environ.pop("OTHER_VAR", None)
TABLE

# run_lang <language> — every row of that language through its part function.
run_lang() {
  local want_lang="$1" name lang ere want line got rows=0
  while IFS='|' read -r name lang ere want line; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    lang="${lang//[[:space:]]/}"
    ere="${ere//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    [[ "$lang" == "$want_lang" ]] || continue
    rows=$((rows + 1))
    line="$(expand "${line# }")"
    if [[ "$ere" == "O" ]]; then ere="OTHER_VAR"; else ere="$GUARDED_ERE"; fi
    got="$(run_with_timeout 60 bash "$RUNNER" "$PARTS/$lang.sh" "${lang}_env_clear_line" "$ere" "$line")"
    assert_eq "$name: $got" "$name: rc=$want out=0"
  done <"$ROWS"
  [[ "$rows" -gt 0 ]] || fail "$want_lang rows" "no row for $want_lang in the table"
}

case_begin "bash-env-clear-line-table" "bin/lib/test-language-parts/bash.sh"
run_lang bash
case_end

case_begin "js-env-clear-line-table" "bin/lib/test-language-parts/js.sh"
run_lang js
case_end

case_begin "pester-env-clear-line-table" "bin/lib/test-language-parts/pester.sh"
run_lang pester
case_end

case_begin "pytest-env-clear-line-table" "bin/lib/test-language-parts/pytest.sh"
run_lang pytest
case_end

# The registry route: tlr_call_part <id> envClearLine reaches each supported entry's part, the
# shell dump carries the field, and the recognized-only entry has none.
# reg_route <root> <ere> <name> — a subshell, so the loader's state stays out of this shell.
reg_route() (
  . "$1/bin/lib/test-language-registry.sh" || exit 97
  tlr_load || exit 96
  local ere="$2" s="$3" id ok bad rc_ok rc_bad
  for id in $(tlr_ids supported); do
    ok=""; bad=""
    if [ "$id" = bash ]; then ok="unset $s"; bad="delete process.env.$s;"; fi
    if [ "$id" = js ]; then ok="delete process.env.$s;"; bad="unset $s"; fi
    if [ "$id" = pester ]; then ok="Remove-Item -Path Env:$s -ErrorAction SilentlyContinue"; bad="os.environ.pop('$s', None)"; fi
    if [ "$id" = pytest ]; then ok="os.environ.pop('$s', None)"; bad="Remove-Item Env:$s"; fi
    rc_ok=x; rc_bad=x
    if [ -n "$ok" ]; then
      tlr_call_part "$id" envClearLine "$ere" "$ok" >/dev/null 2>&1; rc_ok=$?
      tlr_call_part "$id" envClearLine "$ere" "$bad" >/dev/null 2>&1; rc_bad=$?
    fi
    printf 'supported %s fn=%s ok=%s bad=%s\n' "$id" "$(tlr_field "$id" envClearLine.function)" "$rc_ok" "$rc_bad"
  done
  for id in $(tlr_ids recognized-only); do
    printf 'recognized %s fn=%s\n' "$id" "$(tlr_field "$id" envClearLine.function)"
  done
)
REG_OUT="$(reg_route "$SCRIPT_CHECKOUT_ROOT" "$GUARDED_ERE" "$RET_S" 2>"$TMPBASE/reg.err")"

case_begin "registry-routes-each-supported-entry-to-its-part" "hooks/lib/test-language-registry.json"
assert_eq "supported bash: $(printf '%s\n' "$REG_OUT" | grep '^supported bash ')" "supported bash: supported bash fn=bash_env_clear_line ok=0 bad=1"
assert_eq "supported js: $(printf '%s\n' "$REG_OUT" | grep '^supported js ')" "supported js: supported js fn=js_env_clear_line ok=0 bad=1"
assert_eq "supported pester: $(printf '%s\n' "$REG_OUT" | grep '^supported pester ')" "supported pester: supported pester fn=pester_env_clear_line ok=0 bad=1"
assert_eq "supported pytest: $(printf '%s\n' "$REG_OUT" | grep '^supported pytest ')" "supported pytest: supported pytest fn=pytest_env_clear_line ok=0 bad=1"
while IFS= read -r reg_line; do
  if [[ "$reg_line" == "supported "* ]] && [[ "$reg_line" == *" fn= "* || "$reg_line" == *" ok=x "* ]]; then
    fail "supported entry without envClearLine" "$reg_line"
  elif [[ "$reg_line" == "recognized "* && "$reg_line" == *" fn=" ]]; then
    pass "recognized-only has no envClearLine: $reg_line"
  elif [[ "$reg_line" == "recognized "* ]]; then
    fail "recognized-only envClearLine" "$reg_line"
  fi
done <<<"$REG_OUT"
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
