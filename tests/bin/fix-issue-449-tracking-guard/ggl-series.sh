#!/bin/bash
# tests/fix-issue-449-tracking-guard/ggl-series.sh
# Tests: bin/github-issues/clarify-guard-loop.sh, bin/github-issues/check-closes-issues-nonempty.sh
# Tags: workflow, clarify-intent, guard-loop, github, issues, scope:issue-specific
#
# GGL-series — clarify-guard-loop.sh (#1198): CI-C0 tracking-issue guard wrapper.
#
# Pre-implementation RED: each case FAILs with a clear "not yet present"
# message while bin/github-issues/clarify-guard-loop.sh is missing. They turn
# GREEN once /write-code lands the script.
#
# Contract: --session-id <sid> --plans-dir <dir> [--non-github]; requires
# AGENTS_CONFIG_DIR; plans-dir hard-validated against the expected base
# ($WORKFLOW_PLANS_DIR or $HOME/.workflow-plans) — outside base → exit 2;
# wraps check-closes-issues-nonempty.sh (SSOT — no closes_issues re-parse);
# owns the GUARD_ATTEMPT counter file <plans-dir>/<sid>-guard-attempt.tmp;
# stdout is a single decision token:
#   PROCEED | NEED_ISSUE | RETRY_EXHAUSTED | CLOSED_ENTRY
#
# Tests export WORKFLOW_PLANS_DIR="$TMP" so the temp plans dir IS the expected
# base (the prefix check passes); intent.md is written to the contract path
# <plans-dir>/<sid>-intent.md.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# GGL-1: closes_issues non-empty + all OPEN → stdout is exactly PROCEED, exit 0
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    mk_state_check_mock
    export GH_MOCK_STATE="OPEN"
    printf '## closes_issues\n- 1234\n' > "$TMP/test-sid-intent.md"
    OUT=$(WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "PROCEED" ]; then
        pass "GGL-1: non-empty closes_issues + OPEN → stdout=PROCEED, exit 0"
    else
        fail "GGL-1: expected stdout=PROCEED exit=0; got rc=$RC out='$OUT'"
    fi
    rm_state_check_mock
    teardown_tmp
else
    fail "GGL-1: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

# GGL-2: closes_issues empty → stdout NEED_ISSUE, exit 0; counter file created with value 1
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    printf '## closes_issues\n(empty)\n' > "$TMP/test-sid-intent.md"
    OUT=$(WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" 2>/dev/null)
    RC=$?
    COUNTER_FILE="$TMP/test-sid-guard-attempt.tmp"
    COUNTER_VAL=""
    if [ -f "$COUNTER_FILE" ]; then COUNTER_VAL=$(cat "$COUNTER_FILE"); fi
    if [ "$RC" -eq 0 ] && [ "$OUT" = "NEED_ISSUE" ] && [ "$COUNTER_VAL" = "1" ]; then
        pass "GGL-2: empty closes_issues → stdout=NEED_ISSUE, exit 0, counter=1"
    else
        fail "GGL-2: expected NEED_ISSUE exit=0 counter=1; got rc=$RC out='$OUT' counter='$COUNTER_VAL'"
    fi
    teardown_tmp
else
    fail "GGL-2: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

# GGL-3: counter persistence across two real invocations → second call
# emits NEED_ISSUE again and the on-disk counter reaches 2.
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    printf '## closes_issues\n(empty)\n' > "$TMP/test-sid-intent.md"
    WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" >/dev/null 2>&1
    OUT=$(WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" 2>/dev/null)
    RC=$?
    COUNTER_FILE="$TMP/test-sid-guard-attempt.tmp"
    COUNTER_VAL=""
    if [ -f "$COUNTER_FILE" ]; then COUNTER_VAL=$(cat "$COUNTER_FILE"); fi
    if [ "$RC" -eq 0 ] && [ "$OUT" = "NEED_ISSUE" ] && [ "$COUNTER_VAL" = "2" ]; then
        pass "GGL-3: two invocations → NEED_ISSUE, counter persisted and incremented to 2"
    else
        fail "GGL-3: expected NEED_ISSUE exit=0 counter=2 after 2 calls; got rc=$RC out='$OUT' counter='$COUNTER_VAL'"
    fi
    teardown_tmp
else
    fail "GGL-3: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

# GGL-4: third call (counter already at cap=2) → stdout is RETRY_EXHAUSTED, exit 0
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    printf '## closes_issues\n(empty)\n' > "$TMP/test-sid-intent.md"
    COUNTER_FILE="$TMP/test-sid-guard-attempt.tmp"
    echo "2" > "$COUNTER_FILE"
    OUT=$(WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "RETRY_EXHAUSTED" ]; then
        pass "GGL-4: counter at cap=2 → stdout=RETRY_EXHAUSTED, exit 0"
    else
        fail "GGL-4: expected RETRY_EXHAUSTED exit=0; got rc=$RC out='$OUT'"
    fi
    teardown_tmp
else
    fail "GGL-4: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

# GGL-5: closes_issues non-empty + one CLOSED → stdout is CLOSED_ENTRY, exit 0
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    mk_state_check_mock
    export GH_MOCK_STATE="CLOSED"
    printf '## closes_issues\n- 1234\n' > "$TMP/test-sid-intent.md"
    OUT=$(WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "CLOSED_ENTRY" ]; then
        pass "GGL-5: closes_issues non-empty + CLOSED issue → stdout=CLOSED_ENTRY, exit 0"
    else
        fail "GGL-5: expected CLOSED_ENTRY exit=0; got rc=$RC out='$OUT'"
    fi
    rm_state_check_mock
    teardown_tmp
else
    fail "GGL-5: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

# GGL-6: --plans-dir outside the expected base → stderr error + exit 2
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    OUTSIDE_DIR="$TMP/outside-plans-dir-xyz"
    mkdir -p "$OUTSIDE_DIR"
    # Base is $TMP/base (≠ OUTSIDE_DIR); the dir exists so `cd && pwd`
    # normalization succeeds — the prefix check itself must reject it.
    mkdir -p "$TMP/base"
    STDERR=$(WORKFLOW_PLANS_DIR="$TMP/base" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$OUTSIDE_DIR" 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 2 ] && [ -n "$STDERR" ]; then
        pass "GGL-6: --plans-dir outside allowed base → stderr error, exit 2"
    else
        fail "GGL-6: expected exit=2 with stderr; got rc=$RC stderr='$STDERR'"
    fi
    teardown_tmp
else
    fail "GGL-6: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

# GGL-7: missing AGENTS_CONFIG_DIR env → stderr error + non-zero exit
if [ -x "$GUARD_LOOP" ]; then
    setup_tmp
    printf '## closes_issues\n- 1234\n' > "$TMP/test-sid-intent.md"
    STDERR=$(env -u AGENTS_CONFIG_DIR WORKFLOW_PLANS_DIR="$TMP" run_with_timeout 15 bash "$GUARD_LOOP" \
        --session-id "test-sid" \
        --plans-dir "$TMP" 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -ne 0 ] && [ -n "$STDERR" ]; then
        pass "GGL-7: missing AGENTS_CONFIG_DIR → stderr error, non-zero exit"
    else
        fail "GGL-7: expected non-zero exit with stderr; got rc=$RC stderr='$STDERR'"
    fi
    teardown_tmp
else
    fail "GGL-7: clarify-guard-loop.sh not yet present (expected RED before /write-code)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
