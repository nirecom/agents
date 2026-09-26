#!/usr/bin/env bash
# tests/feature-supervisor-scope-drift-audit.sh
# Tests: hooks/workflow-gate.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, workflow-gate, scope-drift, audit, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap: workflow-gate.js not exercised as a real PreToolUse hook / live-session git push; checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh (hook-registration). C4 (CC-UUID->wsid dual-store) skipped — T6 uses WORKFLOW_SESSION_ID env; CC-UUID resolution is an L3 gap.
# T6/T8 (#2256 S5-e): the pre-merge gate is now a READ-ONLY freshness backstop that arms nothing (scope-drift:pre-merge arming retired). It denies unless a terminal TR5 run exists whose freshness_key still matches and whose verdict is not BLOCK. SSOT: tests/feature-2256-premerge-backstop.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-schema.js"
WFSTATE_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state.js"

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

# Compute the current freshness key over repo working tree + plan artifacts for a
# sid — must be computed identically to checkSupervisorPreMerge (same repo/plans/sid).
FP_NODE="$_AGENTS_DIR_NODE/hooks/lib/diff-fingerprint.js"
fresh_key() {
    local plans_node="$1" repo_node="$2" sid="$3"
    run_with_timeout 5 node -e "
const fp = require('$FP_NODE');
const r = fp.computeFreshnessKey('$repo_node', '$plans_node', '$sid');
process.stdout.write(String((r && r.freshness_key) || 'null'));
" 2>/dev/null
}

# Seed one terminal TR5 audit ledger run (verdict + freshness key) — the only shape
# the read-only freshness backstop approves (when fresh + non-BLOCK).
seed_tr5_terminal_run() {
    local tmp_node="$1" sid="$2" verdict="$3" fk="$4"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const fs = require('fs');
const st = w.readState('$sid') || {};
st.audit = st.audit || {};
st.audit.ledger = [{
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], verdict: '$verdict', freshness_key: '$fk',
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': '$fk' },
}];
st.audit.last_terminal_run_id = 'run-0011';
st.audit.audit_verdict_summary = '$verdict';
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
}

# Write all three plan artifacts under a sid so computeFreshnessKey resolves a
# non-null key (it collapses to null if intent/outline/detail is missing).
write_plan_artifacts() {
    local plansdir="$1" sid="$2"
    mkdir -p "$plansdir"
    printf '# intent\ni1\n' > "$plansdir/${sid}-intent.md"
    printf '# outline\no1\n' > "$plansdir/${sid}-outline.md"
    printf '# detail\nd1\n\n## Files to modify\n\n- hooks/workflow-gate.js\n' > "$plansdir/${sid}-detail.md"
}

# Run the pre-merge hook under fixture isolation (rules/test/fixture-isolation.md).
# resolveWorkflowSessionId() never reads WORKFLOW_SESSION_ID; its wsid priority is
# (1) WORKTREE_NOTES.md at CWD / git-common-dir parent, (2) CLAUDE_CODE_SESSION_ID
# guarded on a `<value>-*.md` artifact, (3) CLAUDE_ENV_FILE→CLAUDE_SESSION_ID. Running
# from the real worktree therefore leaked the developer's live wsid via priority 1.
# Neutralize priority 1 by running node from the isolated temp dir (no WORKTREE_NOTES.md,
# git-root probes miss), unset the priority-3 leak vars, and pin the test's wsid via
# priority 2 (CLAUDE_CODE_SESSION_ID + the ${wsid}-*.md artifacts the test seeds). The
# hook's own CC session id still comes from hook_input.session_id (= sid), so the audit
# ledger stays keyed by sid while plan artifacts resolve under wsid (#2256 C8 dual-ID).
run_premerge_hook() {
    local tmp_node="$1" wsid="$2" hook_input="$3"
    (
        cd "$tmp_node" || exit 1
        unset CLAUDE_ENV_FILE CLAUDE_SESSION_ID
        CLAUDE_CODE_SESSION_ID="$wsid" \
        WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
            run_with_timeout 15 node "$HOOK" <<< "$hook_input" 2>/dev/null
    )
}

# --- T6a: gh pr merge, supervisor state but no terminal TR5 run → backstop blocks, arms nothing ---
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

    out=$(run_premerge_hook "$tmp_node" "$wsid" "$hook_input")
    rc=$?

    local audit_state audit_cause audit_phase
    audit_state=$(read_audit_state "$tmp_node" "$sid")
    audit_cause=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_cause)||'null'))" 2>/dev/null)
    audit_phase=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_phase)||'null'))" 2>/dev/null)

    rm -rf "$tmp"

    # Supervisor state resolves but no terminal TR5 run exists → the read-only
    # backstop denies the merge (authoritative) and arms NOTHING.
    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T6a: freshness backstop must block a merge with no terminal TR5 run, got: $(printf '%q' "${out:0:80}")"
        return
    fi
    if [ "$audit_cause" != "null" ]; then
        fail "T6a: freshness backstop arms nothing — audit_cause must stay null, got '$audit_cause'"
        return
    fi
    if [ "$audit_phase" != "null" ]; then
        fail "T6a: freshness backstop arms nothing — audit_phase must stay null, got '$audit_phase'"
        return
    fi
    pass "T6a: gh pr merge, no terminal TR5 run → backstop blocks, arms nothing"
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

    out=$(run_premerge_hook "$tmp_node" "$wsid" "$hook_input")
    rc=$?

    local audit_state audit_cause
    audit_state=$(read_audit_state "$tmp_node" "$sid")
    audit_cause=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_cause)||'null'))" 2>/dev/null)

    rm -rf "$tmp"

    # The freshness backstop gates git push to a protected branch the same way as
    # gh pr merge: no terminal TR5 run → block, and it arms nothing.
    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T6b: freshness backstop must block a git push with no terminal TR5 run, got: $(printf '%q' "${out:0:80}")"
        return
    fi
    if [ "$audit_cause" != "null" ]; then
        fail "T6b: freshness backstop arms nothing on the git push path — audit_cause must stay null, got '$audit_cause'"
        return
    fi
    pass "T6b: git push origin main, no terminal TR5 run → backstop blocks, arms nothing"
}

# --- T6c: a fresh, non-BLOCK terminal TR5 run → the backstop approves the merge ---
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
    # All three plan artifacts must exist under WSID (#2256 C8: plan artifacts are
    # keyed by the workflow session id, not the CC session id) or computeFreshnessKey
    # collapses to null (fail-closed block). write_plan_artifacts first, then
    # write_detail_fixture overwrites detail.md under WSID with the scope-drift detail.
    write_plan_artifacts "$tmp" "$wsid"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    seed_supervisor_state "$tmp_node" "$sid"

    # Seed a fresh, non-BLOCK terminal TR5 run whose freshness_key matches the
    # current working tree — the one shape the read-only backstop approves.
    # The freshness key is computed over WSID (matching supervisor-check's
    # planSessionId = wsid || effectiveSid), while the ledger lives in the CC-sid
    # state file (read via the hook's session_id).
    local fk
    fk=$(fresh_key "$tmp_node" "$repodir_node" "$wsid")
    seed_tr5_terminal_run "$tmp_node" "$sid" "CONTINUE" "$fk"

    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    out=$(run_premerge_hook "$tmp_node" "$wsid" "$hook_input")
    rc=$?

    rm -rf "$tmp"

    # A fresh, non-BLOCK terminal TR5 run is the one shape the backstop lets through.
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T6c: a fresh non-BLOCK TR5 run must let the merge through, got block: $(printf '%q' "${out:0:80}")"
        return
    fi
    if ! echo "$out" | grep -q '"decision":"approve"'; then
        fail "T6c: expected approve for a fresh non-BLOCK TR5 run, got: $(printf '%q' "$out")"
        return
    fi
    pass "T6c: fresh non-BLOCK terminal TR5 run → backstop approves the merge"
}

run_t6a
run_t6b
run_t6c

# T8-all-declared (#2256 S5-e): "declared vs undeclared" no longer matters — the
# backstop arms nothing and only checks for a fresh non-BLOCK terminal TR5 run.
# Pass 1: no TR5 run → block, arms nothing. Pass 2: fresh TR5 run seeded → approve.
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
    # Plan artifacts keyed by WSID (#2256 C8), detail.md written last so the
    # scope-drift detail wins; freshness key is computed over WSID to match
    # supervisor-check's planSessionId = wsid || effectiveSid.
    write_plan_artifacts "$tmp" "$wsid"
    write_detail_fixture "$tmp" "$wsid"
    seed_wf_state "$tmp_node" "$sid"
    # Seed supervisor state (empty findings) so it resolves → backstop is authoritative.
    seed_supervisor_state "$tmp_node" "$sid"

    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$repodir_node")

    # Pass 1: no terminal TR5 run exists → backstop blocks and arms nothing.
    out_pass1=$(run_premerge_hook "$tmp_node" "$wsid" "$hook_input")
    audit_state=$(read_audit_state "$tmp_node" "$sid")
    audit_phase=$(echo "$audit_state" | node -e "const s=JSON.parse(require('fs').readFileSync(0,'utf8'));process.stdout.write(String((s&&s.audit_phase)||'null'))" 2>/dev/null)

    if [ "$audit_phase" != "null" ]; then
        fail "T8-all-declared pass1: backstop arms nothing — audit_phase must stay null, got phase=$audit_phase"
        rm -rf "$tmp"; return
    fi
    if ! echo "$out_pass1" | grep -q '"decision":"block"'; then
        fail "T8-all-declared pass1: backstop must block first merge (no terminal TR5 run), got: $(printf '%q' "${out_pass1:0:80}")"
        rm -rf "$tmp"; return
    fi

    # Seed a fresh, non-BLOCK terminal TR5 run — the one shape the backstop approves.
    # Freshness key over WSID (plan-artifact keying, #2256 C8); ledger under CC-sid.
    local fk
    fk=$(fresh_key "$tmp_node" "$repodir_node" "$wsid")
    seed_tr5_terminal_run "$tmp_node" "$sid" "CONTINUE" "$fk"

    # Pass 2: fresh non-BLOCK TR5 run present → merge is allowed.
    out=$(run_premerge_hook "$tmp_node" "$wsid" "$hook_input")
    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T8-all-declared pass2: a fresh non-BLOCK TR5 run must let the merge through, got block: $(printf '%q' "${out:0:80}")"
        return
    fi
    if ! echo "$out" | grep -q '"decision":"approve"'; then
        fail "T8-all-declared pass2: expected approve for a fresh non-BLOCK TR5 run, got: $(printf '%q' "${out:0:80}")"
        return
    fi
    pass "T8-all-declared: pass1 blocks (no TR5 run, arms nothing); pass2 approves (fresh non-BLOCK TR5 run)"
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

    out=$(run_premerge_hook "$tmp_node" "$wsid" "$hook_input")
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
