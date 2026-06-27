#!/bin/bash
# tests/feature-720-supervisor-l3-cli.sh
# Tests: bin/supervisor-write-audit
# Tags: supervisor, em-supervisor, cli, layer3, scope:issue-specific
# L3 gap (what this test does NOT catch):
#   Exercises the CLI as a child process against a temp WORKFLOW_PLANS_DIR.
#   Does not verify integration with a real Stop-event-driven supervisor-guard
#   pipeline — a live claude -p session is needed for that.
# RED for issue #720.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
    _TMPCONV() { cygpath -m "$1"; }
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
    _TMPCONV() { printf '%s' "$1"; }
fi

CLI="$AGENTS_DIR/bin/supervisor-write-audit"
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

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

read_field() {
    local tmp="$1" sid="$2" path="$3"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
const parts = '$path'.split('.');
let cur = st;
for (const p of parts) { if (cur == null) break; cur = cur[p]; }
process.stdout.write(JSON.stringify(cur));
" 2>/dev/null
    )
}

invoke_cli() {
    local tmp="$1"; shift
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI" "$@" >/dev/null 2>&1
    )
}

run_c1() {
    require_source "$CLI" "C1: --audit-armed-at sets layer3.audit_armed_at" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c1sid"
    invoke_cli "$tmp" --audit-armed-at "2026-06-06T12:00:00Z" --session-id "$sid"
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"2026-06-06T12:00:00Z\"" ]; then
        pass "C1: --audit-armed-at sets layer3.audit_armed_at"
    else
        fail "C1: --audit-armed-at sets layer3.audit_armed_at (rc=$rc, val=$val)"
    fi
}

run_c2() {
    require_source "$CLI" "C2: --set-audit-phase pending sets layer3.audit_phase" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c2sid"
    invoke_cli "$tmp" --set-audit-phase pending --session-id "$sid"
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"pending\"" ]; then
        pass "C2: --set-audit-phase pending sets layer3.audit_phase"
    else
        fail "C2: --set-audit-phase pending sets layer3.audit_phase (rc=$rc, val=$val)"
    fi
}

run_c3() {
    require_source "$CLI" "C3: --set-audit-verdict BLOCK sets layer3.audit_verdict" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c3sid"
    invoke_cli "$tmp" --set-audit-verdict BLOCK --session-id "$sid"
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_verdict")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"BLOCK\"" ]; then
        pass "C3: --set-audit-verdict BLOCK sets layer3.audit_verdict"
    else
        fail "C3: --set-audit-verdict BLOCK sets layer3.audit_verdict (rc=$rc, val=$val)"
    fi
}

run_c4() {
    require_source "$CLI" "C4: --last-run-at sets layer3.audit_last_run_at" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c4sid"
    invoke_cli "$tmp" --last-run-at "2026-06-06T11:00:00Z" --session-id "$sid"
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_last_run_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"2026-06-06T11:00:00Z\"" ]; then
        pass "C4: --last-run-at sets layer3.audit_last_run_at"
    else
        fail "C4: --last-run-at sets layer3.audit_last_run_at (rc=$rc, val=$val)"
    fi
}

run_c5() {
    require_source "$CLI" "C5: --clear-audit-armed-at nulls layer3.audit_armed_at" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c5sid"
    invoke_cli "$tmp" --audit-armed-at "2026-06-06T12:00:00Z" --session-id "$sid"
    invoke_cli "$tmp" --clear-audit-armed-at --session-id "$sid"
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_armed_at")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "null" ]; then
        pass "C5: --clear-audit-armed-at nulls layer3.audit_armed_at"
    else
        fail "C5: --clear-audit-armed-at nulls layer3.audit_armed_at (rc=$rc, val=$val)"
    fi
}

run_c6() {
    require_source "$CLI" "C6: unknown flag exits non-zero" || return
    local tmp rc
    tmp="$(mktemp -d)"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI" --not-a-real-flag value --session-id c6sid >/dev/null 2>&1
    )
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "C6: unknown flag exits non-zero"
    else
        fail "C6: unknown flag exits non-zero (rc=$rc)"
    fi
}

run_c7() {
    require_source "$CLI" "C7: missing --session-id exits non-zero" || return
    local tmp rc
    tmp="$(mktemp -d)"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node "$CLI" --audit-armed-at "2026-06-06T12:00:00Z" >/dev/null 2>&1
    )
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        pass "C7: missing --session-id exits non-zero"
    else
        fail "C7: missing --session-id exits non-zero (rc=$rc)"
    fi
}

run_c8() {
    require_source "$CLI" "C8: --set-audit-phase done resets audit_retry_count to 0" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c8sid"
    # Bump retry count first via CLI (if --increment supported), else write via writer module.
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
// Seed retry count > 0 directly via writeAuditState if exported; otherwise
// fall back to writing the state file manually with a non-zero audit_retry_count.
if (typeof w.writeAuditState === 'function') {
  w.writeAuditState('$sid', { audit_retry_count: 1, audit_phase: 'pending' });
} else {
  const fs = require('fs'); const path = require('path');
  const { createEmptyState } = require('$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js');
  const plansDir = process.env.WORKFLOW_PLANS_DIR;
  const fp = path.join(plansDir, '$sid' + '-supervisor-state.json');
  const st = createEmptyState('$sid');
  if (!st.audit || typeof st.audit !== 'object') st.audit = {};
  st.audit.audit_retry_count = 1;
  st.audit.audit_phase = 'pending';
  fs.writeFileSync(fp, JSON.stringify(st, null, 2));
}
" >/dev/null 2>&1
    )
    invoke_cli "$tmp" --set-audit-phase done --session-id "$sid"
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_retry_count")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "0" ]; then
        pass "C8: --set-audit-phase done resets audit_retry_count to 0"
    else
        fail "C8: --set-audit-phase done resets audit_retry_count to 0 (rc=$rc, val=$val)"
    fi
}

run_c1; run_c2; run_c3; run_c4; run_c5; run_c6; run_c7; run_c8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
