#!/usr/bin/env bash
# Tests: tests/run-all.sh
# Tags: bin, tests, pwsh, scope:issue-specific, TL2
# run-all.sh dispatches *.Tests.ps1 to pwsh, not bash (issue #2007 / #1765).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ALL="$AGENTS_DIR/tests/run-all.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$RUN_ALL" ] || { echo "SKIP: tests/run-all.sh not present"; exit 77; }

# S1: launch() contains a .Tests.ps1 dispatch case.
if grep -qE '\.Tests\.ps1' "$RUN_ALL"; then
    pass "S1: launch() contains a .Tests.ps1 pattern"
else
    fail "S1: launch() has no .Tests.ps1 pattern — a *.Tests.ps1 positional arg would run under bash"
fi

# S2: the dispatch routes to pwsh.
if grep -qE '\bpwsh\b' "$RUN_ALL"; then
    pass "S2: launch() references pwsh for the dispatch"
else
    fail "S2: launch() contains no pwsh reference"
fi

# S3: the auto-discovery glob still only picks *.sh (avoids double-running alongside .sh wrappers).
if grep -qE '\*\.sh' "$RUN_ALL" && ! grep -qE 'TESTS_DIR.*\*\.Tests\.ps1\|for f.*Tests\.ps1' "$RUN_ALL"; then
    pass "S3: auto-discovery glob is *.sh only — no accidental double-discovery of .Tests.ps1"
else
    fail "S3: auto-discovery glob may have changed to include .Tests.ps1 directly"
fi

# B1: behavioural — a *.Tests.ps1 passed as positional arg exits 77 when pwsh is absent.
if ! command -v pwsh >/dev/null 2>&1; then
    TMPDIR_FX="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_FX"' EXIT
    export CLAUDE_WORKFLOW_DIR="$TMPDIR_FX/workflow"
    export WORKFLOW_PLANS_DIR="$TMPDIR_FX/plans"
    mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

    PS1_FILE="$TMPDIR_FX/noop.Tests.ps1"
    printf 'Describe "noop" { It "passes" { $true | Should -BeTrue } }\n' >"$PS1_FILE"

    out="$(bash "$RUN_ALL" "$PS1_FILE" 2>&1)"
    rc=$?
    if echo "$out" | grep -qiE 'skip.*pwsh|pwsh.*not.*path' && [ "$rc" = "0" ]; then
        pass "B1: positional .Tests.ps1 skips (exit 77) when pwsh not on PATH"
    else
        fail "B1: expected SKIP + rc=0 for .Tests.ps1 without pwsh — got rc=$rc output=$(echo "$out" | tail -3)"
    fi
else
    echo "INFO: B1 skipped — pwsh is on PATH; behavioural skip-gate not verifiable"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
