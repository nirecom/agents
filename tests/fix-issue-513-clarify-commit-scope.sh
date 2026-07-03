#!/bin/bash
# tests/fix-issue-513-clarify-commit-scope.sh
# Tests: bin/github-issues/clarify-commit-scope.sh
# Tags: clarify-intent, github, issues, wip, board-card, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Whether real gh API calls succeed or fail in the live environment.
# - Whether real wip-set-single.sh session-id resolution works outside test mocks.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Contract (issue #513 — GH reconcile extraction from clarify-intent Completion):
#   clarify-commit-scope.sh --session-id <sid> --plans-dir <dir> --issues <csv>
#                           [--non-github] [--repo <slug>]
#   - Requires AGENTS_CONFIG_DIR; plans-dir hard-validated against the base
#     ($WORKFLOW_PLANS_DIR or $HOME/.workflow-plans) — outside base → exit 2.
#   - --non-github: skip ALL gh calls, exit 0.
#   - Empty --issues (Path C): gh issue create --label "intent:clarified",
#     stdout CREATED:<N>; gh failure → stderr warning + exit 1.
#   - Non-empty --issues (Path B): CLOSED-entry pre-scan via issue-state-check.sh
#     per N — first CLOSED → stdout CLOSED:<N> + exit 2 immediately (no side
#     effects). Then per-N: gh issue edit <N> --add-label "intent:clarified" →
#     wip-set-single.sh → ensure-board-card.sh. WIP exit 2 → stdout RC2 + exit 2.
#
# Pre-implementation RED: each case FAILs with a clear "not yet present"
# message while the target script is missing. They turn GREEN after /write-code.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCS="$AGENTS_DIR/bin/github-issues/clarify-commit-scope.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMP=""

# Mocks write every invocation to a single ordered log ($MOCK_LOG_DIR/calls.log)
# so cross-tool call ORDER (label → wip → board) is observable, plus their own
# per-tool logs for counting. AGENTS_CONFIG_DIR points at a fake root that
# carries the same mocks under bin/github-issues/, so both absolute-path
# ("$AGENTS_CONFIG_DIR/bin/github-issues/...") and PATH-based invocation are
# intercepted.
setup_mock() {
    TMP="$(mktemp -d)"
    FAKE_ACD="$TMP/agents-root"
    mkdir -p "$TMP/mock-bin" "$TMP/plans" "$FAKE_ACD/bin/github-issues"
    export MOCK_LOG_DIR="$TMP"

    # gh mock — records; handles issue create / issue edit --add-label /
    # issue view --json state.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
ARGS="$*"
echo "gh $ARGS" >> "$MOCK_LOG_DIR/calls.log"
echo "gh $ARGS" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$ARGS" in
  issue\ create*)
    if [ "${MOCK_GH_CREATE_RC:-0}" != "0" ]; then
        echo "mock gh issue create failed" >&2
        exit "${MOCK_GH_CREATE_RC:-1}"
    fi
    echo "https://github.com/nirecom/agents/issues/999"
    exit 0
    ;;
  issue\ edit\ *--add-label*)
    exit 0
    ;;
  issue\ view\ *--json\ state*)
    N=$(printf '%s\n' "$ARGS" | grep -oE 'view [0-9]+' | awk '{print $2}')
    STVAR="GH_MOCK_STATE_${N}"
    printf '%s\n' "$(printf '{"state":"%s"}' "${!STVAR:-${GH_MOCK_STATE:-OPEN}}")"
    exit 0
    ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    # issue-state-check.sh mock — stdout is lowercase open|closed|error
    # (matches the real script's contract).
    cat > "$TMP/mock-bin/issue-state-check.sh" <<'MOCKSTATE'
#!/usr/bin/env bash
# skip optional --repo flag
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) shift 2 ;;
        --repo=*) shift ;;
        *) break ;;
    esac
done
N="${1:-}"
echo "issue-state-check $N" >> "$MOCK_LOG_DIR/calls.log"
STVAR="GH_MOCK_STATE_${N}"
ST="${!STVAR:-${GH_MOCK_STATE:-OPEN}}"
case "$ST" in
    OPEN|open)     echo "open";   exit 0 ;;
    CLOSED|closed) echo "closed"; exit 0 ;;
    *)             echo "error";  exit 1 ;;
esac
MOCKSTATE
    chmod +x "$TMP/mock-bin/issue-state-check.sh"

    # wip-set-single.sh mock — exit code from MOCK_WIP_RC (default 0 / SET_OK).
    cat > "$TMP/mock-bin/wip-set-single.sh" <<'MOCKWIP'
#!/usr/bin/env bash
echo "wip-set-single $*" >> "$MOCK_LOG_DIR/calls.log"
echo "wip-set-single $*" >> "$MOCK_LOG_DIR/wip-calls.log"
rc="${MOCK_WIP_RC:-0}"
case "$rc" in
    0) echo "SET_OK" ;;
    2) echo "RC2" ;;
esac
exit "$rc"
MOCKWIP
    chmod +x "$TMP/mock-bin/wip-set-single.sh"

    # ensure-board-card.sh mock — exit code from MOCK_BOARD_RC (default 0).
    cat > "$TMP/mock-bin/ensure-board-card.sh" <<'MOCKBOARD'
#!/usr/bin/env bash
echo "ensure-board-card $*" >> "$MOCK_LOG_DIR/calls.log"
echo "ensure-board-card $*" >> "$MOCK_LOG_DIR/board-calls.log"
exit "${MOCK_BOARD_RC:-0}"
MOCKBOARD
    chmod +x "$TMP/mock-bin/ensure-board-card.sh"

    # Mirror the helper mocks into the fake AGENTS_CONFIG_DIR layout.
    cp "$TMP/mock-bin/issue-state-check.sh" \
       "$TMP/mock-bin/wip-set-single.sh" \
       "$TMP/mock-bin/ensure-board-card.sh" \
       "$FAKE_ACD/bin/github-issues/"

    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$FAKE_ACD"
    # The temp plans dir IS the expected base so the prefix check passes.
    export WORKFLOW_PLANS_DIR="$TMP/plans"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        export PATH="${PATH#"$TMP/mock-bin:"}"
        rm -rf "$TMP" 2>/dev/null || true
    fi
    unset GH_MOCK_STATE GH_MOCK_STATE_101 GH_MOCK_STATE_102 \
          MOCK_WIP_RC MOCK_BOARD_RC MOCK_GH_CREATE_RC MOCK_LOG_DIR \
          WORKFLOW_PLANS_DIR 2>/dev/null || true
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    TMP=""
}

# first_line_no <log-file> <pattern> — line number of first match, empty if none.
first_line_no() {
    grep -nE "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# CCS-1: Path B — --issues "101" OPEN → side effects in order label → wip → board, exit 0
if [ -f "$CCS" ]; then
    setup_mock
    export GH_MOCK_STATE_101="OPEN"
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101" 2>/dev/null)
    RC=$?
    LBL_LN=$(first_line_no "$TMP/calls.log" "gh issue edit 101 .*add-label")
    WIP_LN=$(first_line_no "$TMP/calls.log" "wip-set-single .*101")
    BOARD_LN=$(first_line_no "$TMP/calls.log" "ensure-board-card .*101")
    if [ "$RC" -eq 0 ] \
        && [ -n "$LBL_LN" ] && [ -n "$WIP_LN" ] && [ -n "$BOARD_LN" ] \
        && [ "$LBL_LN" -lt "$WIP_LN" ] && [ "$WIP_LN" -lt "$BOARD_LN" ]; then
        pass "CCS-1: issue 101 OPEN → label → wip → board in order, exit 0"
    else
        fail "CCS-1: expected ordered label→wip→board exit=0; got rc=$RC lbl_ln='$LBL_LN' wip_ln='$WIP_LN' board_ln='$BOARD_LN'"
    fi
    teardown_mock
else
    fail "CCS-1: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-2: Path B — first entry CLOSED in "101,102" → stdout CLOSED:101, exit 2,
# stop at first: NO label/wip/board side effects for either issue.
if [ -f "$CCS" ]; then
    setup_mock
    export GH_MOCK_STATE_101="CLOSED"
    export GH_MOCK_STATE_102="OPEN"
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101,102" 2>/dev/null)
    RC=$?
    CALLS=$(cat "$TMP/calls.log" 2>/dev/null || true)
    if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "CLOSED:101" \
        && ! echo "$CALLS" | grep -q "add-label" \
        && ! echo "$CALLS" | grep -q "wip-set-single" \
        && ! echo "$CALLS" | grep -q "ensure-board-card"; then
        pass "CCS-2: 101 CLOSED (first of 101,102) → stdout CLOSED:101, exit 2, zero side effects"
    else
        fail "CCS-2: expected CLOSED:101 exit=2 no side effects; got rc=$RC out='$OUT' calls='$CALLS'"
    fi
    teardown_mock
else
    fail "CCS-2: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-2b: Path B — CLOSED pre-scan precedes side effects: "101,102" with 102
# CLOSED → stdout CLOSED:102, exit 2, and no side effects fired for 101 either.
if [ -f "$CCS" ]; then
    setup_mock
    export GH_MOCK_STATE_101="OPEN"
    export GH_MOCK_STATE_102="CLOSED"
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101,102" 2>/dev/null)
    RC=$?
    CALLS=$(cat "$TMP/calls.log" 2>/dev/null || true)
    if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "CLOSED:102" \
        && ! echo "$CALLS" | grep -q "add-label" \
        && ! echo "$CALLS" | grep -q "wip-set-single"; then
        pass "CCS-2b: 102 CLOSED (second of 101,102) → CLOSED:102 exit 2, pre-scan blocks 101's side effects too"
    else
        fail "CCS-2b: expected CLOSED:102 exit=2 no side effects for 101; got rc=$RC out='$OUT' calls='$CALLS'"
    fi
    teardown_mock
else
    fail "CCS-2b: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-3: Path B — issue 101 OPEN, wip exit 2 → stdout contains RC2, exit 2
if [ -f "$CCS" ]; then
    setup_mock
    export GH_MOCK_STATE_101="OPEN"
    export MOCK_WIP_RC=2
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101" 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "RC2"; then
        pass "CCS-3: wip exit 2 → stdout RC2, exit 2"
    else
        fail "CCS-3: expected RC2 exit=2; got rc=$RC out='$OUT'"
    fi
    teardown_mock
else
    fail "CCS-3: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-4: Path C — --issues "" → gh issue create with intent:clarified label;
# stdout CREATED:<N>; exit 0
if [ -f "$CCS" ]; then
    setup_mock
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "" 2>/dev/null)
    RC=$?
    GH_CALLS=$(cat "$TMP/gh-calls.log" 2>/dev/null || true)
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qE "CREATED:[0-9]+" \
        && echo "$GH_CALLS" | grep -q "issue create" \
        && echo "$GH_CALLS" | grep -q "intent:clarified"; then
        pass "CCS-4: empty --issues → gh issue create (intent:clarified), stdout CREATED:<N>, exit 0"
    else
        fail "CCS-4: expected CREATED:<N> exit=0 gh-create with label; got rc=$RC out='$OUT' gh='$GH_CALLS'"
    fi
    teardown_mock
else
    fail "CCS-4: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-5: Path C — --issues "" + gh create fails → stderr warning + exit 1
if [ -f "$CCS" ]; then
    setup_mock
    export MOCK_GH_CREATE_RC=1
    STDERR=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "" 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 1 ] && [ -n "$STDERR" ]; then
        pass "CCS-5: gh issue create fails → stderr warning, exit 1"
    else
        fail "CCS-5: expected exit=1 stderr; got rc=$RC stderr='$STDERR'"
    fi
    teardown_mock
else
    fail "CCS-5: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-6: --non-github → zero gh invocations, exit 0
if [ -f "$CCS" ]; then
    setup_mock
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101" \
        --non-github 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -s "$TMP/gh-calls.log" ]; then
        pass "CCS-6: --non-github → zero gh invocations, exit 0"
    else
        fail "CCS-6: expected exit=0 no-gh; got rc=$RC gh-log='$(cat "$TMP/gh-calls.log" 2>/dev/null || true)'"
    fi
    teardown_mock
else
    fail "CCS-6: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-7: --plans-dir outside base (existing dir, so cd-normalization succeeds
# and the prefix check itself must reject) → stderr error + exit 2
if [ -f "$CCS" ]; then
    setup_mock
    mkdir -p "$TMP/outside"
    STDERR=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/outside" \
        --issues "101" 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -eq 2 ] && [ -n "$STDERR" ]; then
        pass "CCS-7: --plans-dir outside base → stderr error, exit 2"
    else
        fail "CCS-7: expected exit=2 stderr; got rc=$RC stderr='$STDERR'"
    fi
    teardown_mock
else
    fail "CCS-7: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-8: Path B — "101,102" both OPEN → label+wip+board fire for exactly 101
# and 102 (2 each, no other issue numbers)
if [ -f "$CCS" ]; then
    setup_mock
    export GH_MOCK_STATE_101="OPEN"
    export GH_MOCK_STATE_102="OPEN"
    OUT=$(run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101,102" 2>/dev/null)
    RC=$?
    GH_CALLS=$(cat "$TMP/gh-calls.log" 2>/dev/null || true)
    WIP_CALLS=$(cat "$TMP/wip-calls.log" 2>/dev/null || true)
    BOARD_CALLS=$(cat "$TMP/board-calls.log" 2>/dev/null || true)
    GH_LABEL_COUNT=$(echo "$GH_CALLS" | grep -c "add-label" || true)
    WIP_COUNT=$(echo "$WIP_CALLS" | grep -c "wip-set-single" || true)
    BOARD_COUNT=$(echo "$BOARD_CALLS" | grep -c "ensure-board-card" || true)
    if [ "$RC" -eq 0 ] \
        && [ "$GH_LABEL_COUNT" -eq 2 ] && [ "$WIP_COUNT" -eq 2 ] && [ "$BOARD_COUNT" -eq 2 ] \
        && echo "$WIP_CALLS" | grep -q "101" && echo "$WIP_CALLS" | grep -q "102" \
        && echo "$BOARD_CALLS" | grep -q "101" && echo "$BOARD_CALLS" | grep -q "102"; then
        pass "CCS-8: issues 101,102 OPEN → label+wip+board exactly twice, both issues covered"
    else
        fail "CCS-8: expected 2 each of label/wip/board for 101+102; got rc=$RC labels=$GH_LABEL_COUNT wip=$WIP_COUNT board=$BOARD_COUNT"
    fi
    teardown_mock
else
    fail "CCS-8: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

# CCS-9: missing AGENTS_CONFIG_DIR → stderr error + non-zero exit
if [ -f "$CCS" ]; then
    setup_mock
    STDERR=$(env -u AGENTS_CONFIG_DIR run_with_timeout 15 bash "$CCS" \
        --session-id "test-sid" \
        --plans-dir "$TMP/plans" \
        --issues "101" 2>&1 >/dev/null)
    RC=$?
    if [ "$RC" -ne 0 ] && [ -n "$STDERR" ]; then
        pass "CCS-9: missing AGENTS_CONFIG_DIR → stderr error, non-zero exit"
    else
        fail "CCS-9: expected non-zero exit with stderr; got rc=$RC stderr='$STDERR'"
    fi
    teardown_mock
else
    fail "CCS-9: clarify-commit-scope.sh not yet present (expected RED before /write-code)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
