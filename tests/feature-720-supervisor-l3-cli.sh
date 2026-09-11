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
        # No id may reach the CLI from ANY source, or the parent Claude Code
        # session's own id leaks in and this case silently stops testing.
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID WORKFLOW_SESSION_ID
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

# C9 (#2270): the audit CLI is reached by non-native-LLM callers whose env sets
# only CLAUDE_CODE_SESSION_ID. Without --session-id it must resolve that id
# rather than aborting, or the supervisor audit trail loses those sessions.
# RED until the CLAUDE_CODE_SESSION_ID fallback lands in bin/supervisor-write-audit.
run_c9() {
    require_source "$CLI" "C9: --session-id absent, CLAUDE_CODE_SESSION_ID env resolves it" || return
    local tmp sid val rc
    tmp="$(mktemp -d)"; sid="c9ccsid"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        unset CLAUDE_SESSION_ID WORKFLOW_SESSION_ID
        export CLAUDE_CODE_SESSION_ID="$sid"
        run_with_timeout 5 node "$CLI" --set-audit-phase done >/dev/null 2>&1
    )
    rc=$?
    val=$(read_field "$tmp" "$sid" "audit.audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$val" = "\"done\"" ]; then
        pass "C9: CLAUDE_CODE_SESSION_ID resolves the target session"
    else
        fail "C9: CLAUDE_CODE_SESSION_ID resolves the target session (rc=$rc, val=$val)"
    fi
}

# C10 (#2270, CPR-ORTH with SP-20f / T-marker-9): BOTH session vars set to
# different ids. SID_SOURCES.ccuuid must rank CLAUDE_CODE_SESSION_ID first, the
# same order the SSOT resolver uses — otherwise the audit record lands in the
# store of an identity the caller is not.
run_c10() {
    require_source "$CLI" "C10: CLAUDE_CODE_SESSION_ID outranks CLAUDE_SESSION_ID" || return
    local tmp cc_sid legacy_sid cc_val legacy_val rc
    tmp="$(mktemp -d)"; cc_sid="c10ccsid"; legacy_sid="c10legacysid"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        unset WORKFLOW_SESSION_ID
        export CLAUDE_SESSION_ID="$legacy_sid"
        export CLAUDE_CODE_SESSION_ID="$cc_sid"
        run_with_timeout 5 node "$CLI" --set-audit-phase done >/dev/null 2>&1
    )
    rc=$?
    cc_val=$(read_field "$tmp" "$cc_sid" "audit.audit_phase")
    legacy_val=$(read_field "$tmp" "$legacy_sid" "audit.audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$cc_val" = "\"done\"" ] && [ "$legacy_val" != "\"done\"" ]; then
        pass "C10: both vars set -> CLAUDE_CODE_SESSION_ID names the store"
    else
        fail "C10: both vars set -> CLAUDE_CODE_SESSION_ID names the store (rc=$rc, cc=$cc_val, legacy=$legacy_val)"
    fi
}

# C11 (#2270): the OTHER extension point of the same change — MIRROR_RESOLVERS.wsid.
# With WORKFLOW_SESSION_ID resolving the primary store, the mirror store is found
# from the CC-side env; a non-native-LLM caller that exports only
# CLAUDE_CODE_SESSION_ID must still get both halves of the dual-store write.
run_c11() {
    require_source "$CLI" "C11: wsid mirror resolves via CLAUDE_CODE_SESSION_ID" || return
    local tmp wsid cc_sid wsid_val cc_val rc
    tmp="$(mktemp -d)"; wsid="c11wsid"; cc_sid="c11ccsid"
    (
        export WORKFLOW_PLANS_DIR="$(_TMPCONV "$tmp")"
        unset CLAUDE_SESSION_ID
        export WORKFLOW_SESSION_ID="$wsid"
        export CLAUDE_CODE_SESSION_ID="$cc_sid"
        run_with_timeout 5 node "$CLI" --set-audit-phase done >/dev/null 2>&1
    )
    rc=$?
    wsid_val=$(read_field "$tmp" "$wsid" "audit.audit_phase")
    cc_val=$(read_field "$tmp" "$cc_sid" "audit.audit_phase")
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$wsid_val" = "\"done\"" ] && [ "$cc_val" = "\"done\"" ]; then
        pass "C11: WORKFLOW_SESSION_ID primary + CLAUDE_CODE_SESSION_ID mirror -> both stores written"
    else
        fail "C11: WORKFLOW_SESSION_ID primary + CLAUDE_CODE_SESSION_ID mirror -> both stores written (rc=$rc, wsid=$wsid_val, cc=$cc_val)"
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

run_c1; run_c2; run_c3; run_c4; run_c5; run_c6; run_c7; run_c8; run_c9; run_c10; run_c11

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
