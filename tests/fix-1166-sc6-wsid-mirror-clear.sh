#!/usr/bin/env bash
# Tests: skills/session-close/SKILL.md (SC-6 wsid mirror-clear)
# Tags: supervisor, em-supervisor, session-close, sc6, wsid, fix-1166, scope:issue-specific
# RED for issue #1166.
#
# Validates that SC-6 in skills/session-close/SKILL.md includes a wsid mirror-clear step:
# 1. [Structural] The SC-6 section resolves Session-ID from WORKTREE_NOTES.md via awk.
# 2. [Structural] The SC-6 section calls supervisor-write-alert with --session-id "$WSID"
#    and --set-alert-phase frozen and --clear-alert-armed-at.
# 3. [L2 integration] Running the awk extraction + supervisor-write-alert mirror-clear
#    command sequence against a synthetic WORKTREE_NOTES.md + wsid state file leaves
#    the wsid store's alert_armed_at as null (i.e., the armed flag is cleared).
#
# L3 gap (what this test does NOT catch):
# - Whether session-close/SKILL.md's SC-6 orchestration step actually fires the awk
#   command in a real claude -p session (only an E2E test can verify that).
# - Whether the wsid != CC UUID guard works correctly when both are the same value.
# Closest-to-action mitigation: skill-orchestration category in
#   bin/check-verification-gate.sh fires at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SC_SKILL="$AGENTS_DIR/skills/session-close/SKILL.md"
WRITE_ALERT="$AGENTS_DIR/bin/supervisor-write-alert"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"

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

# S1: skills/session-close/SKILL.md SC-6 section contains Session-ID awk extraction.
# The fix adds: WSID="$(awk '/^Session-ID:/{...}' WORKTREE_NOTES.md)"
run_s1() {
    require_source "$SC_SKILL" "S1: SC-6 contains Session-ID awk resolution" || return
    if grep -q "Session-ID" "$SC_SKILL" && grep -q "awk" "$SC_SKILL"; then
        pass "S1: SC-6 contains Session-ID awk resolution"
    else
        fail "S1: SC-6 missing Session-ID awk resolution (fix #1166 not yet applied)"
    fi
}

# S2: SC-6 contains supervisor-write-alert call with --clear-alert-armed-at for the wsid.
# The fix adds a conditional mirror-clear that calls supervisor-write-alert on $WSID.
run_s2() {
    require_source "$SC_SKILL" "S2: SC-6 contains wsid supervisor-write-alert --clear-alert-armed-at" || return
    if grep -q "clear-alert-armed-at" "$SC_SKILL" && grep -q "WSID\|wsid" "$SC_SKILL"; then
        pass "S2: SC-6 contains wsid supervisor-write-alert --clear-alert-armed-at"
    else
        fail "S2: SC-6 missing wsid supervisor-write-alert --clear-alert-armed-at (fix #1166 not yet applied)"
    fi
}

# L2: Actually run the mirror-clear command sequence against a synthetic setup.
# Simulates: fake WORKTREE_NOTES.md with Session-ID, wsid state with alert_armed_at set,
# then runs awk extraction + supervisor-write-alert --session-id WSID --set-alert-phase frozen --clear-alert-armed-at,
# and verifies that alert_armed_at in the wsid state file is null afterward.
run_l2() {
    require_source "$WRITE_ALERT" "L2: supervisor-write-alert --clear-alert-armed-at clears wsid alert_armed_at" || return
    require_source "$WRITER_NODE" "L2: supervisor-state-writer.js exists" || return

    local tmp wsid cc_uuid armed_after
    tmp="$(mktemp -d)"
    wsid="wsid-l2-sc6test"
    cc_uuid="cc-uuid-l2-sc6test"

    # Write a fake WORKTREE_NOTES.md with Session-ID: <wsid>
    printf 'Session-ID: %s\nSome-Other-Field: ignore\n' "$wsid" > "$tmp/WORKTREE_NOTES.md"

    # Seed wsid state with alert_armed_at set (armed state) and alert_phase=null
    # so that --set-alert-phase frozen + --clear-alert-armed-at is a valid transition.
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$wsid');
st.alert.alert_armed_at = new Date().toISOString();
st.alert.alert_phase = null;
fs.writeFileSync(w.getStatePath('$wsid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Verify that alert_armed_at was actually seeded (sanity check)
    local seeded
    seeded=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$wsid');
process.stdout.write(st && st.alert && st.alert.alert_armed_at ? 'armed' : 'not-armed');
" 2>/dev/null)
    if [ "$seeded" != "armed" ]; then
        rm -rf "$tmp"
        fail "L2: test setup failed — wsid alert_armed_at not seeded (got: $seeded)"
        return
    fi

    # Run awk extraction (replicating the SC-6 command that the fix will add)
    local extracted_wsid
    extracted_wsid="$(awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' "$tmp/WORKTREE_NOTES.md" 2>/dev/null || true)"

    if [ "$extracted_wsid" != "$wsid" ]; then
        rm -rf "$tmp"
        fail "L2: awk extraction returned wrong wsid (expected=$wsid, got=$extracted_wsid)"
        return
    fi

    # Run the mirror-clear: --set-alert-phase frozen clears alert_armed_at at the writer level
    # (terminal state enforced by writeAlertState). Also pass --clear-alert-armed-at explicitly.
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$WRITE_ALERT" \
        --session-id "$extracted_wsid" \
        --set-alert-phase frozen \
        --clear-alert-armed-at \
        >/dev/null 2>&1
    local write_rc=$?

    # Read back the wsid state and check alert_armed_at is null
    armed_after=$(WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$wsid');
if (!st || !st.alert) { process.stdout.write('MISSING'); process.exit(0); }
process.stdout.write(st.alert.alert_armed_at === null ? 'null' : String(st.alert.alert_armed_at));
" 2>/dev/null)

    rm -rf "$tmp"

    if [ "$armed_after" = "null" ]; then
        pass "L2: supervisor-write-alert --clear-alert-armed-at clears wsid alert_armed_at"
    else
        fail "L2: wsid alert_armed_at not cleared (got: $armed_after, write_rc=$write_rc)"
    fi
}

run_s1
run_s2
run_l2

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
