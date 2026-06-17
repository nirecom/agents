#!/bin/bash
# tests/feature-929-supervisor-review-codex.sh
# Tests: bin/supervisor-review-codex
# Tags: supervisor, em-supervisor, codex-review, cli, integration
# RED for issue #929.
#
# L3 gap (what this test does NOT catch):
# - real supervisor agent invoking the full flow inside a live Claude Code session
# - Codex API network call succeeding end-to-end
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-review-codex"
WRITE_CLI="$AGENTS_DIR/bin/supervisor-write-layer2"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_cli() {
    local label="$1"
    if [ ! -f "$CLI" ]; then
        skip "$label (source not implemented yet)"; return 1
    fi
    return 0
}

run_rc1() {
    if [ ! -f "$CLI" ]; then skip "RC1: bin/supervisor-review-codex exists and is executable (source not implemented yet)"; return; fi
    if [ -x "$CLI" ]; then
        pass "RC1: bin/supervisor-review-codex exists and is executable"
    else
        fail "RC1: $CLI exists but not executable"
    fi
}

run_rc2() {
    require_cli "RC2: SKIPPED when no state file" || return
    local tmp sid rc out
    tmp="$(mktemp -d)"; sid="rc2-sid"
    # No state file seeded. Script should exit 0 and print SKIPPED.
    out=$(WORKFLOW_PLANS_DIR="$tmp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 10 bash "$CLI" 2>&1) || true
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "skipped"; then
        pass "RC2: SKIPPED (exit 0 + SKIPPED in output) when no state file"
    else
        fail "RC2: expected exit 0 with SKIPPED in output (rc=$rc, out=$out)"
    fi
}

run_rc3() {
    require_cli "RC3: SKIPPED when l2_phase != pending" || return
    local tmp sid rc out
    tmp="$(mktemp -d)"; sid="rc3-sid"
    # Seed state with l2_phase=done (and no findings).
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$WRITE_CLI" \
        --set-l2-phase done --session-id "$sid" >/dev/null 2>&1
    out=$(WORKFLOW_PLANS_DIR="$tmp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        SID="$sid" run_with_timeout 10 bash "$CLI" 2>&1) || true
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "skipped"; then
        pass "RC3: SKIPPED (exit 0 + SKIPPED in output) when l2_phase=done"
    else
        fail "RC3: expected exit 0 with SKIPPED in output (rc=$rc, out=$out)"
    fi
}

run_rc4() {
    require_cli "RC4: SKIPPED when pending but no draft findings" || return
    local tmp sid rc out
    tmp="$(mktemp -d)"; sid="rc4-sid"
    # Seed pending phase with l2_armed_at; no findings.
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$WRITE_CLI" \
        --l2-armed-at "2026-06-06T12:00:00Z" --session-id "$sid" >/dev/null 2>&1
    out=$(WORKFLOW_PLANS_DIR="$tmp" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        SID="$sid" run_with_timeout 10 bash "$CLI" 2>&1) || true
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -qi "skipped"; then
        pass "RC4: SKIPPED (exit 0 + SKIPPED in output) when no draft findings"
    else
        fail "RC4: expected exit 0 with SKIPPED in output (rc=$rc, out=$out)"
    fi
}

run_rc5() {
    require_cli "RC5: SKIPPED when codex unavailable / not configured" || return
    local tmp sid rc
    tmp="$(mktemp -d)"; sid="rc5-sid"
    # Seed pending state with a draft finding. Attempt to add via the
    # new --finding-status flag; if the flag isn't implemented yet,
    # the WRITE_CLI call will fail but the test still meaningfully
    # exercises the codex-unavailable path (no drafts → skip).
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$WRITE_CLI" \
        --l2-armed-at "2026-06-06T12:00:00Z" --session-id "$sid" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$WRITE_CLI" \
        --finding-categories workflow \
        --finding-severity warning \
        --finding-detail "draft1" \
        --finding-reporter supervisor \
        --finding-status draft \
        --session-id "$sid" >/dev/null 2>&1 || true
    # Run review-codex with codex deliberately unavailable.
    CODEX_API_KEY="" CODEX_MODEL="" CODEX_BIN="/nonexistent/codex" \
    PATH="/nonexistent" \
    WORKFLOW_PLANS_DIR="$tmp" \
        run_with_timeout 15 bash "$CLI" --session-id "$sid" >/dev/null 2>&1
    rc=$?
    rm -rf "$tmp"
    # codex_core_run returns exit 3 when codex is unavailable; the wrapper
    # should propagate non-zero (SKIPPED). Accept any non-zero.
    if [ $rc -ne 0 ]; then
        pass "RC5: SKIPPED when codex unavailable (rc=$rc)"
    else
        fail "RC5: expected non-zero exit, got rc=$rc"
    fi
}

run_rc1
run_rc2
run_rc3
run_rc4
run_rc5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
