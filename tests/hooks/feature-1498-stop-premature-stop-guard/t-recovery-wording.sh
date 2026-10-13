# t-recovery-wording.sh — T17-T18 (#2527 step 4-2): C4 block wording when NEXT_SKILL is empty
# Sourced by tests/hooks/feature-1498-stop-premature-stop-guard.sh

# Seed a v1 state paused at branching_complete (the one step whose NEXT_SKILL
# stays empty). The pending entry is stamped so the v1->v2 migration keeps it.
# $1=tmp_dir $2=sid
seed_workflow_state_branching() {
    local tmp="$1" sid="$2"
    mkdir -p "$tmp/workflow"
    WF_DIR="$tmp/workflow" SID="$sid" run_with_timeout 10 node -e "
const fs = require('fs'), path = require('path');
const at = '2026-01-01T00:00:00.000Z';
const done = { status: 'complete', updated_at: at };
const steps = { workflow_init: done, clarify_intent: done, research: done, outline: done, detail: done,
  branching_complete: { status: 'pending', updated_at: at } };
const state = { version: 1, session_id: process.env.SID, created_at: at, workflow_type: 'wf-code', steps };
fs.writeFileSync(path.join(process.env.WF_DIR, process.env.SID + '.json'), JSON.stringify(state));
" >/dev/null 2>&1
    seed_plan_approvals "$tmp" "$sid"
}

# run_guard_in_repo <tmp> <sid> — runs the hook from a git-init'ed cwd; prints stdout.
run_guard_in_repo() {
    local tmp="$1" sid="$2"
    git init -q "$tmp/repo" >/dev/null 2>&1
    git -C "$tmp/repo" config core.hooksPath /dev/null
    (cd "$tmp/repo" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | WORKFLOW_STATE_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 30 node "$HOOK_NODE" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# T17: empty NEXT_SKILL (branching_complete) -> the block reason carries the
#      NEXT_HINT body as "Recovery:", not "(unknown)" / "Re-run next-step".
# ---------------------------------------------------------------------------
run_t17() {
    require_source "$HOOK" "T17: empty NEXT_SKILL -> Recovery: wording" || return
    local tmp sid out
    tmp="$(mktemp -d)"
    sid="t17-sid"
    seed_workflow_state_branching "$tmp" "$sid"
    out="$(run_guard_in_repo "$tmp" "$sid")"
    rm -rf "$tmp"
    if ! echo "$out" | grep -q '"block"'; then
        fail "T17: expected decision:block at branching_complete (out=$out)"
        return
    fi
    if echo "$out" | grep -q 'Recovery:' && echo "$out" | grep -q 'WORKFLOW_BRANCHING_COMPLETE'; then
        pass "T17a: block reason shows the NEXT_HINT body as Recovery:"
    else
        fail "T17a: expected Recovery: + WORKFLOW_BRANCHING_COMPLETE in reason (out=$out)"
    fi
    if echo "$out" | grep -q 'NEXT_SKILL=(unknown)'; then
        fail "T17b: reason still prints NEXT_SKILL=(unknown) (out=$out)"
    else
        pass "T17b: reason no longer prints NEXT_SKILL=(unknown)"
    fi
    if echo "$out" | grep -q 'Re-run next-step'; then
        fail "T17c: reason still tells the model to Re-run next-step (out=$out)"
    else
        pass "T17c: reason no longer says Re-run next-step"
    fi
}

# ---------------------------------------------------------------------------
# T18: control — a non-empty NEXT_SKILL keeps the "Run /<skill>" wording and
#      gains no Recovery: line.
# ---------------------------------------------------------------------------
run_t18() {
    require_source "$HOOK" "T18: non-empty NEXT_SKILL -> Run /<skill> wording" || return
    local tmp sid out
    tmp="$(mktemp -d)"
    sid="t18-sid"
    seed_workflow_state "$tmp" "$sid" "invoke"
    out="$(run_guard_in_repo "$tmp" "$sid")"
    rm -rf "$tmp"
    if echo "$out" | grep -q '"block"' && echo "$out" | grep -q 'Run /write-tests'; then
        pass "T18a: non-empty NEXT_SKILL keeps Run /write-tests"
    else
        fail "T18a: expected block with Run /write-tests (out=$out)"
    fi
    if echo "$out" | grep -q 'Recovery:'; then
        fail "T18b: non-empty NEXT_SKILL must not gain a Recovery: line (out=$out)"
    else
        pass "T18b: non-empty NEXT_SKILL has no Recovery: line"
    fi
}
