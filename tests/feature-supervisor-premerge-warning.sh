#!/usr/bin/env bash
# tests/feature-supervisor-premerge-warning.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/supervisor-check.js, hooks/lib/audit-ledger.js
# Tags: supervisor, em-supervisor, workflow-gate, premerge, freshness-backstop, TL2, scope:issue-specific, pwsh-not-required, hook-registration
# TL3 gap (what this test does NOT catch):
# - workflow-gate.js firing as a real PreToolUse hook inside a live claude -p session
# - a real gh pr merge execution against a real PR
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
# #2256 S5-e: the pre-merge gate never arms an audit; it only re-checks TR5 freshness.

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
WFSTATE_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state.js"
FINGERPRINT_NODE="$_AGENTS_DIR_NODE/hooks/lib/diff-fingerprint.js"

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
to_node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip "all: node/git not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

# A git fixture repo plus the plan artifacts the freshness key composes over.
make_repo() {
    local dir="$1" sid="$2"
    git init -q "$dir" >/dev/null 2>&1
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "test"
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -qm seed >/dev/null 2>&1
}

seed_plans() {
    local plans_dir="$1" sid="$2"
    printf '# intent\n' > "$plans_dir/$sid-intent.md"
    printf '# outline\n' > "$plans_dir/$sid-outline.md"
    printf '# detail\n\n## Files to modify\n\n- `seed.txt`\n' > "$plans_dir/$sid-detail.md"
}

current_freshness_key() {
    local repo_node="$1" plans_node="$2" sid="$3"
    run_with_timeout 10 node -e "
const fp = require('$FINGERPRINT_NODE');
const r = fp.computeFreshnessKey('$repo_node', '$plans_node', '$sid');
process.stdout.write(String((r && r.freshness_key) || ''));
" 2>/dev/null
}

# Seed a supervisor state carrying warning findings plus one TR5 ledger entry.
# $4 = verdict, $5 = freshness_key on the entry ('' = no TR5 entry at all)
seed_state() {
    local plans_node="$1" sid="$2" cumsev="$3" verdict="$4" fkey="$5"
    WORKFLOW_PLANS_DIR="$plans_node" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const st = s.createEmptyState('$sid');
st.alert.cumulative_severity = '$cumsev';
st.alert.findings = [{
    categories: ['workflow'], severity: 'warning', detail: 'pre-merge warning',
    reporter: 'test', timestamp: '2026-01-01T00:00:00.000Z'
}];
st.audit.audit_phase = null;
st.audit.run_seq = 1;
if ('$fkey') {
    st.audit.ledger = [{
        id: 'run-0001', tr_ids: ['TR4', 'TR5'], outcome: 'terminal', verdict: '$verdict',
        cause: 'step-complete:user_verification',
        sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': 'k'.repeat(64) },
        freshness_key: '$fkey'
    }];
    st.audit.last_terminal_run_id = 'run-0001';
    st.audit.audit_verdict = '$verdict';
} else {
    st.audit.ledger = [{
        id: 'run-0001', tr_ids: ['TR4'], outcome: 'terminal', verdict: 'CONTINUE',
        cause: 'step-complete:write_code',
        sub_checks: ['detail-code'], input_key: { 'detail-code': 'k'.repeat(64) },
        freshness_key: 'stale'
    }];
    st.audit.last_terminal_run_id = 'run-0001';
}
fs.writeFileSync(w.getStatePath('$sid'), JSON.stringify(st));
" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$plans_node" run_with_timeout 10 node -e "
const wf = require('$WFSTATE_NODE');
wf.markStep('$sid', 'user_verification', 'complete');
" >/dev/null 2>&1
}

read_audit_field() {
    local plans_node="$1" sid="$2" expr="$3"
    WORKFLOW_PLANS_DIR="$plans_node" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid') || {};
const a = st.audit || {};
process.stdout.write(String($expr));
" 2>/dev/null
}

# Fixture isolation (rules/test/fixture-isolation.md). resolveWorkflowSessionId()
# never reads WORKFLOW_SESSION_ID; its wsid priority is (1) WORKTREE_NOTES.md at CWD /
# git-common-dir parent, (2) CLAUDE_CODE_SESSION_ID guarded on a `<value>-*.md` artifact,
# (3) CLAUDE_ENV_FILE→CLAUDE_SESSION_ID (already unset at top). Running node from the real
# worktree leaked the developer's live wsid via priority 1, collapsing computeFreshnessKey
# to null (fail-closed block). Run node from the isolated plans dir (no WORKTREE_NOTES.md,
# git-root probes miss) and pin the test's session id via priority 2 (CLAUDE_CODE_SESSION_ID
# + the seed_plans artifacts) so plan-artifact lookups resolve under this test's sid.
drive_merge() {
    local plans_node="$1" sid="$2" cwd_node="$3"
    local hook_input
    hook_input=$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr merge --squash","cwd":"%s"}}' "$sid" "$cwd_node")
    (
        cd "$plans_node" || exit 1
        CLAUDE_CODE_SESSION_ID="$sid" \
        WORKFLOW_PLANS_DIR="$plans_node" AGENTS_CONFIG_DIR="$plans_node" \
            run_with_timeout 20 node "$HOOK" <<< "$hook_input" 2>/dev/null
    )
}

if [ ! -f "$HOOK" ]; then
    fail "workflow-gate.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# --- T1: TR5 handled the warnings (fresh, non-BLOCK) → backstop allows ---
run_t1_tr5_handled() {
    local tmp repo plans sid plans_node repo_node fkey out phase
    tmp=$(make_tmp); sid="pmb-t1-$$"
    repo="$tmp/repo"; plans="$tmp/plans"; mkdir -p "$plans"
    make_repo "$repo" "$sid"; seed_plans "$plans" "$sid"
    repo_node=$(to_node_path "$repo"); plans_node=$(to_node_path "$plans")

    fkey=$(current_freshness_key "$repo_node" "$plans_node" "$sid")
    if [ -z "$fkey" ]; then
        fail "T1 [RED-EXPECTED until #2256]: computeFreshnessKey unavailable"
        rm -rf "$tmp"; return
    fi
    seed_state "$plans_node" "$sid" "warning" "CONTINUE" "$fkey"

    out=$(drive_merge "$plans_node" "$sid" "$repo_node")
    phase=$(read_audit_field "$plans_node" "$sid" "a.audit_phase")
    rm -rf "$tmp"

    if echo "$out" | grep -q '"decision":"block"'; then
        fail "T1: TR5 already settled recurrence-patterns on the current inputs → backstop must allow, got block"
        return
    fi
    if [ "$phase" != "null" ]; then
        fail "T1: the gate must never arm an audit (audit_phase='$phase')"
        return
    fi
    pass "T1: fresh non-BLOCK TR5 run → backstop allows and arms nothing"
}

# --- T2: no TR5 run → warnings unhandled → deny with freshness-backstop:pre-merge ---
run_t2_no_tr5_run() {
    local tmp repo plans sid plans_node repo_node out phase ledger_len
    tmp=$(make_tmp); sid="pmb-t2-$$"
    repo="$tmp/repo"; plans="$tmp/plans"; mkdir -p "$plans"
    make_repo "$repo" "$sid"; seed_plans "$plans" "$sid"
    repo_node=$(to_node_path "$repo"); plans_node=$(to_node_path "$plans")

    seed_state "$plans_node" "$sid" "warning" "CONTINUE" ""

    out=$(drive_merge "$plans_node" "$sid" "$repo_node")
    phase=$(read_audit_field "$plans_node" "$sid" "a.audit_phase")
    ledger_len=$(read_audit_field "$plans_node" "$sid" "(a.ledger || []).length")
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T2: TR5 never ran → backstop must deny the merge, got: $(printf '%q' "${out:0:120}")"
        return
    fi
    if ! echo "$out" | grep -q 'freshness-backstop:pre-merge'; then
        fail "T2: deny reason must name freshness-backstop:pre-merge, got: $(printf '%q' "${out:0:200}")"
        return
    fi
    if [ "$phase" != "null" ] || [ "$ledger_len" != "1" ]; then
        fail "T2: deny must stay read-only (audit_phase='$phase', ledger=$ledger_len)"
        return
    fi
    pass "T2: no TR5 run → deny with freshness-backstop:pre-merge, no arm, ledger untouched"
}

# --- T3: TR5 ran but the inputs moved afterwards → stale → deny ---
run_t3_stale_freshness() {
    local tmp repo plans sid plans_node repo_node fkey out phase
    tmp=$(make_tmp); sid="pmb-t3-$$"
    repo="$tmp/repo"; plans="$tmp/plans"; mkdir -p "$plans"
    make_repo "$repo" "$sid"; seed_plans "$plans" "$sid"
    repo_node=$(to_node_path "$repo"); plans_node=$(to_node_path "$plans")

    fkey=$(current_freshness_key "$repo_node" "$plans_node" "$sid")
    seed_state "$plans_node" "$sid" "warning" "CONTINUE" "${fkey:-seed}"
    printf 'edited after the TR5 verdict\n' >> "$repo/seed.txt"

    out=$(drive_merge "$plans_node" "$sid" "$repo_node")
    phase=$(read_audit_field "$plans_node" "$sid" "a.audit_phase")
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T3: code moved after the TR5 verdict → backstop must deny, got: $(printf '%q' "${out:0:120}")"
        return
    fi
    if ! echo "$out" | grep -q 'freshness-backstop:pre-merge'; then
        fail "T3: stale deny must name freshness-backstop:pre-merge, got: $(printf '%q' "${out:0:200}")"
        return
    fi
    if [ "$phase" != "null" ]; then
        fail "T3: the gate must never arm an audit (audit_phase='$phase')"
        return
    fi
    pass "T3: stale freshness key → deny with freshness-backstop:pre-merge, no arm"
}

# --- T4: BLOCK verdict reaching the backstop → deny + severity=error finding (TR5 hold bypassed) ---
run_t4_block_reaches_backstop() {
    local tmp repo plans sid plans_node repo_node fkey out errors
    tmp=$(make_tmp); sid="pmb-t4-$$"
    repo="$tmp/repo"; plans="$tmp/plans"; mkdir -p "$plans"
    make_repo "$repo" "$sid"; seed_plans "$plans" "$sid"
    repo_node=$(to_node_path "$repo"); plans_node=$(to_node_path "$plans")

    fkey=$(current_freshness_key "$repo_node" "$plans_node" "$sid")
    seed_state "$plans_node" "$sid" "warning" "BLOCK" "${fkey:-seed}"

    out=$(drive_merge "$plans_node" "$sid" "$repo_node")
    errors=$(WORKFLOW_PLANS_DIR="$plans_node" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid') || {};
const all = [].concat((st.alert && st.alert.findings) || [], (st.layer1 && st.layer1.findings) || []);
process.stdout.write(String(all.filter((f) => f && f.severity === 'error').length));
" 2>/dev/null)
    rm -rf "$tmp"

    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T4: an unresolved BLOCK verdict must deny at the backstop, got: $(printf '%q' "${out:0:120}")"
        return
    fi
    if [ "$errors" = "0" ] || [ -z "$errors" ]; then
        fail "T4: reaching Path (i-b) must append a severity=error finding (TR5 hold bypassed), got $errors"
        return
    fi
    pass "T4: BLOCK verdict → deny plus a severity=error TR5-hold-bypassed finding"
}

# --- T5: freshness key uncomputable (non-git cwd) → fail closed, no crash ---
run_t5_uncomputable_fails_closed() {
    local tmp plans nongit sid plans_node nongit_node out rc
    tmp=$(make_tmp); sid="pmb-t5-$$"
    plans="$tmp/plans"; nongit="$tmp/nongit"; mkdir -p "$plans" "$nongit"
    seed_plans "$plans" "$sid"
    plans_node=$(to_node_path "$plans"); nongit_node=$(to_node_path "$nongit")

    seed_state "$plans_node" "$sid" "warning" "CONTINUE" ""

    out=$(drive_merge "$plans_node" "$sid" "$nongit_node")
    rc=$?
    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T5: the hook must not crash when the freshness key cannot be computed (rc=$rc)"
        return
    fi
    if ! echo "$out" | grep -q '"decision":"block"'; then
        fail "T5: an uncomputable freshness key must fail closed (deny), got: $(printf '%q' "${out:0:120}")"
        return
    fi
    pass "T5: non-git cwd → freshness key uncomputable → fail-closed deny without crashing"
}

run_t1_tr5_handled
run_t2_no_tr5_run
run_t3_stale_freshness
run_t4_block_reaches_backstop
run_t5_uncomputable_fails_closed

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
