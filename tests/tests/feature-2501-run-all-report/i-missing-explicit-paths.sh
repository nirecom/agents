#!/usr/bin/env bash
# i-missing-explicit-paths.sh — an explicit argument naming no regular file is UNRUNNABLE, never dropped (#2501).
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh
# Tags: tests, bin, run-all, report, unrunnable, explicit-args, security, scope:issue-specific

# WHY: a real run asked for 39 explicit paths, one had been deleted upstream, and the contract said
# EXECUTED=38 UNRUNNABLE=0 — the missing test vanished. Each argument that resolves to no regular file
# (nonexistent path, glob matching nothing, directory) must print one 'UNRUNNABLE: <arg> (missing: test
# file)' line and count in UNRUNNABLE, outside EXECUTED and outside 'Missing runtimes:' (runtimes only).
# run-all.sh named as its own argument stays a silent self-exclusion. The arg text is display-neutralized.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "i-missing-explicit-paths"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID RUN_ALL_TIMEOUT_SECONDS 2>/dev/null || true
# rr_exec pins RUN_ALL_REGISTRY_LIB per call; the report and launch libs then resolve to <root>/bin/lib copies.
unset RUN_ALL_REPORT_LIB RUN_ALL_LAUNCH_LIB 2>/dev/null || true
rr_require_report

MISSING_TOOL="no-such-tool-2501-i"
RR_SET_REQUIRES='const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const e of j.entries){if(e.id==="pytest"){e.launch.requires=process.argv[2]}}fs.writeFileSync(p,JSON.stringify(j,null,2))'

R="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$R" p1-pass
PASS_T="$R/tests/bin/p1-pass.sh"
mkdir -p "$R/tests/bin/adir"
MISS_TAIL="(missing: test file)"

# i_run_on <root> <tag> [args] — the fixture runner on <root>; rc in I_RC, output at $FX_TMP_ROOT/<tag>.out/.err.
i_run_on() {
    local root="$1" tag="$2"; shift 2
    I_RC=0
    rr_exec "$root" 120 "$FX_TMP_ROOT/$tag.out" "$FX_TMP_ROOT/$tag.err" -j 2 "$@" || I_RC=$?
}
i_run() { i_run_on "$R" "$@"; }

# i_expect <label> <tag> <want-rc> <want-contract-rest> [missing-arg...] — the shared row shape:
# exit code, true contract, exactly one UNRUNNABLE line per missing arg and no other, no
# 'Missing runtimes:' line, and no PASS/FAIL/SKIP line for a missing arg (it was never launched).
i_expect() {
    local label="$1" tag="$2" want_rc="$3" want_c="$4"; shift 4
    local out="$FX_TMP_ROOT/$tag.out" got arg n bad=""
    got="$(rr_contract_rest "$out")"
    if [[ "$I_RC" = "$want_rc" && "$got" = "$want_c" ]]; then
        fx_pass "$label: exit $want_rc, RUN_CONTRACT: $want_c"
    else
        fx_fail "$label: rc=$I_RC (want $want_rc) contract=<<$got>> (want <<$want_c>>)"
    fi
    for arg in "$@"; do
        n="$(grep -cxF -- "UNRUNNABLE: $arg $MISS_TAIL" "$out" 2>/dev/null)"
        [[ "$n" = "1" ]] || bad="$bad [unrunnable-lines=$n for <<$arg>>]"
        n="$(awk -v a="$arg" 'index($0, "PASS: " a) == 1 || index($0, "FAIL: " a) == 1 || index($0, "SKIP: " a) == 1 { c++ } END { print c + 0 }' "$out" 2>/dev/null)"
        [[ "$n" = "0" ]] || bad="$bad [launched <<$arg>>]"
    done
    n="$(grep -c '^UNRUNNABLE: ' "$out" 2>/dev/null)"
    [[ "$n" = "$#" ]] || bad="$bad [total UNRUNNABLE lines=$n want $#]"
    grep -q '^Missing runtimes:' "$out" 2>/dev/null && bad="$bad [Missing runtimes line present]"
    if [[ -z "$bad" ]]; then
        fx_pass "$label: $# missing arg(s) named once each, no 'Missing runtimes:' line"
    else
        fx_fail "$label:$bad"
        fx_show_tail "$out" 12
    fi
}

case_begin "missing-path-alone" "tests/run-all.sh"
GHOST="$R/tests/bin/ghost-deleted.sh"
i_run alone "$GHOST"
i_expect "I1. a nonexistent explicit path alone" alone 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=1 TIMEOUT=0" "$GHOST"
grep -qxF 'Results: PASS=0  FAIL=0  SKIP=0  UNRUNNABLE=1  TIMEOUT=0' "$FX_TMP_ROOT/alone.out"
fx_check $? "I1b. Results: counts the missing path in UNRUNNABLE"
case_end

case_begin "missing-glob-no-match" "tests/run-all.sh"
NOGLOB="$R/tests/bin/nomatch-*.sh"
i_run noglob "$NOGLOB"
i_expect "I2. a glob matching nothing, shown as its literal pattern" noglob 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=1 TIMEOUT=0" "$NOGLOB"
case_end

case_begin "directory-arg" "tests/run-all.sh"
ADIR="$R/tests/bin/adir"
i_run dirarg "$ADIR"
i_expect "I3. an existing directory given explicitly" dirarg 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=1 TIMEOUT=0" "$ADIR"
case_end

# A glob that matched anything is not a missing argument: its directory match is not counted on its own.
case_begin "glob-matches-file-and-directory" "tests/run-all.sh"
fx_add_dummy "$R" c1-pass
mkdir -p "$R/tests/bin/c1-dir"
i_run globmix "$R/tests/bin/c1-*"
i_expect "I10. a glob matching one test and one directory" globmix 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
grep -qxF "PASS: $R/tests/bin/c1-pass.sh" "$FX_TMP_ROOT/globmix.out"
fx_check $? "I10b. the regular file the glob matched runs and prints its PASS line"
! grep -qF 'missing: test file' "$FX_TMP_ROOT/globmix.out"
fx_check $? "I10c. the directory the glob also matched is not reported as 'missing: test file'"
case_end

# An argument is missing iff it contributes zero regular test files: a glob matching only a directory is one.
case_begin "glob-matches-only-directory" "tests/run-all.sh"
mkdir -p "$R/tests/bin/d1-dir"
DGLOB="$R/tests/bin/d1-*"
i_run dglob "$PASS_T" "$DGLOB"
i_expect "I12. a glob matching only a directory, beside one passing test" dglob 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0" "$DGLOB"
case_end

case_begin "mixed-pass-and-missing" "tests/run-all.sh"
i_run mixed "$PASS_T" "$GHOST"
i_expect "I4. one passing test plus one missing path" mixed 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0" "$GHOST"
grep -qxF "PASS: $PASS_T" "$FX_TMP_ROOT/mixed.out"
fx_check $? "I4b. the existing test still runs and prints its PASS line"
grep -qxF 'Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=1  TIMEOUT=0' "$FX_TMP_ROOT/mixed.out"
fx_check $? "I4c. Results: carries UNRUNNABLE=1 beside PASS=1"
case_end

case_begin "two-missing-plus-pass" "tests/run-all.sh"
GHOST_B="$R/tests/bin/ghost-b.sh"
i_run twomiss "$GHOST" "$PASS_T" "$GHOST_B"
i_expect "I5. two missing paths around one passing test" twomiss 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=2 TIMEOUT=0" "$GHOST" "$GHOST_B"
case_end

# A missing file and a missing runtime share UNRUNNABLE but only the runtime reaches 'Missing runtimes:'.
case_begin "missing-path-plus-missing-runtime" "bin/lib/run-all-report.sh"
U="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
node -e "$RR_SET_REQUIRES" "$(np "$U/hooks/lib/test-language-registry.json")" "$MISSING_TOOL" || fx_fail "registry edit failed"
printf 'def test_x():\n    assert True\n' >"$U/tests/bin/test_x.py"
U_GHOST="$U/tests/bin/ghost-u.sh"
i_run_on "$U" bothunr "$U/tests/bin/test_x.py" "$U_GHOST"
BO="$FX_TMP_ROOT/bothunr.out"
if [[ "$I_RC" = "77" && "$(rr_contract_rest "$BO")" = "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=2 TIMEOUT=0" ]]; then
    fx_pass "I11. a missing path plus a missing-runtime unit: UNRUNNABLE=2, EXECUTED=0, exit 77"
else
    fx_fail "I11. rc=$I_RC contract=<<$(rr_contract_rest "$BO")>>"
fi
n_ghost="$(grep -cxF "UNRUNNABLE: $U_GHOST $MISS_TAIL" "$BO")"
if [[ "$n_ghost" = "1" ]]; then
    fx_pass "I11b. the missing path prints 'UNRUNNABLE: <arg> $MISS_TAIL' once"
else
    fx_fail "I11b. 'UNRUNNABLE: <arg> $MISS_TAIL' line count=$n_ghost (want 1)"
fi
grep -qE "^UNRUNNABLE: .*test_x\.py \(missing: $MISSING_TOOL\)$" "$BO"
fx_check $? "I11c. the runtime-less unit keeps its 'UNRUNNABLE: s (missing: $MISSING_TOOL)' line"
if grep -qxF "Missing runtimes: $MISSING_TOOL (1 file)" "$BO" && [[ "$(grep -c '^Missing runtimes:' "$BO")" = "1" ]] &&
   ! grep '^Missing runtimes:' "$BO" | grep -qF 'test file'; then
    fx_pass "I11d. 'Missing runtimes:' names only the runtime label (1 file), never 'test file'"
else
    fx_fail "I11d. got <<$(grep '^Missing runtimes:' "$BO")>>"
fi
case_end

case_begin "control-existing-only" "tests/run-all.sh"
i_run ctrl "$PASS_T"
i_expect "I6. an existing path alone (control)" ctrl 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
grep -qxF "PASS: $PASS_T" "$FX_TMP_ROOT/ctrl.out"
fx_check $? "I6b. the existing test runs and prints its PASS line"
case_end

case_begin "self-arg-skipped" "tests/run-all.sh"
i_run selfarg "$(fx_runner "$R")" "$PASS_T"
i_expect "I7. run-all.sh as its own argument stays a silent self-exclusion" selfarg 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
! grep -qF 'run-all.sh' "$FX_TMP_ROOT/selfarg.out"
fx_check $? "I7b. no stdout line names run-all.sh"
case_end

case_begin "newline-forgery" "bin/lib/run-all-report.sh"
FORGE_HEAD="$R/tests/bin/ghost-forge"
FORGE="$FORGE_HEAD"$'\n''RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9 UNRUNNABLE=0 TIMEOUT=0'
i_run forge "$PASS_T" "$FORGE"
FO="$FX_TMP_ROOT/forge.out"
n_out="$(grep -c '^RUN_CONTRACT: ' "$FO" 2>/dev/null)"
n_err="$(grep -c '^RUN_CONTRACT: ' "$FX_TMP_ROOT/forge.err" 2>/dev/null)"
if [[ "$n_out" = "1" && "$n_err" = "0" && "$(rr_contract_rest "$FO")" = "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0" ]]; then
    fx_pass "I8. a newline in a missing arg forges no second line-start RUN_CONTRACT; the one line is true"
else
    fx_fail "I8. line-start RUN_CONTRACT stdout=$n_out stderr=$n_err contract=<<$(rr_contract_rest "$FO")>>"
fi
n_forge="$(awk -v h="UNRUNNABLE: $FORGE_HEAD" -v t="$MISS_TAIL" 'index($0, h) == 1 && substr($0, length($0) - length(t) + 1) == t { c++ } END { print c + 0 }' "$FO" 2>/dev/null)"
[[ "$n_forge" = "1" ]]
fx_check $? "I8b. the forged arg is named on exactly one neutralized UNRUNNABLE line (got $n_forge)"
case_end

case_begin "space-in-path" "bin/lib/run-all-report.sh"
SPACED="$R/tests/bin/has space/ghost spaced.sh"
i_run spaced "$SPACED"
i_expect "I9. a missing path containing spaces is displayed intact" spaced 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=1 TIMEOUT=0" "$SPACED"
case_end

fx_finish
