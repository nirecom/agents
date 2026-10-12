#!/usr/bin/env bash
# tests/bin/feature-2501-wrapper-pester.sh
# Tests: bin/lib/test-wrappers/pester.ps1
# Tags: scope:issue-specific, pwsh-required, test-language-wrapper, pester, run-all, result-dir, unrunnable, tl2
# Pester language wrapper (#2501 D4-1): exit-table normalization (77 / 256 failures -> 1,
# 0 tests -> 77, all skipped -> 77, top-level exit 77 -> 77), version floor -> 79 + marker,
# per-run testResults.xml in the result dir (#2483), env removal before test code, cases.tsv.
# TL3 gap: worker-dispatch env (PSModulePath) resolution is covered by TL3-worker-dispatch-mixed-language-run.sh.
set -u

# Pin to this checkout: the wrappers under test are the ones beside this file.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$SCRIPT_CHECKOUT_ROOT"
. "$REPO_ROOT/tests/lib/harness.sh"

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 77; }
if ! run_with_timeout 60 pwsh -NoProfile -Command "if (Get-Module -ListAvailable Pester | ? Version -ge '5.0') {exit 0} else {exit 1}" >/dev/null 2>&1; then
  echo "SKIP: Pester>=5.0 not importable"
  exit 77
fi

unset RUN_ALL_TIMEOUT_SECONDS PROBE_OUT
WRAPPER="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-wrappers/pester.ps1"
T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fx" "$T/cwd"

# run_pester <resdir> <fixture> <minVersion> [cwd] — direct wrapper launch; rc in PRC and returned.
run_pester() {
  local res="$1" fx="$2" mv="$3" cwd="${4:-$T/cwd}"
  mkdir -p "$res"
  PRC=0
  (
    cd "$cwd" || exit 2
    export RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER
    RUN_ALL_RESULT_DIR="$(np "$res")"
    RUN_ALL_RESULT_OWNER="$fx"
    run_with_timeout 120 pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(np "$WRAPPER")" -Path "$(np "$fx")" -MinVersion "$mv" >"$res.out" 2>&1 </dev/null
  ) || PRC=$?
  return "$PRC"
}

# tsv_count <resdir> <STATE> — number of cases.tsv records in that state.
tsv_count() {
  if [ -f "$1/cases.tsv" ]; then awk -F'\t' -v s="$2" '$2==s{n++} END{print n+0}' "$1/cases.tsv"; else echo 0; fi
}

cat >"$T/fx/mixed.Tests.ps1" <<'EOF'
Describe 'mixed' {
  It 'passes' { 1 | Should -Be 1 }
  It 'skipped-flag' -Skip { 1 | Should -Be 2 }
  It 'skipped-result' { Set-ItResult -Skipped -Because 'fixture'; 1 | Should -Be 2 }
}
EOF
cat >"$T/fx/allskip.Tests.ps1" <<'EOF'
Describe 'allskip' {
  It 'a' -Skip { 1 | Should -Be 1 }
  It 'b' { Set-ItResult -Skipped -Because 'fixture' }
}
EOF
printf 'exit 77\n' >"$T/fx/toplevel77.Tests.ps1"
printf "Describe 'empty' { }\n" >"$T/fx/empty.Tests.ps1"
cat >"$T/fx/fail77.Tests.ps1" <<'EOF'
Describe 'fail77' {
  It 'f<_>' -ForEach (1..77) { $false | Should -BeTrue }
}
EOF
cat >"$T/fx/fail256.Tests.ps1" <<'EOF'
Describe 'fail256' {
  It 'f<_>' -ForEach (1..256) { $false | Should -BeTrue }
}
EOF
printf "Describe 'para1' { It 'ok' { 1 | Should -Be 1 } }\n" >"$T/fx/para1.Tests.ps1"
printf "Describe 'para2' { It 'ok' { 1 | Should -Be 1 } }\n" >"$T/fx/para2.Tests.ps1"
cat >"$T/fx/envprobe.Tests.ps1" <<'EOF'
Describe 'envprobe' {
  It 'writes env' { Set-Content -LiteralPath $env:PROBE_OUT -Value ("[" + $env:RUN_ALL_RESULT_DIR + "|" + $env:RUN_ALL_RESULT_OWNER + "]") -NoNewline }
}
EOF

case_begin "wrapper-file-exists" "bin/lib/test-wrappers/pester.ps1"
if [ -f "$WRAPPER" ]; then pass "pester wrapper present"; else fail "pester wrapper missing" "$WRAPPER"; fi
case_end

case_begin "pass-and-skips-exit-0-with-records" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-mixed" "$T/fx/mixed.Tests.ps1" 5.0
assert_eq "$PRC" 0
mixed_native="$(np "$T/fx/mixed.Tests.ps1")"
if [ -f "$T/r-mixed/cases.tsv" ] && awk -F'\t' -v t="$mixed_native" '$2=="PASS" && $3=="mixed.passes" && $4==t{f=1} END{exit !f}' "$T/r-mixed/cases.tsv"; then
  pass "PASS record: case=ExpandedPath target=-Path"
else
  fail "PASS record mixed.passes with target=$mixed_native missing"
fi
assert_eq "$(tsv_count "$T/r-mixed" SKIP)" 2
assert_eq "$(tsv_count "$T/r-mixed" FAIL)" 0
case_end

case_begin "all-skipped-exit-77" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-allskip" "$T/fx/allskip.Tests.ps1" 5.0
assert_eq "$PRC" 77
assert_eq "$(tsv_count "$T/r-allskip" PASS)" 0
case_end

case_begin "top-level-exit-77-is-skip" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-top77" "$T/fx/toplevel77.Tests.ps1" 5.0
assert_eq "$PRC" 77
case_end

case_begin "empty-describe-exit-77" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-empty" "$T/fx/empty.Tests.ps1" 5.0
assert_eq "$PRC" 77
case_end

case_begin "seventy-seven-failures-exit-1" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-f77" "$T/fx/fail77.Tests.ps1" 5.0
assert_eq "$PRC" 1
assert_eq "$(tsv_count "$T/r-f77" FAIL)" 77
case_end

case_begin "two-hundred-fifty-six-failures-exit-1" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-f256" "$T/fx/fail256.Tests.ps1" 5.0
assert_eq "$PRC" 1
assert_eq "$(tsv_count "$T/r-f256" FAIL)" 256
case_end

case_begin "min-version-unmet-exit-79-with-marker" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-v99" "$T/fx/mixed.Tests.ps1" 99.0
assert_eq "$PRC" 79
if [ -f "$T/r-v99/unrunnable" ]; then
  assert_eq "$(tr -d '\r\n' <"$T/r-v99/unrunnable")" "Pester>=99.0"
else
  fail "unrunnable marker missing" "$T/r-v99/unrunnable"
fi
assert_eq "$(tsv_count "$T/r-v99" PASS)" 0
case_end

# An installed Pester that fails to import is a failure, never "runtime missing". The fixture
# module is the only one >= 98.0, so -MinVersion 98.0 selects it wherever it sits on the path.
mkdir -p "$T/broken/Pester/99.0.0"
printf '%s\n' "@{ ModuleVersion = '99.0.0'; RootModule = 'Pester.psm1'; GUID = '5d0b4c0e-2501-4a1f-9c1d-000000002501' }" >"$T/broken/Pester/99.0.0/Pester.psd1"
printf '%s\n' "throw 'broken-pester-2501'" >"$T/broken/Pester/99.0.0/Pester.psm1"
PSEP=":"
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) PSEP=";" ;; esac
case_begin "broken-pester-install-is-fail-not-unrunnable" "bin/lib/test-wrappers/pester.ps1"
PSModulePath="$(np "$T/broken")$PSEP${PSModulePath-}" run_pester "$T/r-broken" "$T/fx/mixed.Tests.ps1" 98.0
assert_eq "broken install rc: $PRC" "broken install rc: 1"
if [ -e "$T/r-broken/unrunnable" ]; then fail "broken install wrote an unrunnable marker"; else pass "broken install: no unrunnable marker"; fi
if grep -q 'broken-pester-2501' "$T/r-broken.out"; then pass "broken install: the import error is shown"; else fail "import error not in output" "$(tail -3 "$T/r-broken.out")"; fi
case_end

case_begin "test-results-xml-in-result-dir" "bin/lib/test-wrappers/pester.ps1"
if [ -s "$T/r-mixed/testResults.xml" ]; then pass "testResults.xml written to result dir"; else fail "testResults.xml not in result dir" "$T/r-mixed"; fi
if [ -e "$T/cwd/testResults.xml" ]; then fail "testResults.xml leaked into cwd"; else pass "no testResults.xml in cwd"; fi
case_end

case_begin "parallel-same-cwd-separate-result-dirs" "bin/lib/test-wrappers/pester.ps1"
mkdir -p "$T/pcwd"
run_pester "$T/r-p1" "$T/fx/para1.Tests.ps1" 5.0 "$T/pcwd" &
pid1=$!
run_pester "$T/r-p2" "$T/fx/para2.Tests.ps1" 5.0 "$T/pcwd" &
pid2=$!
prc1=0; wait "$pid1" || prc1=$?
prc2=0; wait "$pid2" || prc2=$?
assert_eq "$prc1" 0
assert_eq "$prc2" 0
if [ -f "$T/r-p1/testResults.xml" ] && grep -q 'para1' "$T/r-p1/testResults.xml" && ! grep -q 'para2' "$T/r-p1/testResults.xml"; then
  pass "run 1 xml holds only its own results"
else
  fail "run 1 testResults.xml missing or mixed" "$T/r-p1"
fi
if [ -f "$T/r-p2/testResults.xml" ] && grep -q 'para2' "$T/r-p2/testResults.xml" && ! grep -q 'para1' "$T/r-p2/testResults.xml"; then
  pass "run 2 xml holds only its own results"
else
  fail "run 2 testResults.xml missing or mixed" "$T/r-p2"
fi
case_end

case_begin "result-env-not-visible-to-test-code" "bin/lib/test-wrappers/pester.ps1"
export PROBE_OUT
PROBE_OUT="$(np "$T/envprobe.txt")"
run_pester "$T/r-env" "$T/fx/envprobe.Tests.ps1" 5.0
unset PROBE_OUT
assert_eq "$PRC" 0
if [ -f "$T/envprobe.txt" ]; then
  assert_eq "$(tr -d '\r\n' <"$T/envprobe.txt")" "[|]"
else
  fail "env probe test did not run" "$T/envprobe.txt"
fi
case_end

# TIMEOUT is applied by the launcher, not the wrapper: one case through run_all_exec.
case_begin "launcher-timeout-env-gives-124" "bin/lib/test-wrappers/pester.ps1"
mkdir -p "$T/to" "$T/r-to"
printf "Describe 'slow' { It 'sleeps' { Start-Sleep -Seconds 25 } }\n" >"$T/to/slow.Tests.ps1"
. "$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
RUN_ALL_EXEC_STATE=""
torc=0
export RUN_ALL_TIMEOUT_SECONDS=6
run_all_exec "$T/to/slow.Tests.ps1" "$T/to.out" "$T/to.err" "$T/r-to" || torc=$?
unset RUN_ALL_TIMEOUT_SECONDS
assert_eq "$torc" 124
assert_eq "${RUN_ALL_EXEC_STATE:-}" "TIMEOUT"
case_end

# Container / block failures (plan D4-1 + conversion table): FailedContainersCount + FailedBlocksCount > 0
# adds a synthetic `(container)` FAIL and the exit is 1 — never 77, even when no It ran.
cat >"$T/fx/beforeall.Tests.ps1" <<'EOF'
Describe 'ba' {
  BeforeAll { throw 'fixture boom' }
  It 'a' { 1 | Should -Be 1 }
  It 'b' { 1 | Should -Be 1 }
}
EOF
printf "Describe 'syn' {\n  It 'a' { 1 | Should -Be 1\n" >"$T/fx/syntax.Tests.ps1"
cat >"$T/fx/itexit77.Tests.ps1" <<'EOF'
Describe 'ex' {
  It 'ok' { 1 | Should -Be 1 }
  It 'quits' { exit 77 }
}
EOF

# tsv_container_fail <resdir> — a FAIL record whose case is the synthetic (container).
tsv_container_fail() {
  [ -f "$1/cases.tsv" ] && awk -F'\t' '$2=="FAIL" && $3=="(container)"{f=1} END{exit !f}' "$1/cases.tsv"
}

case_begin "before-all-throw-is-container-fail-exit-1" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-ba" "$T/fx/beforeall.Tests.ps1" 5.0
assert_eq "$PRC" 1
if tsv_container_fail "$T/r-ba"; then pass "BeforeAll throw adds a (container) FAIL record"; else fail "no (container) FAIL record for BeforeAll throw" "$T/r-ba"; fi
assert_eq "$(tsv_count "$T/r-ba" PASS)" 0
assert_eq "$(tsv_count "$T/r-ba" SKIP)" 0
case_end

case_begin "syntax-error-file-is-container-fail-exit-1" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-syn" "$T/fx/syntax.Tests.ps1" 5.0
assert_eq "$PRC" 1
if tsv_container_fail "$T/r-syn"; then pass "syntax error adds a (container) FAIL record"; else fail "no (container) FAIL record for a syntax error" "$T/r-syn"; fi
assert_eq "$(tsv_count "$T/r-syn" SKIP)" 0
case_end

# Pester turns `exit 77` inside an It into a Failed case (research pester-exit77-probe); it is
# not a container / block failure, so the case record is FAIL and the wrapper exit is 1, not 77.
case_begin "exit-77-inside-it-is-fail-exit-1" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-itx" "$T/fx/itexit77.Tests.ps1" 5.0
assert_eq "$PRC" 1
if [ -f "$T/r-itx/cases.tsv" ] && awk -F'\t' '$2=="FAIL" && $3=="ex.quits"{f=1} END{exit !f}' "$T/r-itx/cases.tsv"; then
  pass "It with exit 77 recorded as FAIL"
else
  fail "no FAIL record for the It that exits 77" "$T/r-itx"
fi
assert_eq "$(tsv_count "$T/r-itx" SKIP)" 0
case_end

# Security round: -Path is a literal path. `a[1].Tests.ps1` as a wildcard names a1.Tests.ps1 and
# not itself, so a wildcard-interpreted path runs the wrong file.
mkdir -p "$T/wild"
printf "Describe 'literal' { It 'lit' { 1 | Should -Be 1 } }\n" >"$T/wild/a[1].Tests.ps1"
printf "Describe 'sibling' { It 'sib' { 1 | Should -Be 1 } }\n" >"$T/wild/a1.Tests.ps1"

case_begin "bracket-path-is-literal-not-wildcard" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-wild" "$T/wild/a[1].Tests.ps1" 5.0
assert_eq "bracket path rc: $PRC" "bracket path rc: 0"
if [ -f "$T/r-wild/cases.tsv" ] && awk -F'\t' '$2=="PASS" && $3=="literal.lit"{f=1} END{exit !f}' "$T/r-wild/cases.tsv"; then
  pass "the bracketed file itself ran (literal.lit PASS)"
else
  fail "literal.lit PASS record missing" "$(cat "$T/r-wild/cases.tsv" 2>/dev/null)"
fi
if [ -f "$T/r-wild/cases.tsv" ] && awk -F'\t' '$3=="sibling.sib"{f=1} END{exit !f}' "$T/r-wild/cases.tsv"; then
  fail "the wildcard sibling a1.Tests.ps1 ran instead/as well"
else
  pass "the wildcard sibling a1.Tests.ps1 did not run"
fi
case_end

# The test code runs under the default session preferences (StrictMode off, EAP Continue), as
# under a plain Invoke-Pester; only the wrapper's own code is strict. P3 is the failing control.
cat >"$T/fx/strictoff.Tests.ps1" <<'EOF'
Describe 'strictoff' {
  It 'unset-script-var' { if ($null -ne $script:neverSet2501) { throw 'unexpected value' }; $true | Should -BeTrue }
  It 'unset-lastexitcode' { $code = $LASTEXITCODE; $null -eq $code -or $code -is [int] | Should -BeTrue }
}
EOF
cat >"$T/fx/eapcontinue.Tests.ps1" <<'EOF'
Describe 'eapcontinue' {
  It 'non-terminating-error-continues' { Write-Error 'nonterminating-2501'; $reached = $true; $reached | Should -BeTrue }
}
EOF
cat >"$T/fx/realfail.Tests.ps1" <<'EOF'
Describe 'realfail' {
  It 'assert' { 1 | Should -Be 2 }
  It 'throws' { throw 'real-failure-2501' }
}
EOF

# expect_pass_records <resdir> <label> <case>... — exit 0, each case a PASS record, no FAIL record.
expect_pass_records() {
  local res="$1" label="$2" c miss=""
  shift 2
  for c in "$@"; do
    awk -F'\t' -v c="$c" '$2=="PASS" && $3==c{f=1} END{exit !f}' "$res/cases.tsv" 2>/dev/null || miss="$miss $c"
  done
  if [ "$PRC" = 0 ] && [ -z "$miss" ] && [ "$(tsv_count "$res" FAIL)" = 0 ]; then
    pass "$label: exit 0 and PASS records for $*"
  else
    fail "$label: rc=$PRC missing-PASS=[${miss# }]" "$(grep -E 'cannot be retrieved|nonterminating-2501|\[-\]' "$res.out" | head -n 4 | tr '\n' '|')"
  fi
}

case_begin "test-code-runs-strict-mode-off" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-strictoff" "$T/fx/strictoff.Tests.ps1" 5.0
expect_pass_records "$T/r-strictoff" "P1. unset \$script: var and unset \$LASTEXITCODE" strictoff.unset-script-var strictoff.unset-lastexitcode
case_end

case_begin "test-code-runs-eap-continue" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-eap" "$T/fx/eapcontinue.Tests.ps1" 5.0
expect_pass_records "$T/r-eap" "P2. a non-terminating Write-Error does not stop the It" eapcontinue.non-terminating-error-continues
case_end

case_begin "real-failure-still-fails-under-reset" "bin/lib/test-wrappers/pester.ps1"
run_pester "$T/r-realfail" "$T/fx/realfail.Tests.ps1" 5.0
assert_eq "P3. real failures rc: $PRC" "P3. real failures rc: 1"
assert_eq "P3. FAIL records: $(tsv_count "$T/r-realfail" FAIL) PASS records: $(tsv_count "$T/r-realfail" PASS)" "P3. FAIL records: 2 PASS records: 0"
case_end
# P4 (the wrapper's own strictness survives): syntax-error-file-is-container-fail-exit-1 and
# before-all-throw-is-container-fail-exit-1 above already cover it.

echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
