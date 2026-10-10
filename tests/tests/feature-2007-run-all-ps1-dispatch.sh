#!/usr/bin/env bash
# Tests: tests/run-all.sh, bin/lib/run-all-launch.sh
# Tags: bin, tests, pwsh, python, scope:issue-specific, TL2
# run-all.sh discovers tests/<category>/ test files and launches each through run_all_exec
# (bin/lib/run-all-launch.sh) per the test language registry: pwsh / uv+pytest / bash; other
# files print UNSUPPORTED (#2007 / #1765 / #2392 / #2500). B3/B4 need uv/pwsh on PATH.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ALL="$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh"
LAUNCH_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"

# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

[ -f "$RUN_ALL" ] || { echo "SKIP: tests/run-all.sh not present"; exit 77; }

TMPDIR_FX="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FX"' EXIT
export WORKFLOW_STATE_DIR="$TMPDIR_FX/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_FX/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID
# Keep fixture runs out of the real duration ledger and progress stream.
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# run_all_fx <args...> — sets OUT / RC.
run_all_fx() { OUT="$(bash "$RUN_ALL" "$@" 2>&1)"; RC=$?; }

# S1/S2 (#2500): the launch per language is a row of the test language registry,
# read through its CLI — not a branch of bin/lib/run-all-launch.sh.
case_begin "registry-launch-rows" "bin/lib/run-all-launch.sh"
T=$'\t'
REG_RC=0
REG_SHELL="$(node "$SCRIPT_CHECKOUT_ROOT/bin/test-language-registry" --format shell 2>&1)" || REG_RC=$?
reg_has() { printf '%s\n' "$REG_SHELL" | grep -qxF -- "$1"; }
for s in "S1 pester *.Tests.ps1 pwsh" "S2 pytest test_*.py uv"; do
    read -r sid lid pat tool <<<"$s"
    if [ "$REG_RC" = "0" ] && reg_has "pattern${T}${lid}${T}${pat}" \
        && reg_has "field${T}${lid}${T}launch.requires${T}${tool}" && reg_has "arg${T}${lid}${T}command${T}${tool}"; then
        pass "$sid: registry routes $pat to $tool (pattern, requires, command)"
    else
        fail "$sid: registry lacks $lid -> $tool — rc=$REG_RC out=$(printf '%s' "$REG_SHELL" | head -n 3)"
    fi
done
case_end

# S3: --all discovery lists a category's *.Tests.ps1 and test_*.py (behaviour, not source text).
case_begin "discovery-and-dispatch" "tests/run-all.sh"
FX3="$TMPDIR_FX/s3-tests"
mkdir -p "$FX3/skills"
: >"$FX3/skills/x.Tests.ps1"
: >"$FX3/skills/test_x.py"
OUT="$(TESTS_DIR="$FX3" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 bash "$RUN_ALL" --print-plan --all 2>/dev/null)"; RC=$?
s3_plan="$(printf '%s\n' "$OUT" | grep -E '^plan' | awk -F'\t' '{print $4}' | sed 's#.*/##' | LC_ALL=C sort | tr '\n' ' ')"
if [ "$RC" = "0" ] && [ "$s3_plan" = "test_x.py x.Tests.ps1 " ]; then
    pass "S3: --all lists tests/<category>/x.Tests.ps1 and test_x.py"
else
    fail "S3: --all discovery mismatch — rc=$RC got=<<$s3_plan>>"
fi

# B1: a *.Tests.ps1 passed as positional arg exits 77 (SKIP) when pwsh is absent.
if ! command -v pwsh >/dev/null 2>&1; then
    PS1_FILE="$TMPDIR_FX/noop.Tests.ps1"
    printf 'Describe "noop" { It "passes" { $true | Should -BeTrue } }\n' >"$PS1_FILE"
    run_all_fx "$PS1_FILE"
    if echo "$OUT" | grep -qiE 'skip.*pwsh|pwsh.*not.*path' && [ "$RC" = "0" ]; then
        pass "B1: positional .Tests.ps1 skips (exit 77) when pwsh not on PATH"
    else
        fail "B1: expected SKIP + rc=0 for .Tests.ps1 without pwsh — got rc=$RC output=$(echo "$OUT" | tail -3)"
    fi
else
    echo "INFO: B1 skipped — pwsh is on PATH; behavioural skip-gate not verifiable"
fi

# B2: with uv absent, run_all_exec SKIPs a test_*.py with rc 77. An empty PATH makes uv
# absent on every host; the SKIP path uses shell builtins only.
if [ -f "$LAUNCH_LIB" ]; then
    mkdir -p "$TMPDIR_FX/emptybin" "$TMPDIR_FX/b2"
    printf 'def test_x():\n    assert True\n' >"$TMPDIR_FX/b2/test_x.py"
    # The launch reads the registry through node, so node alone stays reachable via a shim.
    if B2_NODE="$(command -v node)"; then
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$B2_NODE" >"$TMPDIR_FX/emptybin/node"
        chmod +x "$TMPDIR_FX/emptybin/node"
    fi
    # shellcheck disable=SC2123  # PATH is emptied on purpose to make uv absent.
    ( PATH="$TMPDIR_FX/emptybin"
      # shellcheck source=/dev/null
      . "$LAUNCH_LIB"
      run_all_exec "$TMPDIR_FX/b2/test_x.py" "$TMPDIR_FX/b2/out" "$TMPDIR_FX/b2/err" )
    b2_rc=$?
    b2_out="$(cat "$TMPDIR_FX/b2/out" 2>/dev/null)"
    if [ "$b2_rc" = "77" ] && [[ "$b2_out" == *"SKIP: uv not on PATH"* ]]; then
        pass "B2: test_*.py without uv → 'SKIP: uv not on PATH' + rc 77"
    else
        fail "B2: expected rc 77 + 'SKIP: uv not on PATH' — got rc=$b2_rc out=<<$b2_out>>"
    fi
else
    fail "B2: bin/lib/run-all-launch.sh missing — run_all_exec not implemented"
fi

# B3: with uv present, a passing test_*.py is PASS and a failing one is FAIL.
if command -v uv >/dev/null 2>&1; then
    mkdir -p "$TMPDIR_FX/b3"
    printf 'def test_ok():\n    assert True\n' >"$TMPDIR_FX/b3/test_ok.py"
    printf 'def test_ng():\n    assert False\n' >"$TMPDIR_FX/b3/test_ng.py"
    run_all_fx "$TMPDIR_FX/b3/test_ok.py"
    if [ "$RC" = "0" ] && echo "$OUT" | grep -q '^PASS: .*test_ok\.py'; then
        pass "B3a: passing test_ok.py runs under pytest → PASS"
    else
        fail "B3a: expected PASS for test_ok.py — rc=$RC out=$(echo "$OUT" | tail -5)"
    fi
    run_all_fx "$TMPDIR_FX/b3/test_ng.py"
    if [ "$RC" != "0" ] && echo "$OUT" | grep -q '^FAIL: .*test_ng\.py' && echo "$OUT" | grep -qi 'assert'; then
        pass "B3b: failing test_ng.py runs under pytest → FAIL with assertion output"
    else
        fail "B3b: expected pytest FAIL for test_ng.py — rc=$RC out=$(echo "$OUT" | tail -5)"
    fi
else
    echo "INFO: B3 skipped — uv not on PATH"
fi

# B4: with pwsh present, an MSYS-style (/c/...) path still reaches Pester (cygpath conversion).
if command -v pwsh >/dev/null 2>&1; then
    mkdir -p "$TMPDIR_FX/b4"
    printf 'Describe "noop" { It "passes" { $true | Should -BeTrue } }\n' >"$TMPDIR_FX/b4/noop.Tests.ps1"
    b4_path="$TMPDIR_FX/b4/noop.Tests.ps1"
    if command -v cygpath >/dev/null 2>&1; then
        b4_win="$(cygpath -m "$b4_path")"
        b4_drive="${b4_win%%:*}"
        b4_path="/$(printf '%s' "$b4_drive" | tr '[:upper:]' '[:lower:]')/${b4_win#?:/}"
    fi
    run_all_fx "$b4_path"
    if [ "$RC" = "0" ] && echo "$OUT" | grep -qE 'Passed: 1'; then
        pass "B4: MSYS-style path $b4_path resolves in pwsh and the Pester test passes"
    else
        fail "B4: MSYS-style .Tests.ps1 path not resolved by pwsh — rc=$RC out=$(echo "$OUT" | tail -5)"
    fi
else
    echo "INFO: B4 skipped — pwsh not on PATH"
fi

# B5: --all enumerates only category-direct *.sh / *.Tests.ps1 / test_*.py.
FX5="$TMPDIR_FX/b5-tests"
mkdir -p "$FX5/bin/sub" "$FX5/lib"
for f in bin/a.sh bin/a.Tests.ps1 bin/test_a.py bin/sub/test_b.py lib/x.Tests.ps1 test_c.py bin/helper.ps1 bin/helper.py; do
    : >"$FX5/$f"
done
OUT="$(TESTS_DIR="$FX5" bash "$RUN_ALL" --print-plan --all 2>/dev/null)"; RC=$?
b5_plan="$(printf '%s\n' "$OUT" | grep -E '^plan' | awk -F'\t' '{print $4}' | sed "s|^$FX5/||" | sort)"
b5_want="$(printf '%s\n' bin/a.Tests.ps1 bin/a.sh bin/test_a.py | sort)"
if [ "$RC" = "0" ] && [ "$b5_plan" = "$b5_want" ]; then
    pass "B5: --all lists exactly the 3 category-direct entrypoints (sub/lib/top-level excluded)"
else
    fail "B5: --all plan mismatch — rc=$RC got=<<$b5_plan>> want=<<$b5_want>>"
fi

# B6: a missing launch library falls back to plain bash for .sh (fixtures copy run-all.sh alone).
printf '#!/usr/bin/env bash\necho fallback-ran\nexit 0\n' >"$TMPDIR_FX/b6-pass.sh"
OUT="$(RUN_ALL_LAUNCH_LIB=/nonexistent bash "$RUN_ALL" "$TMPDIR_FX/b6-pass.sh" 2>&1)"; RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q 'fallback-ran' && echo "$OUT" | grep -q '^PASS: .*b6-pass\.sh'; then
    pass "B6: RUN_ALL_LAUNCH_LIB=/nonexistent still runs .sh via the bash fallback"
else
    fail "B6: .sh did not run without the launch library — rc=$RC out=$(echo "$OUT" | tail -3)"
fi

# B7 (#2434): every launched test gets a fresh per-run WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR
# that overrides the caller's pair and is removed with the work dir.
mkdir -p "$TMPDIR_FX/b7/caller-wf" "$TMPDIR_FX/b7/caller-plans"
cat >"$TMPDIR_FX/b7/print-dirs.sh" <<'B7_EOF'
#!/usr/bin/env bash
: >"$WORKFLOW_STATE_DIR/b7-marker" || exit 1
: >"$WORKFLOW_PLANS_DIR/b7-marker" || exit 1
printf 'B7_WF=%s\nB7_PL=%s\n' "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
B7_EOF
OUT="$(WORKFLOW_STATE_DIR="$TMPDIR_FX/b7/caller-wf" WORKFLOW_PLANS_DIR="$TMPDIR_FX/b7/caller-plans" \
    bash "$RUN_ALL" "$TMPDIR_FX/b7/print-dirs.sh" 2>&1)"; RC=$?
b7_wf="$(printf '%s\n' "$OUT" | sed -n 's/^B7_WF=//p')"
b7_pl="$(printf '%s\n' "$OUT" | sed -n 's/^B7_PL=//p')"
b7_leak="$(ls -A "$TMPDIR_FX/b7/caller-wf" "$TMPDIR_FX/b7/caller-plans" 2>/dev/null | grep -c 'b7-marker')"
if [ "$RC" = "0" ] && [ -n "$b7_wf" ] && [ -n "$b7_pl" ] && [ "$b7_wf" != "$b7_pl" ] \
    && [ "$b7_wf" != "$TMPDIR_FX/b7/caller-wf" ] && [ "$b7_pl" != "$TMPDIR_FX/b7/caller-plans" ] \
    && [ ! -e "$b7_wf" ] && [ ! -e "$b7_pl" ] && [ "$b7_leak" = "0" ]; then
    pass "B7: run-all pins both state dirs per run, overrides the caller's pair, and removes them"
else
    fail "B7: state dirs not pinned per run — rc=$RC wf=<<$b7_wf>> plans=<<$b7_pl>> leak=$b7_leak out=$(echo "$OUT" | tail -3)"
fi

case_end

# U1-U5 (#2500): a recognized-only or unmatched file is listed as UNSUPPORTED and
# changes no tally, exit code, plan or contract.
case_begin "unsupported-display" "tests/run-all.sh"
FXR="$TMPDIR_FX/u-root"
mkdir -p "$FXR/tests/hooks"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FXR/tests/hooks/ok.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FXR/tests/hooks/ng.sh"
: >"$FXR/tests/hooks/README.md"
# u_run <tag> <run-all args...> — from $FXR with TESTS_DIR=$FXR/tests; sets U_OUT / U_RC, keeps $TMPDIR_FX/<tag>.out.
u_run() {
    local tag="$1"; shift
    U_RC=0
    U_OUT="$(cd "$FXR" && TESTS_DIR="$FXR/tests" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 bash "$RUN_ALL" "$@" 2>/dev/null)" || U_RC=$?
    printf '%s\n' "$U_OUT" >"$TMPDIR_FX/$tag.out"
}
u_tail() { printf '%s\n' "$1" | grep -E '^(Results|RUN_CONTRACT):'; }
# u_hook <stdout-file> — what the hook side reads: contract, trust and failing list.
cat >"$TMPDIR_FX/u_hook.js" <<'JS'
const fs = require("fs");
const [file, root, hooks] = process.argv.slice(2);
const out = fs.readFileSync(file, "utf8");
const m = [...out.matchAll(/^[ \t]*RUN_CONTRACT: PASS=(\d+) FAIL=(\d+) SKIP=(\d+) EXECUTED=(\d+)/gm)];
if (m.length !== 1) { console.log("contracts=" + m.length); process.exit(0); }
const [pass, fail, skip, executed] = m[0].slice(1).map(Number);
const contract = { pass, fail, skip, executed };
const { isContractTrusted } = require(hooks + "/outcome.js");
const { extractFailingTests } = require(hooks + "/failing-list.js");
console.log("trusted=" + isContractTrusted({ attributed: true, contract }) +
  " failing=" + JSON.stringify(extractFailingTests({ stdout: out, worktreeRoot: root, contract })));
JS
u_hook() { node "$TMPDIR_FX/u_hook.js" "$1" "$FXR" "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests"; }

# U1: --all — js shown once, after the result lines and before Results:; tallies/exit/contract unchanged.
u_run u1-base --all; base_rc=$U_RC; base_tail="$(u_tail "$U_OUT")"
: >"$FXR/tests/hooks/a.test.js"
u_run u1 --all
want_line="UNSUPPORTED: $FXR/tests/hooks/a.test.js (language: js; not run)"
u1_lines="$(printf '%s\n' "$U_OUT" | grep -c '^UNSUPPORTED: ')"
u_ln="$(printf '%s\n' "$U_OUT" | grep -nxF -- "$want_line" | cut -d: -f1)"
r_ln="$(printf '%s\n' "$U_OUT" | grep -n '^Results:' | cut -d: -f1)"
t_ln="$(printf '%s\n' "$U_OUT" | grep -nE '^(PASS|FAIL|SKIP): ' | tail -n 1 | cut -d: -f1)"
if [ -n "$u_ln" ] && [ "$u1_lines" = "1" ] && [ -n "$r_ln" ] && [ -n "$t_ln" ] && [ "$t_ln" -lt "$u_ln" ] && [ "$u_ln" -lt "$r_ln" ]; then
    pass "U1a: --all prints one UNSUPPORTED line for a.test.js between the result lines and Results:"
else
    fail "U1a: --all UNSUPPORTED line missing or misplaced — lines=$u1_lines at=$u_ln last-result=$t_ln results=$r_ln"
fi
if [ "$U_RC" = "$base_rc" ] && [ "$base_rc" = "1" ] && [ "$(u_tail "$U_OUT")" = "$base_tail" ] && [ -n "$base_tail" ]; then
    pass "U1b: --all tallies, RUN_CONTRACT and exit code equal the run without a.test.js"
else
    fail "U1b: --all changed — rc=$U_RC base_rc=$base_rc tail=<<$(u_tail "$U_OUT" | tr '\n' '|')>> base=<<${base_tail//$'\n'/|}>>"
fi
# U1c: x.test.sh matches both bash (*.sh, supported) and *.test.* (recognized-only): it runs, never UNSUPPORTED.
printf '#!/usr/bin/env bash\nexit 0\n' >"$FXR/tests/hooks/x.test.sh"
u_run u1c --all
rm -f "$FXR/tests/hooks/x.test.sh"
u1c_lines="$(printf '%s\n' "$U_OUT" | grep -c '^UNSUPPORTED: ')"
u1c_dual="$(printf '%s\n' "$U_OUT" | grep -c 'UNSUPPORTED: .*x\.test\.sh')"
if [ "$u1c_lines" = "$u1_lines" ] && [ "$u1c_dual" = "0" ] && printf '%s\n' "$U_OUT" | grep -q '^PASS: .*x\.test\.sh'; then
    pass "U1c: --all runs x.test.sh (supported wins) and lists no UNSUPPORTED line for it"
else
    fail "U1c: dual-match x.test.sh — unsupported=$u1c_lines (want $u1_lines) dual=$u1c_dual out=$(printf '%s' "$U_OUT" | tail -n 6 | tr '\n' '|')"
fi

# U2: named — js and an unmatched file each get one line; the hook reads the same as without them.
: >"$FXR/tests/hooks/notes.txt"
u_run u2-base tests/hooks/ok.sh tests/hooks/ng.sh; base_rc=$U_RC; base_tail="$(u_tail "$U_OUT")"
u_run u2 tests/hooks/ok.sh tests/hooks/ng.sh tests/hooks/a.test.js tests/hooks/notes.txt
u2_have=0
for l in "UNSUPPORTED: tests/hooks/a.test.js (language: js; not run)" "UNSUPPORTED: tests/hooks/notes.txt (language: unknown; not run)"; do
    printf '%s\n' "$U_OUT" | grep -qxF -- "$l" && u2_have=$((u2_have + 1))
done
if [ "$u2_have" = "2" ] && [ "$U_RC" = "$base_rc" ] && [ "$(u_tail "$U_OUT")" = "$base_tail" ]; then
    pass "U2a: named js / unknown files print UNSUPPORTED (language: js|unknown); tallies and exit unchanged"
else
    fail "U2a: named UNSUPPORTED — found=$u2_have rc=$U_RC base_rc=$base_rc tail=<<$(u_tail "$U_OUT" | tr '\n' '|')>> base=<<${base_tail//$'\n'/|}>>"
fi
u2_hook="$(u_hook "$TMPDIR_FX/u2.out")"; u2_base_hook="$(u_hook "$TMPDIR_FX/u2-base.out")"
if [ "$u2_hook" = "$u2_base_hook" ] && [ "$u2_hook" = 'trusted=true failing=["tests/hooks/ng.sh"]' ] \
    && ! grep -qE '^FAIL: .*(a\.test\.js|notes\.txt)' "$TMPDIR_FX/u2.out"; then
    pass "U2b: failing-list and RUN_CONTRACT readers see the same result as without the unsupported files"
else
    fail "U2b: hook reading differs — with=<<$u2_hook>> without=<<$u2_base_hook>>"
fi

# U3: --print-plan never shows UNSUPPORTED and plans only the supported files.
u_run u3 --print-plan --all
if [ "$U_RC" = "0" ] && ! printf '%s\n' "$U_OUT" | grep -q 'UNSUPPORTED' && [ "$(printf '%s\n' "$U_OUT" | grep -c '^plan')" = "2" ]; then
    pass "U3: --print-plan --all plans ok.sh/ng.sh only and prints no UNSUPPORTED line"
else
    fail "U3: --print-plan output — rc=$U_RC out=$(printf '%s' "$U_OUT" | tr '\n' '|')"
fi

# U4: unsupported-only — EXECUTED=0, exit 0, and the hook does not trust the contract.
u_run u4 tests/hooks/a.test.js tests/hooks/notes.txt
if [ "$U_RC" = "0" ] && printf '%s\n' "$U_OUT" | grep -qxF 'RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0' \
    && [ "$(printf '%s\n' "$U_OUT" | grep -c '^UNSUPPORTED: ')" = "2" ] && [ "$(u_hook "$TMPDIR_FX/u4.out")" = "trusted=false failing=[]" ]; then
    pass "U4: unsupported-only run → 2 UNSUPPORTED, EXECUTED=0, exit 0, contract not trusted"
else
    fail "U4: unsupported-only — rc=$U_RC hook=<<$(u_hook "$TMPDIR_FX/u4.out")>> out=$(printf '%s' "$U_OUT" | tail -n 4 | tr '\n' '|')"
fi

# U5: an unreadable registry loader aborts with exit 5 and one exact stderr line.
u5_rc=0
u5_err="$(RUN_ALL_REGISTRY_LIB=/nonexistent bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 bash "$RUN_ALL" "$FXR/tests/hooks/ok.sh" 2>&1 >/dev/null)" || u5_rc=$?
if [ "$u5_rc" = "5" ] && printf '%s\n' "$u5_err" | grep -qxF '[run-all] test language registry not readable: /nonexistent (RUN_ALL_REGISTRY_LIB)'; then
    pass "U5: RUN_ALL_REGISTRY_LIB=/nonexistent → exit 5 with the registry-not-readable message"
else
    fail "U5: expected exit 5 + message — rc=$u5_rc err=<<$u5_err>>"
fi
# U5b: the loader exists but tlr_load fails — its sibling registry table is corrupt JSON.
U5B="$TMPDIR_FX/u5b-agents"
# shellcheck source=../lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"
u5b_lib="$U5B/bin/lib/test-language-registry.sh"
# Control: the installed set loads before corruption, so the abort below is the JSON's doing.
u5b_ok=0
install_test_language_registry "$U5B" "$SCRIPT_CHECKOUT_ROOT" && [ -f "$u5b_lib" ] \
  && bash -c '. "$1" && tlr_load' _ "$u5b_lib" >/dev/null 2>&1 && u5b_ok=1
printf '{ "schema": 1, "entries": [ \n' >"$U5B/hooks/lib/test-language-registry.json"
u5b_rc=0
u5b_err="$(RUN_ALL_REGISTRY_LIB="$u5b_lib" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 bash "$RUN_ALL" "$FXR/tests/hooks/ok.sh" 2>&1 >/dev/null)" || u5b_rc=$?
if [ "$u5b_ok" = "1" ] && [ "$u5b_rc" = "5" ] && printf '%s\n' "$u5b_err" | grep -qxF "[run-all] test language registry not readable: $u5b_lib (RUN_ALL_REGISTRY_LIB)"; then
    pass "U5b: loader present but its registry JSON corrupt → exit 5 with the registry-not-readable message"
else
    fail "U5b: expected a loadable install (ok=$u5b_ok), then exit 5 + message for a corrupt registry — rc=$u5b_rc err=<<$u5b_err>>"
fi
case_end

# shellcheck source=feature-2007-run-all-ps1-dispatch/pester-quoting.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2007-run-all-ps1-dispatch/pester-quoting.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
