#!/usr/bin/env bash
# tests/feature-supervisor-premerge-warning.sh
# Tests: hooks/workflow-gate.js, hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js
# Tags: supervisor, em-supervisor, workflow-gate, premerge, warning-flush, dedup, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - workflow-gate.js firing as a real PreToolUse hook inside a live claude -p session
# - Real git repository context for repoDir resolution (this test mocks mergeHit detection)
# - actual gh pr merge execution
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# T5-dual-store covers the CC-UUID→wsid fallback path (C5): CC UUID supervisor state empty,
# wsid state has warning → checkSupervisorPreMerge must block via wsid. RED-EXPECTED until Change 2.
# L3 gap: CC-UUID-only path where resolveWorkflowSessionId() must be called internally
#   (requires real claude -p session env for CLAUDE_SESSION_ID propagation)

# T5: cumulative_severity="warning" + 1 finding; drive gh pr merge through workflow-gate.js
# Pass 1: assert audit_phase==="pending" AND layer1.findings.length UNCHANGED (intent-C2: blockWithoutError adds no L1 error)
# Pass 2 (audit_last_run_at set + audit_cause==="pre-merge-warning-flush", audit_phase=null): assert NO re-arm → gate approves

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
WFSTATE_NODE="$_AGENTS_DIR_NODE/hooks/lib/workflow-state.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr5'; }

# T5-dual-store: CC UUID supervisor state empty/unarmed, wsid state has warning findings → pre-merge must use wsid (C5)
# RED-EXPECTED until Change 2 (checkSupervisorPreMerge) implements dual-store state resolution.
run_t5_dual_store() {
    local tmp sid wsid tmp_node out
    tmp=$(make_tmp)
    sid="t5ds-$$"
    wsid="t5ds-wid-$$"
    if command -v cygpath >/dev/null 2>&1; then tmp_node="$(cygpath -m "$tmp")"; else tmp_node="$tmp"; fi

    if ! command -v node >/dev/null 2>&1; then
        skip "T5-dual-store: node not available"; rm -rf "$tmp"; return
    fi
    if [ ! -f "$HOOK" ] || ! grep -q "checkSupervisorPreMerge" "$HOOK" 2>/dev/null; then
        fail "T5-dual-store: checkSupervisorPreMerge absent (RED-EXPECTED — Change 2 not yet applied)"
        rm -rf "$tmp"; return
    fi

    # Seed CC UUID: workflow=complete, supervisor state EMPTY (no cumSev/findings)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf=require('$WFSTATE_NODE'); wf.markStep('$sid','user_verification','complete');
" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
fs.writeFileSync(w.getStatePath('$sid'),JSON.stringify(s.createEmptyState('$sid')));
" >/dev/null 2>&1

    # Seed wsid: cumSev=warning, 1 warning finding
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$wsid');
st.alert.cumulative_severity='warning';
st.alert.findings=[{categories:['workflow'],severity:'warning',detail:'dual-store warning',reporter:'test',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$wsid'),JSON.stringify(st));
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge"},"tool_response":{"output":""}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rm -rf "$tmp"

    # After Change 2: checkSupervisorPreMerge reads wsid → blocks on warning cumSev
    if echo "$out" | grep -qE '"decision".*"block"|"block".*"decision"|blockReason'; then
        pass "T5-dual-store: CC UUID empty + wsid warning → merge blocked via dual-store wsid fallback"
    else
        fail "T5-dual-store: merge not blocked — dual-store wsid state not used (Change 2 not applied or path missing)"
    fi
}
run_t5_dual_store

if [ ! -f "$HOOK" ]; then
    fail "T5: workflow-gate.js not present (RED-EXPECTED — Change 2 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Check if checkSupervisorPreMerge is present in workflow-gate (target function)
if ! grep -q "checkSupervisorPreMerge" "$HOOK" 2>/dev/null; then
    fail "T5: checkSupervisorPreMerge not yet in workflow-gate.js (RED-EXPECTED — Change 2 not yet applied)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# --- Setup: seed workflow state with user_verification=complete + supervisor state ---
seed_all() {
    local tmp_node="$1" sid="$2"
    # Seed workflow-gate state: user_verification=complete so merge can proceed
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1

    # Seed supervisor state: cumSev=warning, 1 alert finding, 0 layer1 findings
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.cumulative_severity = 'warning';
st.alert.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'pre-merge warning test',
    reporter: 'test',
    timestamp: new Date().toISOString()
}];
// layer1 starts empty (no findings)
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(JSON.stringify(st || null));
" 2>/dev/null
}

# --- T5-pass1: first gh pr merge → arms audit, blocks, does NOT add L1 finding ---
run_t5_pass1() {
    local tmp sid out rc state l1_count audit_phase audit_cause
    tmp=$(make_tmp)
    sid="t5-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    seed_all "$tmp_node" "$sid"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    # Read back state
    state=$(read_state "$tmp_node" "$sid")

    # Count layer1 findings (must remain 0 — intent-C2: blockWithoutError does NOT add L1 error)
    l1_count=$(echo "$state" | node -e "
const s = JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(String((s && s.layer1 && s.layer1.findings && s.layer1.findings.length) || 0));
" 2>/dev/null)

    audit_phase=$(echo "$state" | node -e "
const s = JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(String((s && s.audit && s.audit.audit_phase) || 'null'));
" 2>/dev/null)

    audit_cause=$(echo "$state" | node -e "
const s = JSON.parse(require('fs').readFileSync(0,'utf8'));
process.stdout.write(String((s && s.audit && s.audit.audit_cause) || 'null'));
" 2>/dev/null)

    rm -rf "$tmp"

    # The gate must block (exit 0 with decision:block is the blockWithoutError path)
    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T5-pass1: workflow-gate must block on warning cumSev pre-merge (checkSupervisorPreMerge not yet implemented or wrong path)"
        return
    fi

    # audit_phase must be "pending"
    if [ "$audit_phase" != "pending" ]; then
        fail "T5-pass1: audit_phase must be 'pending' after first merge attempt, got '$audit_phase'"
        return
    fi

    # audit_cause must be "pre-merge-warning-flush"
    if [ "$audit_cause" != "pre-merge-warning-flush" ]; then
        fail "T5-pass1: audit_cause must be 'pre-merge-warning-flush', got '$audit_cause'"
        return
    fi

    # layer1 findings must remain at 0 (blockWithoutError does not add L1 errors)
    if [ "$l1_count" != "0" ]; then
        fail "T5-pass1: layer1.findings must remain 0 (no L1 error added), got $l1_count (intent-C2 violated)"
        return
    fi

    pass "T5-pass1: warning pre-merge → audit_phase=pending, audit_cause=pre-merge-warning-flush, layer1=0"
}

# --- T5-pass2: after audit ran (audit_last_run_at set, audit_phase=null) → dedup → approve ---
run_t5_pass2() {
    local tmp sid out rc state
    tmp=$(make_tmp)
    sid="t5b-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    seed_all "$tmp_node" "$sid"

    # Simulate audit already ran: set audit_last_run_at + audit_cause=pre-merge-warning-flush, audit_phase=null
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeAuditState('$sid', {
    audit_phase: null,
    audit_cause: 'pre-merge-warning-flush',
    audit_last_run_at: new Date().toISOString(),
    audit_verdict: 'CONTINUE'
});
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # Dedup: must NOT re-arm. Gate should approve (decision=approve or no block).
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T5-pass2: dedup should prevent re-arm after audit already ran for pre-merge-warning-flush"
        return
    fi
    # approve() outputs decision:approve
    if ! echo "$out" | grep -q '"decision":"approve"'; then
        fail "T5-pass2: expected decision:approve after dedup pass, got: $(printf '%q' "$out")"
        return
    fi
    pass "T5-pass2: after audit ran (audit_last_run_at set) → dedup → no re-arm → approve"
}

run_t5_pass1
run_t5_pass2

# --- #1374: verdict + freshness-aware pre-merge skip (Path(i)) ---
# seed_verdict: cumSev=warning + 1 finding at $fts, plus an audit block already
# recorded (verdict/last_run_at/cause) from a NON-warning-flush cause.
# Under the current code the skip only fires for audit_cause=="pre-merge-warning-flush",
# so a stage-boundary verdict does NOT skip → gate re-arms & blocks (RED until #1374).
seed_verdict() {
    local tmp_node="$1" sid="$2" fts="$3" alast="$4" averdict="$5" acause="$6"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1

    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.cumulative_severity = 'warning';
st.alert.findings = [{
    categories: ['workflow'],
    severity: 'warning',
    detail: 'verdict-aware finding',
    reporter: 'test',
    timestamp: '$fts'
}];
st.audit.audit_phase = null;
st.audit.audit_verdict = '$averdict';
st.audit.audit_last_run_at = '$alast';
st.audit.audit_cause = '$acause';
st.audit.audit_armed_at = null;
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# run_t5_verdict_ready (RED until #1374):
# T0 finding, audit ran at T1 (>T0), verdict=WARN, cause="stage-boundary:CONFIRM_DETAIL".
# A fresh non-BLOCK verdict covering the current findings must let merge through.
# Current code ignores non-"pre-merge-warning-flush" causes → re-arms & blocks.
run_t5_verdict_ready() {
    local tmp sid out state
    tmp=$(make_tmp)
    sid="t5vr-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # T0 finding timestamp, T1 audit_last_run_at (T1 > T0)
    local t0="2026-01-01T00:00:00.000Z"
    local t1="2026-01-01T01:00:00.000Z"
    seed_verdict "$tmp_node" "$sid" "$t0" "$t1" "WARN" "stage-boundary:CONFIRM_DETAIL"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)

    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"'; then
        fail "run_t5_verdict_ready [RED-EXPECTED until #1374]: fresh non-BLOCK verdict (cause=stage-boundary) still blocks — verdict-aware skip not implemented"
        return
    fi
    if echo "$out" | grep -q '"decision":"approve"'; then
        pass "run_t5_verdict_ready: fresh WARN verdict (audit_last_run_at >= findingAt) → approve"
    else
        fail "run_t5_verdict_ready: expected decision:approve, got: $(printf '%q' "$out")"
    fi
}

# run_t5_stale_verdict (RED until #1374 WITH freshness anchor):
# audit ran at T1 with verdict=CONTINUE, THEN a new warning finding arrived at T2 (>T1).
# A naive verdict-only skip would wrongly approve; the freshness check
# (audit_last_run_at >= latestFindingAt) must catch the stale verdict and BLOCK.
run_t5_stale_verdict() {
    local tmp sid out
    tmp=$(make_tmp)
    sid="t5sv-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # audit ran at T1; new finding at T2 (T2 > T1) → verdict is stale
    local t1="2026-01-01T01:00:00.000Z"
    local t2="2026-01-01T02:00:00.000Z"
    seed_verdict "$tmp_node" "$sid" "$t2" "$t1" "CONTINUE" "stage-boundary:CONFIRM_DETAIL"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)

    rm -rf "$tmp"

    # Must block: the verdict predates the newest finding (stale).
    if echo "$out" | grep -q '"decision":"block"'; then
        pass "run_t5_stale_verdict: new finding after audit ran (T2 > audit_last_run_at) → stale verdict → block"
    else
        fail "run_t5_stale_verdict [RED until #1374 freshness anchor]: stale verdict wrongly skipped — freshness check (audit_last_run_at >= latestFindingAt) missing; got: $(printf '%q' "$out")"
    fi
}

# run_t5_verdict_block (GREEN-guard / regression prevention):
# audit ran at T1 (> finding timestamps) with verdict=BLOCK. BLOCK must always block,
# regardless of freshness. Verifies the #1374 skip never approves a BLOCK verdict.
run_t5_verdict_block() {
    local tmp sid out
    tmp=$(make_tmp)
    sid="t5vb-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # T1 (audit_last_run_at) > T0 (finding) — fresh, but verdict=BLOCK
    local t0="2026-01-01T00:00:00.000Z"
    local t1="2026-01-01T01:00:00.000Z"
    seed_verdict "$tmp_node" "$sid" "$t0" "$t1" "BLOCK" "stage-boundary:CONFIRM_DETAIL"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash"}}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)

    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"'; then
        pass "run_t5_verdict_block: BLOCK verdict always blocks (fresh or stale)"
    else
        fail "run_t5_verdict_block: BLOCK verdict must block regardless of freshness, got: $(printf '%q' "$out")"
    fi
}

run_t5_verdict_ready
run_t5_stale_verdict
run_t5_verdict_block

# C6: fail-open edge cases for checkSupervisorPreMerge
# When the detail.md file referenced by scope-drift is missing → hook exits 0 (fail-open, no crash)
# When there is no git repo (non-git directory) → Path(ii) fails-open → hook exits 0
run_c6_failopen_missing_detail() {
    if ! command -v node >/dev/null 2>&1; then
        skip "C6-missing-detail: node not available"; return
    fi

    local tmp sid tmp_node hook_input out rc
    tmp=$(make_tmp)
    sid="c6a-sid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # Seed workflow state: user_verification=complete
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1

    # Seed supervisor state: no findings, no cumSev (clean state)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Do NOT write any detail.md — missing detail.md is the test condition.
    # Use a non-git tmp dir as cwd so scope-drift path also fails gracefully.
    local nongit_dir
    nongit_dir=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then
        local nongit_node; nongit_node="$(cygpath -m "$nongit_dir")"
    else
        local nongit_node="$nongit_dir"
    fi

    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$nongit_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" WORKFLOW_SESSION_ID="c6a-wsid-$$" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" "$nongit_dir"

    # Fail-open: missing detail.md must not crash the hook; hook must exit 0
    if [ $rc -ne 0 ]; then
        fail "C6-missing-detail: hook must exit 0 (fail-open) when detail.md is missing, got rc=$rc"
        return
    fi
    # Must not block (no findings, no cumSev to trigger warning-flush; scope-drift skips when detail missing)
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "C6-missing-detail: hook must not block when detail.md is missing (fail-open), got: $(printf '%q' "${out:0:80}")"
        return
    fi
    pass "C6-missing-detail: missing detail.md → hook fails open (exit 0, no block)"
}

run_c6_failopen_nongit() {
    if ! command -v node >/dev/null 2>&1; then
        skip "C6-nongit: node not available"; return
    fi

    local tmp sid tmp_node hook_input out rc wsid
    tmp=$(make_tmp)
    sid="c6b-sid-$$"
    wsid="c6b-wsid-$$"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
    else
        local tmp_node="$tmp"
    fi

    # Seed workflow state: user_verification=complete
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1

    # Seed supervisor state: no cumSev/findings
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1

    # Write a detail.md for wsid (scope-drift check needs it), but cwd is a non-git dir
    mkdir -p "$tmp"
    cat > "$tmp/${wsid}-detail.md" <<'DETAIL'
# Implementation Detail Plan

## Files to modify

- `hooks/workflow-gate.js` — main merge gate

## Steps

Step 1: do something.
DETAIL

    # A plain tmp dir (not a git repo) as cwd — resolveBranchDiff must fail open
    local nongit_dir
    nongit_dir=$(make_tmp)
    if command -v cygpath >/dev/null 2>&1; then
        local nongit_node; nongit_node="$(cygpath -m "$nongit_dir")"
    else
        local nongit_node="$nongit_dir"
    fi

    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$nongit_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?
    rm -rf "$tmp" "$nongit_dir"

    # Fail-open: non-git cwd → resolveBranchDiff returns null → scope-drift skips → exit 0
    if [ $rc -ne 0 ]; then
        fail "C6-nongit: hook must exit 0 (fail-open) when cwd is not a git repo, got rc=$rc"
        return
    fi
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "C6-nongit: hook must not block when no git repo (fail-open), got: $(printf '%q' "${out:0:80}")"
        return
    fi
    pass "C6-nongit: non-git cwd → Path(ii) fails open (exit 0, no block)"
}

run_c6_failopen_missing_detail
run_c6_failopen_nongit

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
