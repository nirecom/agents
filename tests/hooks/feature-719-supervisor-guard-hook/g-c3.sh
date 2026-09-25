#!/bin/bash
# tests/feature-719-supervisor-guard-hook/g-c3.sh
# Tests: hooks/supervisor-guard.js (C3 OFF-proposal detection + done-guard)
# Tags: supervisor, em-supervisor, hook, layer2, stop, scope:issue-specific
# G-C3a/b/c: detectOffProposal -> arm L2 with C3 cause (#903)
# G-C3d: alert_phase=done done-guard skips C3 block (#1163)
# G-C3-text-neg: text-only bypass keyword must NOT trigger C3 (#1162)
# _lib.sh must be sourced by the caller before sourcing this file.
#
# L3 gap (what this L2 test does NOT catch):
# - hook registration in settings.json Stop hooks (covered by the parent
#   entrypoint's L3 gap note); these cases invoke the hook script directly.
#
# ---------------------------------------------------------------------------
# G-C3a/b/c: detectOffProposal -> arm L2 with C3 cause (#903)
# Asserts the state file has alert.alert_cause / alert.alert_phase set after the
# hook runs over a transcript whose last assistant Bash tool_use command contains
# the escape sentinel. Post #1162, OFF proposals are detected from Bash tool_use
# commands only (assistant TEXT content is no longer scanned).
# ---------------------------------------------------------------------------

read_alert_cause() {
    # args: tmp sid
    local tmp="$1" sid="$2"
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = process.env.WORKFLOW_PLANS_DIR + '/' + '$sid' + '-supervisor-state.json';
try {
  const s = JSON.parse(fs.readFileSync(p, 'utf8'));
  process.stdout.write(String((s.alert || {}).alert_cause || ''));
} catch (e) {
  process.stdout.write('');
}
" 2>/dev/null
}

read_alert_phase() {
    local tmp="$1" sid="$2"
    run_with_timeout 5 node -e "
const fs = require('fs');
const p = process.env.WORKFLOW_PLANS_DIR + '/' + '$sid' + '-supervisor-state.json';
try {
  const s = JSON.parse(fs.readFileSync(p, 'utf8'));
  process.stdout.write(String((s.alert || {}).alert_phase || ''));
} catch (e) {
  process.stdout.write('');
}
" 2>/dev/null
}

run_g_c3a() {
    require_source "$HOOK" "G-C3a: WORKTREE_OFF sentinel in Bash tool_use -> alert_cause = 'C3 worktree-off proposal'" || return
    local tmp tp cause
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: some reason>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3a-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    printf '{"stop_hook_active":false,"session_id":"g-c3a-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    cause=$(WORKFLOW_PLANS_DIR="$tmp" read_alert_cause "$tmp" "g-c3a-sid")
    rm -rf "$tmp"
    if [ "$cause" = "C3 worktree-off proposal" ]; then
        pass "G-C3a: WORKTREE_OFF sentinel in Bash tool_use -> alert_cause = 'C3 worktree-off proposal'"
    else
        fail "G-C3a: WORKTREE_OFF sentinel in Bash tool_use -> alert_cause = 'C3 worktree-off proposal' (got=$cause)"
    fi
}

run_g_c3b() {
    require_source "$HOOK" "G-C3b: WORKFLOW_OFF sentinel in Bash tool_use -> alert_cause = 'C3 workflow-off proposal'" || return
    local tmp tp cause
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: some reason>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3b-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    printf '{"stop_hook_active":false,"session_id":"g-c3b-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    cause=$(WORKFLOW_PLANS_DIR="$tmp" read_alert_cause "$tmp" "g-c3b-sid")
    rm -rf "$tmp"
    if [ "$cause" = "C3 workflow-off proposal" ]; then
        pass "G-C3b: WORKFLOW_OFF sentinel in Bash tool_use -> alert_cause = 'C3 workflow-off proposal'"
    else
        fail "G-C3b: WORKFLOW_OFF sentinel in Bash tool_use -> alert_cause = 'C3 workflow-off proposal' (got=$cause)"
    fi
}

run_g_c3c() {
    require_source "$HOOK" "G-C3c: WORKTREE_OFF sentinel in Bash tool_use -> alert_phase = 'pending'" || return
    local tmp tp phase
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: some reason>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3c-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    printf '{"stop_hook_active":false,"session_id":"g-c3c-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    phase=$(WORKFLOW_PLANS_DIR="$tmp" read_alert_phase "$tmp" "g-c3c-sid")
    rm -rf "$tmp"
    if [ "$phase" = "pending" ]; then
        pass "G-C3c: WORKTREE_OFF sentinel in Bash tool_use -> alert_phase = 'pending'"
    else
        fail "G-C3c: WORKTREE_OFF sentinel in Bash tool_use -> alert_phase = 'pending' (got=$phase)"
    fi
}

# G-C3d — alert_phase=done + Bash tool_use OFF sentinel -> C3 done-guard skips block.
# RED until #1163 adds `alertPhase !== "done" && alertPhase !== "frozen"` to the C3 branch.
# When seeded with alert_phase=done, writeAlertState(done->pending) silently fails and the
# unconditional C3 block fires a bogus {"decision":"block"}. After the fix the C3 branch is
# skipped: hook exits 0 with no decision:block.
run_g_c3d() {
    local label="G-C3d: alert_phase=done + Bash OFF sentinel -> C3 skipped (done-guard), exit 0 no block"
    require_source "$HOOK" "$label" || return
    local tmp tp out rc
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: some reason>>\""}}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3d-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: 'done' }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g-c3d-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -q '"decision":"block"' ); then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# G-C3-text-neg — bypass keyword in assistant TEXT content ONLY (no tool_use) must NOT trigger C3.
# RED until #1162 scopes detectOffProposal scanning to Bash tool_use items only. While text
# content is still scanned, this fixture fires a bogus C3 block; after the fix it exits 0 clean.
run_g_c3_text_neg() {
    local label="G-C3-text-neg: OFF keyword in assistant TEXT only -> no C3 (text not scanned), exit 0 no block"
    require_source "$HOOK" "$label" || return
    local tmp tp out rc
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will use <<WORKFLOW_ENFORCE_WORKTREE_OFF: some reason>>"}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3-text-neg-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [], alert_phase: null }"
    out=$(printf '{"stop_hook_active":false,"session_id":"g-c3-text-neg-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! ( echo "$out" | grep -q '"decision":"block"' ); then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}
