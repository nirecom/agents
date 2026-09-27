#!/usr/bin/env bash
# Tests: tests/run-all.sh, bin/lib/run-all-launch.sh
# Tags: bin, tests, pwsh, python, scope:issue-specific, TL2
# run-all.sh discovers tests/<category>/{*.sh,*.Tests.ps1,test_*.py} and dispatches each by
# extension through run_all_exec (bin/lib/run-all-launch.sh): pwsh / uv+pytest / bash
# (issues #2007 / #1765 / #2392). B3/B4 need uv/pwsh on PATH and are skipped otherwise.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ALL="$AGENTS_DIR/tests/run-all.sh"
LAUNCH_LIB="$AGENTS_DIR/bin/lib/run-all-launch.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$RUN_ALL" ] || { echo "SKIP: tests/run-all.sh not present"; exit 77; }

TMPDIR_FX="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FX"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_FX/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_FX/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
# Keep fixture runs out of the real duration ledger and progress stream.
export RUN_ALL_DURATIONS_LIB=/nonexistent RUN_ALL_PROGRESS=off

# run_all_fx <args...> — sets OUT / RC.
run_all_fx() { OUT="$(bash "$RUN_ALL" "$@" 2>&1)"; RC=$?; }

# S1/S2: the per-extension dispatch lives in bin/lib/run-all-launch.sh.
if [ ! -f "$LAUNCH_LIB" ]; then
    fail "S1/S2: bin/lib/run-all-launch.sh missing — dispatch library not implemented"
else
    grep -qE '\.Tests\.ps1' "$LAUNCH_LIB" && grep -qE '\bpwsh\b' "$LAUNCH_LIB" \
        && pass "S1: run-all-launch.sh routes *.Tests.ps1 to pwsh" \
        || fail "S1: run-all-launch.sh lacks the .Tests.ps1 → pwsh branch"
    grep -qE 'test_\*\.py' "$LAUNCH_LIB" && grep -qE '\buv\b' "$LAUNCH_LIB" \
        && pass "S2: run-all-launch.sh routes test_*.py to uv" \
        || fail "S2: run-all-launch.sh lacks the test_*.py → uv branch"
fi

# S3 (reversed by #2392): discovery enumerates .Tests.ps1 and test_*.py per category.
_disc_src="$RUN_ALL"; [ -f "$LAUNCH_LIB" ] && _disc_src="$_disc_src $LAUNCH_LIB"
# shellcheck disable=SC2086  # intentional split into 1-2 file args
if grep -qE '\$cat"?/\*\.Tests\.ps1' $_disc_src && grep -qE '\$cat"?/test_\*\.py' $_disc_src; then
    pass "S3: discovery enumerates tests/<category>/*.Tests.ps1 and test_*.py"
else
    fail "S3: discovery does not enumerate *.Tests.ps1 / test_*.py under tests/<category>/"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
