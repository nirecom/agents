#!/bin/bash
# tests/fix-issue-449-tracking-guard/d-series.sh
# Tests: bin/github-issues/check-closes-issues-nonempty.sh, hooks/lib/parse-closes-issues.js
# Tags: workflow, clarify-intent, planning, github, issues, scope:issue-specific
#
# D-series — check-closes-issues-nonempty.sh (issue #449) + session-dedup
# extensions (D11–D16). Moved verbatim from tests/fix-issue-449-tracking-guard.sh
# when the file crossed the 500-line HARD cap (rules/coding/file-split.md).
#
# Guard script that verifies the session's intent.md has a non-empty
# ## closes_issues section. Called by clarify-intent's Completion section
# to prevent the workflow from proceeding with an empty tracking list.
# Uses hooks/lib/parse-closes-issues.js as the SSOT parser (via node -e).

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$CHECK" ]; then
    echo "FAIL: precondition missing — bin/github-issues/check-closes-issues-nonempty.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# --- D1: single closes_issues entry → rc=0, stderr empty
setup_tmp
mk_state_check_mock
export GH_MOCK_STATE="OPEN"
printf '## closes_issues\n- 449\n' > "$TMP/intent.md"
STDERR=$(run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$STDERR" ]; then
    pass "D1: single entry → rc=0, stderr empty"
else
    fail "D1: rc=$RC stderr=$STDERR"
fi
rm_state_check_mock
teardown_tmp

# --- D2: empty closes_issues section → rc=1, stderr mentions /issue-create
setup_tmp
printf '## closes_issues\n(empty)\n' > "$TMP/intent.md"
STDERR=$(run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$STDERR" | grep -q "Run /issue-create"; then
    pass "D2: empty section → rc=1, stderr mentions Run /issue-create"
else
    fail "D2: rc=$RC stderr=$STDERR"
fi
teardown_tmp

# --- D3: bare header at EOF → rc=1
setup_tmp
printf '## closes_issues\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "D3: bare header at EOF → rc=1"
else
    fail "D3: rc=$RC"
fi
teardown_tmp

# --- D4: no closes_issues section → rc=1
setup_tmp
printf '# Some Intent\n\n## Other Section\n- 999\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "D4: no closes_issues section → rc=1"
else
    fail "D4: rc=$RC"
fi
teardown_tmp

# --- D5: --non-github flag skips check even with empty section → rc=0
setup_tmp
printf '## closes_issues\n(empty)\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" --non-github "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "D5: --non-github → rc=0 (skip regardless of content)"
else
    fail "D5: rc=$RC"
fi
teardown_tmp

# --- D6: multiple closes_issues entries → rc=0
setup_tmp
mk_state_check_mock
export GH_MOCK_STATE="OPEN"
printf '## closes_issues\n- 449\n- 450\n' > "$TMP/intent.md"
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "D6: multiple entries → rc=0"
else
    fail "D6: rc=$RC"
fi
rm_state_check_mock
teardown_tmp

# --- D7: nonexistent path → rc=1, stderr mentions "intent.md not found"
setup_tmp
STDERR=$(run_with_timeout 15 bash "$CHECK" "$TMP/does-not-exist.md" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$STDERR" | grep -q "intent.md not found"; then
    pass "D7: nonexistent path → rc=1, stderr mentions intent.md not found"
else
    fail "D7: rc=$RC stderr=$STDERR"
fi
teardown_tmp

# --- D8: no arguments → rc=1, stderr mentions "Usage:"
STDERR=$(run_with_timeout 15 bash "$CHECK" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$STDERR" | grep -q "Usage:"; then
    pass "D8: no arguments → rc=1, stderr mentions Usage:"
else
    fail "D8: rc=$RC stderr=$STDERR"
fi

# --- D9: section-boundary integrity — `- 999` under ## Other not counted
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Agreed Requirements

## closes_issues
(empty)

## Other
- 999
EOF
run_with_timeout 15 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "D9: section-boundary integrity (entries under ## Other ignored) → rc=1"
else
    fail "D9: rc=$RC (parser may be ignoring ## boundary)"
fi
teardown_tmp

# --- D10: shell-injection isolation
setup_tmp
INJECT_FILE="$TMP/D10_INJECT_$$"
# Construct a literal filename containing $(touch ...) — must not execute.
FNAME='intent_$(touch '"$INJECT_FILE"').md'
touch "$TMP/$FNAME"
run_with_timeout 15 bash "$CHECK" "$TMP/$FNAME" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$INJECT_FILE" ]; then
    pass "D10: shell-injection isolation (rc=$RC, inject file not created)"
else
    fail "D10: rc=$RC inject_exists=$([ -f "$INJECT_FILE" ] && echo yes || echo no)"
fi
rm -f "$INJECT_FILE" 2>/dev/null
teardown_tmp


# ============================================================================
# D-series extensions for session-dedup feature (D11–D16)
#
# D11 (task D8): closes_issues set + issue CLOSED → exits 2 + stderr "CLOSED"
# D12 (task D9): closes_issues set + all OPEN → exits 0
# D13 (task D10): --non-github flag → skips CLOSED check (exits 0)
# D14 (task D11): issue-state-check returns error → warn-continue (exits 0)
# D15 (task D12): clarify-intent SKILL.md Step 0 guard contains GUARD_RC==2 branch
# D16 (task D13): clarify-intent SKILL.md Step 0 guard GUARD_RC==2 does NOT invoke issue-create
#
# Runtime tests D11–D14 require both check-closes-issues-nonempty.sh AND
# issue-state-check.sh implementations. Skip gracefully if state-check missing.
# ============================================================================

# --- D11: closes_issues set + issue CLOSED → exits 2 + stderr contains "CLOSED"
if [ -f "$STATE_CHECK" ]; then
    setup_tmp
    mk_state_check_mock
    export GH_MOCK_STATE_449="CLOSED"
    printf '## closes_issues\n- 449\n' > "$TMP/intent.md"
    STDERR=$(run_with_timeout 30 bash "$CHECK" "$TMP/intent.md" 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 2 ] && echo "$STDERR" | grep -q "CLOSED"; then
        pass "D11: closes_issues set + #449 CLOSED → exit 2, stderr mentions CLOSED"
    else
        fail "D11: rc=$RC stderr=$STDERR"
    fi
    rm_state_check_mock
    teardown_tmp
else
    skip "D11: issue-state-check.sh not yet present (pre-implementation)"
fi

# --- D12: closes_issues set + all OPEN → exits 0
if [ -f "$STATE_CHECK" ]; then
    setup_tmp
    mk_state_check_mock
    export GH_MOCK_STATE="OPEN"
    printf '## closes_issues\n- 449\n- 450\n' > "$TMP/intent.md"
    run_with_timeout 30 bash "$CHECK" "$TMP/intent.md" >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "D12: closes_issues set + all OPEN → exit 0"
    else
        fail "D12: rc=$RC"
    fi
    rm_state_check_mock
    teardown_tmp
else
    skip "D12: issue-state-check.sh not yet present (pre-implementation)"
fi

# --- D13: --non-github flag → skips CLOSED check (exits 0 even if mock would say CLOSED)
if [ -f "$STATE_CHECK" ]; then
    setup_tmp
    mk_state_check_mock
    export GH_MOCK_STATE="CLOSED"
    printf '## closes_issues\n- 449\n' > "$TMP/intent.md"
    run_with_timeout 30 bash "$CHECK" --non-github "$TMP/intent.md" >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "D13: --non-github flag skips CLOSED check (rc=0 even with CLOSED mock)"
    else
        fail "D13: rc=$RC (expected 0)"
    fi
    rm_state_check_mock
    teardown_tmp
else
    skip "D13: issue-state-check.sh not yet present (pre-implementation)"
fi

# --- D14: issue-state-check returns error → warn-continue (exits 0)
if [ -f "$STATE_CHECK" ]; then
    setup_tmp
    mk_state_check_mock
    export GH_MOCK_FAIL=1
    printf '## closes_issues\n- 449\n' > "$TMP/intent.md"
    STDERR=$(run_with_timeout 30 bash "$CHECK" "$TMP/intent.md" 2>&1 >/dev/null)
    RC=$?
    # Warn-continue: rc=0 (do not block on probe error); stderr may carry a warning.
    if [ "$RC" -eq 0 ]; then
        pass "D14: issue-state-check error → warn-continue (rc=0)"
    else
        fail "D14: rc=$RC stderr=$STDERR (expected warn-continue rc=0)"
    fi
    rm_state_check_mock
    teardown_tmp
else
    skip "D14: issue-state-check.sh not yet present (pre-implementation)"
fi

# --- D15: clarify-intent SKILL.md Step 0 guard contains GUARD_RC==2 branch (static grep)
if [ -f "$CLARIFY_SKILL" ]; then
    if grep -qE 'GUARD_RC[[:space:]]*(==|-eq)[[:space:]]*2' "$CLARIFY_SKILL"; then
        pass "D15: clarify-intent SKILL.md Step 0 guard contains GUARD_RC==2 branch"
    else
        skip "D15: GUARD_RC==2 branch not yet in clarify-intent SKILL.md (pre-implementation)"
    fi
else
    skip "D15: skills/clarify-intent/SKILL.md not present"
fi

# --- D16: clarify-intent SKILL.md GUARD_RC==2 branch does NOT invoke issue-create
# Heuristic: extract the lines following 'GUARD_RC == 2' (or '-eq 2') until next blank line
# or next conditional, and ensure no 'issue-create' literal appears in that block.
if [ -f "$CLARIFY_SKILL" ]; then
    # Find the line range of the GUARD_RC==2 branch.
    GUARD_LINE=$(grep -nE 'GUARD_RC[[:space:]]*(==|-eq)[[:space:]]*2' "$CLARIFY_SKILL" | head -1 | cut -d: -f1)
    if [ -n "$GUARD_LINE" ]; then
        # Inspect the next 30 lines after the guard for issue-create invocation.
        BLOCK=$(awk -v start="$GUARD_LINE" 'NR>=start && NR<start+30' "$CLARIFY_SKILL")
        if echo "$BLOCK" | grep -qE '/?issue-create\b'; then
            fail "D16: GUARD_RC==2 branch invokes issue-create (regression — must NOT auto-create)"
        else
            pass "D16: GUARD_RC==2 branch does NOT invoke issue-create"
        fi
    else
        skip "D16: GUARD_RC==2 branch not yet present (pre-implementation)"
    fi
else
    skip "D16: skills/clarify-intent/SKILL.md not present"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
