#!/usr/bin/env bash
# Tests: hooks/supervisor-trigger.js (escape-hatch arm finding-presence gate)
# Tags: supervisor, em-supervisor, layer2, trigger, posttooluse, fix-975, scope:issue-specific
# RED for issue #975.
#
# Validates: supervisor-trigger.js must only arm L2 (set l2_armed_at) on
# escape-hatch sentinels when at least one finding with severity !== "notice"
# exists. Pre-authorized WORKFLOW_OFF prompts (and notice-only sessions)
# must NOT arm a Layer 2 review.
#
# L3 gap (what this test does NOT catch):
# - hook registration in settings.json PostToolUse matchers — if
#   supervisor-trigger.js is not wired, escape-hatch arming is not observable
# - real Claude Code PostToolUse payload shape differences
# Closest-to-action mitigation: hook-registration category in
#   bin/check-verification-gate.sh fires at WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/supervisor-trigger.js"
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

# Seed state with layer1.findings supplied as a JS literal (e.g. "[]" or full array).
seed_state_l1_findings() {
    local tmp="$1" sid="$2" findings_literal="$3"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.layer1.findings = $findings_literal;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# Pipe a Bash PostToolUse JSON envelope with the WORKFLOW_OFF escape-hatch
# command into the trigger hook. Returns the post-invocation l2_armed_at value
# (string "null" when null, JSON-string otherwise).
run_trigger_and_get_armed_at() {
    local tmp="$1" sid="$2"
    local payload
    payload="{\"tool_name\":\"Bash\",\"session_id\":\"$sid\",\"tool_input\":{\"command\":\"echo \\\"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: test>>\\\"\"},\"tool_response\":\"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: test>>\"}"
    echo "$payload" | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(st && st.layer2 ? JSON.stringify(st.layer2.l2_armed_at) : 'no-state');
" 2>/dev/null
}

# Variant: ENFORCE_WORKTREE_OFF sentinel (also an escape-hatch).
run_trigger_worktreeoff_get_armed_at() {
    local tmp="$1" sid="$2"
    local payload
    payload="{\"tool_name\":\"Bash\",\"session_id\":\"$sid\",\"tool_input\":{\"command\":\"echo \\\"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test>>\\\"\"},\"tool_response\":\"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test>>\"}"
    echo "$payload" | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(st && st.layer2 ? JSON.stringify(st.layer2.l2_armed_at) : 'no-state');
" 2>/dev/null
}

# Non-escape-hatch: regular Bash command (no sentinel).
run_trigger_nonescape_get_armed_at() {
    local tmp="$1" sid="$2"
    local payload
    payload="{\"tool_name\":\"Bash\",\"session_id\":\"$sid\",\"tool_input\":{\"command\":\"echo hello\"},\"tool_response\":\"hello\"}"
    echo "$payload" | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(st && st.layer2 ? JSON.stringify(st.layer2.l2_armed_at) : 'no-state');
" 2>/dev/null
}

# T1: no state file -> trigger should not arm (no state to mutate). Verify
# that a state file is not created (or, if created, l2_armed_at remains null).
run_t1() {
    require_source "$HOOK" "T1: no state file -> no arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    out=$(run_trigger_and_get_armed_at "$tmp" "t1-sid")
    rm -rf "$tmp"
    # Accept either: "no-state" (file never created) or "null" (file created with l2_armed_at=null).
    if [ "$out" = "no-state" ] || [ "$out" = "null" ]; then
        pass "T1: no state file -> no arm"
    else
        fail "T1: no state file -> no arm (l2_armed_at=$out)"
    fi
}

# T2: state with only "notice" severity findings -> SHOULD NOT arm
run_t2() {
    require_source "$HOOK" "T2: notice-only findings -> no arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t2-sid" \
        '[{"categories":["workflow"],"severity":"notice","detail":"info-only","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    out=$(run_trigger_and_get_armed_at "$tmp" "t2-sid")
    rm -rf "$tmp"
    if [ "$out" = "null" ]; then
        pass "T2: notice-only findings -> no arm"
    else
        fail "T2: notice-only findings -> no arm (l2_armed_at=$out)"
    fi
}

# T3: state with one "warning" finding -> SHOULD arm
run_t3() {
    require_source "$HOOK" "T3: warning finding -> arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t3-sid" \
        '[{"categories":["workflow"],"severity":"warning","detail":"sus","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    out=$(run_trigger_and_get_armed_at "$tmp" "t3-sid")
    rm -rf "$tmp"
    if [ "$out" != "null" ] && [ "$out" != "no-state" ] && [ -n "$out" ]; then
        pass "T3: warning finding -> arm"
    else
        fail "T3: warning finding -> arm (l2_armed_at=$out)"
    fi
}

# T4: state with one "error" finding -> SHOULD arm
run_t4() {
    require_source "$HOOK" "T4: error finding -> arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t4-sid" \
        '[{"categories":["workflow"],"severity":"error","detail":"bad","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    out=$(run_trigger_and_get_armed_at "$tmp" "t4-sid")
    rm -rf "$tmp"
    if [ "$out" != "null" ] && [ "$out" != "no-state" ] && [ -n "$out" ]; then
        pass "T4: error finding -> arm"
    else
        fail "T4: error finding -> arm (l2_armed_at=$out)"
    fi
}

# T5: state with no findings at all -> SHOULD NOT arm (empty == notice-only)
run_t5() {
    require_source "$HOOK" "T5: empty findings -> no arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t5-sid" "[]"
    out=$(run_trigger_and_get_armed_at "$tmp" "t5-sid")
    rm -rf "$tmp"
    if [ "$out" = "null" ]; then
        pass "T5: empty findings -> no arm"
    else
        fail "T5: empty findings -> no arm (l2_armed_at=$out)"
    fi
}

# T6: non-escape-hatch command with warning finding -> SHOULD NOT arm
# (arm gate is only for escape-hatch sentinels, regardless of findings)
run_t6() {
    require_source "$HOOK" "T6: non-escape-hatch cmd -> no arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t6-sid" \
        '[{"categories":["workflow"],"severity":"warning","detail":"sus","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    out=$(run_trigger_nonescape_get_armed_at "$tmp" "t6-sid")
    rm -rf "$tmp"
    if [ "$out" = "null" ] || [ "$out" = "no-state" ]; then
        pass "T6: non-escape-hatch cmd -> no arm"
    else
        fail "T6: non-escape-hatch cmd -> no arm (l2_armed_at=$out)"
    fi
}

# T7: ENFORCE_WORKTREE_OFF sentinel + notice-only findings -> SHOULD NOT arm
run_t7() {
    require_source "$HOOK" "T7: WORKTREE_OFF + notice-only -> no arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t7-sid" \
        '[{"categories":["workflow"],"severity":"notice","detail":"info","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    out=$(run_trigger_worktreeoff_get_armed_at "$tmp" "t7-sid")
    rm -rf "$tmp"
    if [ "$out" = "null" ]; then
        pass "T7: WORKTREE_OFF + notice-only -> no arm"
    else
        fail "T7: WORKTREE_OFF + notice-only -> no arm (l2_armed_at=$out)"
    fi
}

# T8: mixed notice+warning findings -> SHOULD arm (warning dominates)
run_t8() {
    require_source "$HOOK" "T8: mixed notice+warning -> arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t8-sid" \
        '[{"categories":["workflow"],"severity":"notice","detail":"info","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"},{"categories":["code"],"severity":"warning","detail":"suspicious","reporter":"t","timestamp":"2026-06-06T12:01:00.000Z"}]'
    out=$(run_trigger_and_get_armed_at "$tmp" "t8-sid")
    rm -rf "$tmp"
    if [ "$out" != "null" ] && [ "$out" != "no-state" ] && [ -n "$out" ]; then
        pass "T8: mixed notice+warning -> arm"
    else
        fail "T8: mixed notice+warning -> arm (l2_armed_at=$out)"
    fi
}

# T9: escape-hatch with warning finding when already armed -> l2_armed_at unchanged (idempotency)
run_t9() {
    require_source "$HOOK" "T9: escape-hatch + already armed -> l2_armed_at unchanged" || return
    local tmp out before after
    tmp="$(mktemp -d)"
    before="2026-01-01T00:00:00.000Z"
    seed_state_l1_findings "$tmp" "t9-sid" \
        '[{"categories":["workflow"],"severity":"warning","detail":"sus","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    # Pre-set l2_armed_at so !l2ArmedAt is false in the hook
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeLayer2State('t9-sid', { l2_armed_at: '$before' });
" >/dev/null 2>&1
    out=$(run_trigger_and_get_armed_at "$tmp" "t9-sid")
    rm -rf "$tmp"
    # Armed-at should still be the original timestamp (not overwritten)
    if [ "$out" = "\"$before\"" ]; then
        pass "T9: escape-hatch + already armed -> l2_armed_at unchanged"
    else
        fail "T9: escape-hatch + already armed -> l2_armed_at unchanged (got=$out, expected=\"$before\")"
    fi
}

# T10: WORKTREE_OFF sentinel + warning finding -> SHOULD arm (symmetric with T3/WORKFLOW_OFF)
run_t10() {
    require_source "$HOOK" "T10: WORKTREE_OFF + warning -> arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    seed_state_l1_findings "$tmp" "t10-sid" \
        '[{"categories":["workflow"],"severity":"warning","detail":"sus","reporter":"t","timestamp":"2026-06-06T12:00:00.000Z"}]'
    out=$(run_trigger_worktreeoff_get_armed_at "$tmp" "t10-sid")
    rm -rf "$tmp"
    if [ "$out" != "null" ] && [ "$out" != "no-state" ] && [ -n "$out" ]; then
        pass "T10: WORKTREE_OFF + warning -> arm"
    else
        fail "T10: WORKTREE_OFF + warning -> arm (l2_armed_at=$out)"
    fi
}

# T11: state present but layer1 field missing -> fail-open (no arm, no throw)
run_t11() {
    require_source "$HOOK" "T11: layer1 missing -> fail-open no arm" || return
    local tmp out
    tmp="$(mktemp -d)"
    # Seed state with layer1 deleted to test defensive read
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('t11-sid');
delete st.layer1;
fs.writeFileSync(w.getStatePath('t11-sid'), JSON.stringify(st));
" >/dev/null 2>&1
    out=$(run_trigger_and_get_armed_at "$tmp" "t11-sid")
    rm -rf "$tmp"
    # Should fail-open: no arm (null) and no throw (no-state not expected here since file exists)
    if [ "$out" = "null" ]; then
        pass "T11: layer1 missing -> fail-open no arm"
    else
        fail "T11: layer1 missing -> fail-open no arm (l2_armed_at=$out)"
    fi
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
