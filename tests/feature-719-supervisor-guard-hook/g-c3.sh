#!/bin/bash
# tests/feature-719-supervisor-guard-hook/g-c3.sh
# G-C3a/b/c: detectWorktreeOffProposal -> arm L2 with C3 cause (#903)
# _lib.sh must be sourced by the caller before sourcing this file.

# ---------------------------------------------------------------------------
# G-C3a/b/c: detectWorktreeOffProposal -> arm L2 with C3 cause (#903)
# RED: detectWorktreeOffProposal + l2_cause field not yet implemented.
# Asserts the state file has layer2.l2_cause set after hook runs over a
# transcript whose last assistant text content contains the escape sentinel.
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
    require_source "$HOOK" "G-C3a: WORKTREE_OFF sentinel in assistant text -> l2_cause = 'C3 worktree-off proposal'" || return
    local tmp tp cause
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will use <<WORKFLOW_ENFORCE_WORKTREE_OFF: some reason>>"}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3a-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    printf '{"stop_hook_active":false,"session_id":"g-c3a-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    cause=$(WORKFLOW_PLANS_DIR="$tmp" read_alert_cause "$tmp" "g-c3a-sid")
    rm -rf "$tmp"
    if [ "$cause" = "C3 worktree-off proposal" ]; then
        pass "G-C3a: WORKTREE_OFF sentinel in assistant text -> l2_cause = 'C3 worktree-off proposal'"
    else
        fail "G-C3a: WORKTREE_OFF sentinel in assistant text -> l2_cause = 'C3 worktree-off proposal' (got=$cause)"
    fi
}

run_g_c3b() {
    require_source "$HOOK" "G-C3b: WORKFLOW_OFF sentinel in assistant text -> l2_cause = 'C3 workflow-off proposal'" || return
    local tmp tp cause
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will use <<WORKFLOW_ENFORCE_WORKFLOW_OFF: some reason>>"}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3b-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    printf '{"stop_hook_active":false,"session_id":"g-c3b-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    cause=$(WORKFLOW_PLANS_DIR="$tmp" read_alert_cause "$tmp" "g-c3b-sid")
    rm -rf "$tmp"
    if [ "$cause" = "C3 workflow-off proposal" ]; then
        pass "G-C3b: WORKFLOW_OFF sentinel in assistant text -> l2_cause = 'C3 workflow-off proposal'"
    else
        fail "G-C3b: WORKFLOW_OFF sentinel in assistant text -> l2_cause = 'C3 workflow-off proposal' (got=$cause)"
    fi
}

run_g_c3c() {
    require_source "$HOOK" "G-C3c: WORKTREE_OFF sentinel in assistant text -> l2_phase = 'pending'" || return
    local tmp tp phase
    tmp="$(mktemp -d)"
    make_fixture "$tmp/t.jsonl" \
        '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"test"}]}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will use <<WORKFLOW_ENFORCE_WORKTREE_OFF: some reason>>"}]}}'
    tp="$(node_path "$tmp/t.jsonl")"
    seed_state "$tmp" "g-c3c-sid" "{ alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [] }"
    printf '{"stop_hook_active":false,"session_id":"g-c3c-sid","transcript_path":"%s"}' "$tp" \
        | WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$HOOK" >/dev/null 2>&1
    phase=$(WORKFLOW_PLANS_DIR="$tmp" read_alert_phase "$tmp" "g-c3c-sid")
    rm -rf "$tmp"
    if [ "$phase" = "pending" ]; then
        pass "G-C3c: WORKTREE_OFF sentinel in assistant text -> l2_phase = 'pending'"
    else
        fail "G-C3c: WORKTREE_OFF sentinel in assistant text -> l2_phase = 'pending' (got=$phase)"
    fi
}
