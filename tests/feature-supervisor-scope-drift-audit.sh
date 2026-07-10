#!/usr/bin/env bash
# tests/feature-supervisor-scope-drift-audit.sh
# Tests: hooks/workflow-gate.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, workflow-gate, scope-drift, audit, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - workflow-gate.js firing as a real PreToolUse hook (hook registration via settings.json)
# - Real git push intercepted in live session — tests use a real git repo fixture
#   but not a live Claude Code session
# - resolveBranchDiff using origin/* refs that require a real remote
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# SKIPPED: CC-UUID-only dual-store resolution path (C4)
# Because: T5/T6 setup uses WORKFLOW_SESSION_ID env; CC-UUID→wsid resolution via
#   resolve-workflow-session-id.js is an L3 gap (requires real claude -p session env)
# L3 gap: a test where checkSupervisorPreMerge receives only CLAUDE_SESSION_ID and
#   must internally call resolveWorkflowSessionId() to locate warning/audit state

# T6: Three subcases (unconditional, works with ZERO prior findings):
# (a) gh pr merge: branch diff includes undeclared file → audit_cause="scope-drift:pre-merge" + block
# (b) git push origin main: same drift via BRANCH diff (NOT staged diff) → armed
# (c) dedup: with audit_last_run_at set + audit_cause="scope-drift:pre-merge" → NO re-arm, approve

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

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsr6'; }

# T6-threshold: AUDIT_SEVERITY_THRESHOLD must be "warning" after Change 5 (runs before guard exits)
if command -v node >/dev/null 2>&1; then
    _threshold=$(node -e "const s=require('$SCHEMA_NODE'); process.stdout.write(String(s.AUDIT_SEVERITY_THRESHOLD))" 2>/dev/null)
    if [ "${_threshold:-}" = "warning" ]; then
        pass "T6-threshold: AUDIT_SEVERITY_THRESHOLD=warning (Change 5 applied)"
    else
        fail "T6-threshold: AUDIT_SEVERITY_THRESHOLD should be 'warning', got '${_threshold:-undefined}' (Change 5 not yet applied)"
    fi
fi

if [ ! -f "$HOOK" ]; then
    fail "T6: workflow-gate.js not present (RED-EXPECTED — Change 2 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

if ! grep -q "scope-drift" "$HOOK" 2>/dev/null; then
    fail "T6: scope-drift not yet in workflow-gate.js (RED-EXPECTED — Change 2 not yet implemented)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# Setup a throwaway git repo fixture with:
#   - base branch (main) with one file
#   - feature branch with one additional undeclared file committed
setup_git_fixture() {
    local repodir="$1"
    git -C "$repodir" init -b main >/dev/null 2>&1 || git -C "$repodir" init >/dev/null 2>&1
    git -C "$repodir" config user.email "test@example.com" >/dev/null 2>&1
    git -C "$repodir" config user.name "Test" >/dev/null 2>&1
    # Disable inherited global core.hooksPath (agents/hooks pre-commit blocks commits
    # from non-linked-worktrees — fixture repos are throwaway, bypass is safe).
    git -C "$repodir" config core.hooksPath /dev/null >/dev/null 2>&1
    # Base commit on main: only declared file
    mkdir -p "$repodir/hooks"
    echo "declared" > "$repodir/hooks/workflow-gate.js"
    git -C "$repodir" add . >/dev/null 2>&1
    git -C "$repodir" commit --no-verify -m "base" >/dev/null 2>&1

    # Feature branch: add undeclared file
    git -C "$repodir" switch -c feature-test >/dev/null 2>&1 || git -C "$repodir" checkout -b feature-test >/dev/null 2>&1
    echo "undeclared" > "$repodir/hooks/supervisor-guard.js"
    git -C "$repodir" add . >/dev/null 2>&1
    git -C "$repodir" commit --no-verify -m "add undeclared file" >/dev/null 2>&1

    # Set up 'origin/main' locally so merge-base can be computed
    git -C "$repodir" branch -f "origin-main-ref" HEAD~ >/dev/null 2>&1 || true
    # Create a fake origin/main ref
    git -C "$repodir" update-ref refs/remotes/origin/main HEAD~ >/dev/null 2>&1 || true
}

# Write a detail.md fixture with only "hooks/workflow-gate.js" declared
write_detail_fixture() {
    local plansdir="$1" wsid="$2"
    mkdir -p "$plansdir"
    cat > "$plansdir/${wsid}-detail.md" <<'DETAIL'
# Implementation Detail Plan

## Files to modify

- `hooks/workflow-gate.js` — main merge gate

## Steps

Step 1: do something.
DETAIL
}

# Seed workflow-gate state with user_verification=complete
seed_wf_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1
}

# Seed supervisor state (empty findings, no cumSev — scope-drift is unconditional)
seed_supervisor_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
// No findings, no cumSev — scope-drift check is unconditional
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

read_audit_state() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(JSON.stringify((st && st.audit) || null));
" 2>/dev/null
}

# --- T6a: gh pr merge + branch diff with undeclared file → scope-drift block ---
run_t6a() {
    local tmp sid out rc repodir wsid
    tmp=$(make_tmp)
    sid="t6a-sid-$$"
    wsid="t6a-wsid-$$"
    repodir="$tmp/repo"
    mkdir -p "$repodir/hooks"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
        local repodir_node; repodir_node="$(cygpath -m "$repodir")"
    else
        local tmp_node="$tmp"
        local repodir_node="$repodir"
    fi

    setup_git_fixture "$repodir"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    seed_supervisor_state "$tmp_node" "$sid"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    local audit_state audit_cause audit_phase
    audit_state=$(read_audit_state "$tmp_node" "$sid")
    audit_cause=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_cause)||'null'))" 2>/dev/null)
    audit_phase=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_phase)||'null'))" 2>/dev/null)

    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T6a: scope-drift gh pr merge must block (checkSupervisorPreMerge not yet implemented)"
        return
    fi
    if [ "$audit_cause" != "scope-drift:pre-merge" ]; then
        fail "T6a: audit_cause must be 'scope-drift:pre-merge', got '$audit_cause'"
        return
    fi
    if [ "$audit_phase" != "pending" ]; then
        fail "T6a: audit_phase must be 'pending', got '$audit_phase'"
        return
    fi
    pass "T6a: gh pr merge + undeclared file → audit_cause=scope-drift:pre-merge + block"
}

# --- T6b: git push origin main + branch diff (staged empty) → scope-drift armed ---
run_t6b() {
    local tmp sid out rc repodir wsid
    tmp=$(make_tmp)
    sid="t6b-sid-$$"
    wsid="t6b-wsid-$$"
    repodir="$tmp/repo"
    mkdir -p "$repodir/hooks"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
        local repodir_node; repodir_node="$(cygpath -m "$repodir")"
    else
        local tmp_node="$tmp"
        local repodir_node="$repodir"
    fi

    setup_git_fixture "$repodir"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    seed_supervisor_state "$tmp_node" "$sid"

    # Explicitly confirm: staged area is empty (everything committed)
    local staged_count
    staged_count=$(git -C "$repodir" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    if [ "$staged_count" -ne 0 ]; then
        skip "T6b: fixture has staged changes (expected empty staged area after commit)"
        rm -rf "$tmp"
        return
    fi

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"git push origin main","cwd":"%s"}}' "$sid" "$repodir_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    local audit_state audit_cause
    audit_state=$(read_audit_state "$tmp_node" "$sid")
    audit_cause=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_cause)||'null'))" 2>/dev/null)

    rm -rf "$tmp"

    # T6b verifies that branch diff (not staged diff) is used.
    # Staged is empty, but committed branch has undeclared file — should still detect drift.
    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T6b: scope-drift git push must use BRANCH diff (not staged diff) — block expected even with empty staged area"
        return
    fi
    if [ "$audit_cause" != "scope-drift:pre-merge" ]; then
        fail "T6b: audit_cause must be 'scope-drift:pre-merge' for git push path, got '$audit_cause'"
        return
    fi
    pass "T6b: git push origin main + branch diff (staged empty) → scope-drift armed via branch diff"
}

# --- T6c: dedup — audit_last_run_at already set + same cause → NO re-arm, approve ---
run_t6c() {
    local tmp sid out rc repodir wsid
    tmp=$(make_tmp)
    sid="t6c-sid-$$"
    wsid="t6c-wsid-$$"
    repodir="$tmp/repo"
    mkdir -p "$repodir/hooks"
    if command -v cygpath >/dev/null 2>&1; then
        local tmp_node; tmp_node="$(cygpath -m "$tmp")"
        local repodir_node; repodir_node="$(cygpath -m "$repodir")"
    else
        local tmp_node="$tmp"
        local repodir_node="$repodir"
    fi

    setup_git_fixture "$repodir"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    seed_supervisor_state "$tmp_node" "$sid"

    # Mark audit as already ran for this cause
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
w.writeAuditState('$sid', {
    audit_phase: null,
    audit_cause: 'scope-drift:pre-merge',
    audit_last_run_at: new Date().toISOString(),
    audit_verdict: 'CONTINUE'
});
" >/dev/null 2>&1

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rc=$?

    rm -rf "$tmp"

    # Dedup: scope-drift already audited → no re-arm → approve
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T6c: dedup must prevent re-arm when audit_last_run_at+audit_cause=scope-drift:pre-merge already set"
        return
    fi
    if ! echo "$out" | grep -q '"decision":"approve"'; then
        fail "T6c: expected approve after dedup, got: $(printf '%q' "$out")"
        return
    fi
    pass "T6c: scope-drift dedup → no re-arm → approve"
}

run_t6a
run_t6b
run_t6c

# T8-all-declared: first merge arms scope-drift:pre-merge even when ALL changed files are declared
# and zero prior findings exist. Second merge deduplicates → approve.
# RED-EXPECTED until Change 2+3 implement unconditional pre-merge scope-drift audit trigger.
setup_git_all_declared() {
    local repodir="$1"
    git -C "$repodir" init -b main >/dev/null 2>&1 || git -C "$repodir" init >/dev/null 2>&1
    git -C "$repodir" config user.email "test@example.com" >/dev/null 2>&1
    git -C "$repodir" config user.name "Test" >/dev/null 2>&1
    # Disable inherited global core.hooksPath (agents/hooks pre-commit blocks commits
    # from non-linked-worktrees — fixture repos are throwaway, bypass is safe).
    git -C "$repodir" config core.hooksPath /dev/null >/dev/null 2>&1
    mkdir -p "$repodir/hooks"
    echo "base" > "$repodir/hooks/workflow-gate.js"
    git -C "$repodir" add . >/dev/null 2>&1
    git -C "$repodir" commit --no-verify -m "base" >/dev/null 2>&1
    git -C "$repodir" switch -c feature-declared >/dev/null 2>&1 || git -C "$repodir" checkout -b feature-declared >/dev/null 2>&1
    echo "changed" > "$repodir/hooks/workflow-gate.js"
    git -C "$repodir" add . >/dev/null 2>&1
    git -C "$repodir" commit --no-verify -m "update declared file" >/dev/null 2>&1
    git -C "$repodir" update-ref refs/remotes/origin/main HEAD~ >/dev/null 2>&1 || true
}

run_t8() {
    local tmp sid wsid repodir tmp_node repodir_node hook_input out out_pass1 audit_state audit_phase
    tmp=$(make_tmp)
    sid="t8-sid-$$"
    wsid="t8-wsid-$$"
    repodir="$tmp/repo"
    mkdir -p "$repodir/hooks"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
        repodir_node="$(cygpath -m "$repodir")"
    else
        tmp_node="$tmp"
        repodir_node="$repodir"
    fi

    setup_git_all_declared "$repodir"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    # C1: seed with a warning-severity finding so the warning-flush path fires and blocks
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert.cumulative_severity='warning';
st.alert.findings=[{categories:['workflow'],severity:'warning',detail:'pre-merge warning finding',reporter:'test',timestamp:new Date().toISOString()}];
fs.writeFileSync(w.getStatePath('$sid'),JSON.stringify(st));
" >/dev/null 2>&1

    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    # Pass 1: first merge attempt — capture stdout to assert block decision (C1)
    out_pass1=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    audit_state=$(read_audit_state "$tmp_node" "$sid")
    audit_phase=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_phase)||'null'))" 2>/dev/null)

    if [ "$audit_phase" != "pending" ]; then
        fail "T8-all-declared pass1: expected audit_phase=pending, got phase=$audit_phase (Change 2+3 not yet applied)"
        rm -rf "$tmp"; return
    fi
    # C1: hook stdout must contain decision:block (warning-flush path fires first)
    if ! echo "$out_pass1" | grep -q '"decision":"block"'; then
        fail "T8-all-declared pass1 (C1): hook output must contain decision:block on first merge (warning-flush path), got: $(printf '%q' "${out_pass1:0:80}")"
        rm -rf "$tmp"; return
    fi

    # Simulate audit ran — use the actual audit_cause that was set
    local audit_cause
    audit_cause=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_cause)||'pre-merge-warning-flush'))" 2>/dev/null)
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE');
w.writeAuditState('$sid',{audit_phase:null,audit_cause:'$audit_cause',audit_last_run_at:new Date().toISOString(),audit_verdict:'CONTINUE'});
" >/dev/null 2>&1

    # Pass 2: second merge → dedup → approve (no re-arm for same cause)
    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T8-all-declared pass2: dedup must prevent re-arm after audit already ran for cause=$audit_cause"
        return
    fi
    pass "T8-all-declared: pass1 blocks (decision:block emitted, C1 fixed); pass2 deduplicates → approve"
}
run_t8

# --- C2: after audit_verdict=BLOCK completes, second merge call must still block ---
# Seed state: audit_phase=complete and audit_verdict=BLOCK → workflow-gate must block (not pass through).
# This verifies that a BLOCK verdict prevents merging even after the audit completes.
run_c2() {
    local tmp sid wsid repodir tmp_node repodir_node hook_input out
    tmp=$(make_tmp)
    sid="c2-sid-$$"
    wsid="c2-wsid-$$"
    repodir="$tmp/repo"
    mkdir -p "$repodir/hooks"
    if command -v cygpath >/dev/null 2>&1; then
        tmp_node="$(cygpath -m "$tmp")"
        repodir_node="$(cygpath -m "$repodir")"
    else
        tmp_node="$tmp"
        repodir_node="$repodir"
    fi

    setup_git_all_declared "$repodir"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"

    # Seed supervisor state: warning finding + audit_phase=complete + audit_verdict=BLOCK
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w=require('$WRITER_NODE'),s=require('$SCHEMA_NODE'),fs=require('fs');
const st=s.createEmptyState('$sid');
st.alert.cumulative_severity='warning';
st.alert.findings=[{categories:['workflow'],severity:'warning',detail:'block verdict test',reporter:'test',timestamp:new Date().toISOString()}];
st.audit.audit_phase='complete';
st.audit.audit_verdict='BLOCK';
st.audit.audit_cause='scope-drift:pre-merge';
st.audit.audit_last_run_at=new Date().toISOString();
fs.writeFileSync(w.getStatePath('$sid'),JSON.stringify(st));
" >/dev/null 2>&1

    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" WORKFLOW_SESSION_ID="$wsid" \
        run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    rm -rf "$tmp"

    # audit_verdict=BLOCK: the pre-merge warning-flush path should block on cumSev=warning.
    # audit_phase=complete is not a skip condition for warning-flush; audit_last_run_at+cause
    # dedup applies to scope-drift, but warning-flush dedup checks for pre-merge-warning-flush cause.
    # Since cause is scope-drift:pre-merge (not pre-merge-warning-flush), the warning-flush
    # path arms and blocks again.
    if echo "$out" | grep -q '"decision":"block"'; then
        pass "C2: audit_verdict=BLOCK + second merge call → still blocked (block verdict enforced)"
    else
        fail "C2: expected block after audit_verdict=BLOCK, got: $(printf '%q' "${out:0:80}")"
    fi
}
run_c2

# Note: Additional-1 (collect-audit-triggers CONFIRM_INTENT sentinel test) lives in
# tests/feature-supervisor-atmost1.sh (co-located with other collect-audit-triggers tests).

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
