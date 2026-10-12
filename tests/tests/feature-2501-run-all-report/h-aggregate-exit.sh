#!/usr/bin/env bash
# h-aggregate-exit.sh — the run-wide exit code from the final counts (#2501 D5-2, C1).
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh, hooks/lib/run-contract.js
# Tags: tests, bin, run-all, report, exit-code, run-contract, scope:issue-specific

# WHY: a run that passed nothing (all SKIP, nothing selected, all UNRUNNABLE, all UNSUPPORTED) is
# not a pass, so it exits 77 like a single file would; FAIL>0 exits 1; one PASS with no FAIL exits 0.
# The real run-all contract line also round-trips byte for byte through run-contract.js.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "h-aggregate-exit"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID RUN_ALL_TIMEOUT_SECONDS 2>/dev/null || true
rr_require_report

MISSING_TOOL="no-such-tool-2501-h"
RR_SET_REQUIRES='const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const e of j.entries){if(e.id==="pytest"){e.launch.requires=process.argv[2]}}fs.writeFileSync(p,JSON.stringify(j,null,2))'

# h_run <tag> <root> [args] — the fixture runner on <root>; rc in H_RC, output at $FX_TMP_ROOT/<tag>.out.
h_run() {
    local tag="$1" root="$2"; shift 2
    H_RC=0
    rr_exec "$root" 120 "$FX_TMP_ROOT/$tag.out" "$FX_TMP_ROOT/$tag.err" -j 2 "$@" || H_RC=$?
}

# h_expect <label> <tag> <want-rc> <want-contract-rest>
h_expect() {
    local got
    got="$(rr_contract_rest "$FX_TMP_ROOT/$2.out")"
    if [ "$H_RC" = "$3" ] && [ "$got" = "$4" ]; then
        fx_pass "$1: exit $3, RUN_CONTRACT: $4"
    else
        fx_fail "$1: rc=$H_RC (want $3) contract=<<$got>> (want <<$4>>)"
    fi
}

case_begin "all-skip-exits-77" "bin/lib/run-all-report.sh"
R="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$R" s1 --exit 77
fx_add_dummy "$R" s2 --exit 77
h_run allskip "$R" --all
h_expect "H1. all SKIP" allskip 77 "PASS=0 FAIL=0 SKIP=2 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
case_end

case_begin "nothing-selected-exits-77" "bin/lib/run-all-report.sh"
E="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
h_run empty "$E" --all
h_expect "H2. TOTAL=0" empty 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=0 TIMEOUT=0"
case_end

case_begin "all-unrunnable-exits-77" "bin/lib/run-all-report.sh"
U="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
node -e "$RR_SET_REQUIRES" "$(np "$U/hooks/lib/test-language-registry.json")" "$MISSING_TOOL" || fx_fail "registry edit failed"
printf 'def test_x():\n    assert True\n' >"$U/tests/bin/test_x.py"
h_run allunr "$U" --all
h_expect "H3. all UNRUNNABLE" allunr 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=1 TIMEOUT=0"
case_end

case_begin "all-unsupported-exits-77" "bin/lib/run-all-report.sh"
N="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
: >"$N/tests/bin/notes.txt"
: >"$N/tests/bin/foo.test.ts"
h_run allunsup "$N" "$N/tests/bin/notes.txt" "$N/tests/bin/foo.test.ts"
h_expect "H4. all UNSUPPORTED" allunsup 77 "PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=0 TIMEOUT=0"
case_end

case_begin "pass-with-skip-or-unrunnable-exits-0" "bin/lib/run-all-report.sh"
P="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$P" p1
fx_add_dummy "$P" s1 --exit 77
h_run passskip "$P" --all
h_expect "H5. PASS 1 + SKIP 1" passskip 0 "PASS=1 FAIL=0 SKIP=1 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
node -e "$RR_SET_REQUIRES" "$(np "$P/hooks/lib/test-language-registry.json")" "$MISSING_TOOL" || fx_fail "registry edit failed"
rm -f "$P/tests/bin/s1.sh"
printf 'def test_x():\n    assert True\n' >"$P/tests/bin/test_x.py"
h_run passunr "$P" --all
h_expect "H6. PASS 1 + UNRUNNABLE 1" passunr 0 "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0"
case_end

case_begin "fail-beats-skip-exits-1" "bin/lib/run-all-report.sh"
F="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$F" s1 --exit 77
fx_add_dummy "$F" f1 --exit 1
h_run failskip "$F" --all
h_expect "H7. FAIL 1 + SKIP 1" failskip 1 "PASS=0 FAIL=1 SKIP=1 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
case_end

# The run-all printf and run-contract.js formatContract are two writers of one format (D5-1).
case_begin "contract-line-round-trips-through-run-contract-js" "hooks/lib/run-contract.js"
RC_JS="$(np "$FX_REPO_ROOT/hooks/lib/run-contract.js")"
for tag in allskip passskip passunr failskip; do
    line="$(grep -m1 '^RUN_CONTRACT: ' "$FX_TMP_ROOT/$tag.out" 2>/dev/null)"
    back="$(node -e 'const m=require(process.argv[1]);const c=m.parseContractLine(process.argv[2]);process.stdout.write(c?m.formatContract(c):"<null>")' "$RC_JS" "$line" 2>/dev/null)"
    if [ -n "$line" ] && [ "$back" = "$line" ]; then
        fx_pass "H8. $tag: formatContract(parseContractLine(line)) == line"
    else
        fx_fail "H8. $tag: line=<<$line>> round-trip=<<$back>>"
    fi
done
case_end

fx_finish
