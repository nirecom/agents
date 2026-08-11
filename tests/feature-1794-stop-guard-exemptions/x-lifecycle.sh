# x-lifecycle.sh — X1-X7 + T17/T18 + Z1: isWorkflowStarted, the C4/C2 restructuring
# and the marker sweep introduced by #1794. Sourced by tests/feature-1794-stop-guard-exemptions.sh.
# Tests: hooks/workflow-state/lifecycle.js, hooks/workflow-state.js, hooks/workflow-state/state-io.js, hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js
# Tags: stop-hook, supervisor-guard, session-marker, regression-1794, scope:issue-specific, pwsh-not-required, TL1, TL2

# ---------------------------------------------------------------------------
# X1: isWorkflowStarted(sid) truth table
#     complete/skipped -> true; pending/in_progress/absent/corrupt -> false
# ---------------------------------------------------------------------------
run_X1() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_raw_state "$tmp" "x1-complete" "complete"
    seed_raw_state "$tmp" "x1-skipped" "skipped"
    seed_raw_state "$tmp" "x1-pending" "pending"
    seed_raw_state "$tmp" "x1-inprogress" "in_progress"
    seed_corrupt_state "$tmp" "x1-corrupt"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 20 node -e "
const { isWorkflowStarted } = require('$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js');
const rows = [
  ['x1-complete', true], ['x1-skipped', true], ['x1-pending', false],
  ['x1-inprogress', false], ['x1-absent', false], ['x1-corrupt', false],
];
const bad = rows.filter(([sid, want]) => isWorkflowStarted(sid) !== want).map(([sid]) => sid);
process.stdout.write(bad.length ? 'BAD:' + bad.join(',') : 'OK');" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "X1: isWorkflowStarted truth table (complete/skipped true; pending/in_progress/absent/corrupt false)"
    else
        fail "X1: truth table mismatch; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# X2: the barrel actually re-exports isWorkflowStarted on the path
#     buildExemptionDeps uses — require("./workflow-state") from hooks/
# ---------------------------------------------------------------------------
run_X2() {
    local out
    out=$("$RWT" 20 node -e "
const barrel = require('$_AGENTS_DIR_NODE/hooks/workflow-state.js');
const lifecycle = require('$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js');
const ok = typeof barrel.isWorkflowStarted === 'function' &&
  barrel.isWorkflowStarted === lifecycle.isWorkflowStarted;
process.stdout.write(ok ? 'OK' : 'BAD');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "X2: hooks/workflow-state barrel re-exports lifecycle.isWorkflowStarted (same function identity)"
    else
        fail "X2: barrel does not re-export isWorkflowStarted; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# X3: C2 fail-opens when CLAUDE_WORKFLOW_DIR points at a nonexistent path,
#     even with the scheduled-review alert armed
# ---------------------------------------------------------------------------
run_X3() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_sup_armed "$tn" "x3sid"
    C2_OUT=""; C2_RC=""
    C2_OUT=$(echo '{"stop_hook_active":false,"session_id":"x3sid","transcript_path":""}' \
        | CLAUDE_WORKFLOW_DIR="$tn/definitely-not-here" WORKFLOW_PLANS_DIR="$tn" \
          AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 25 node "$(node_path "$GUARD_C2")" 2>/dev/null)
    C2_RC=$?
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C2_RC" -eq 0 ] && ! echo "$C2_OUT" | grep -q '"block"'; then
        pass "X3: C2 fail-opens (exit 0, no block) when the workflow dir is unreadable"
    else
        fail "X3: expected fail-open exit 0 with no block (rc=$C2_RC, out=$C2_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# X4: C2 scope limitation — pre-init state but cumulative_severity=error
#     still BLOCKS. The pre-init exemption must not swallow the severity gate.
# ---------------------------------------------------------------------------
run_X4() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_preinit "$tn" "x4sid"
    seed_sup_error "$tn" "x4sid"
    run_c2 "$tn" "x4sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C2_RC" -eq 2 ] && echo "$C2_OUT" | grep -q '"decision":"block"'; then
        pass "X4: C2 still blocks on cumSev=error while workflow_init is pending"
    else
        fail "X4: expected decision:block + exit 2 for pre-init + cumSev=error (rc=$C2_RC, out=$C2_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# X5: C2 pre-init + alert_armed_at only (no severity trigger) -> silent exit 0.
#     The pre-init exemption DOES cover the scheduled-review path.
# ---------------------------------------------------------------------------
run_X5() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_preinit "$tn" "x5sid"
    seed_sup_armed "$tn" "x5sid"
    run_c2 "$tn" "x5sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C2_RC" -eq 0 ] && [ -z "$C2_OUT" ]; then
        pass "X5: C2 exits 0 silently for pre-init + alert_armed_at (scheduled review suppressed)"
    else
        fail "X5: expected silent exit 0 (rc=$C2_RC, out=$C2_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# X6 (MANDATORY paired test): same trigger as X5 but workflow_init COMPLETE
#     -> C2 must still BLOCK. Without this, an asymmetric let/destructure edit
#     that kills C2 entirely would still satisfy X3-X5 (all non-blocking).
# ---------------------------------------------------------------------------
run_X6() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "x6sid"
    seed_sup_armed "$tn" "x6sid"
    run_c2 "$tn" "x6sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C2_RC" -eq 2 ] && echo "$C2_OUT" | grep -q '"decision":"block"'; then
        pass "X6: C2 blocks on alert_armed_at once workflow_init is complete (guard is alive)"
    else
        fail "X6: C2 IS DEAD or over-suppressed — expected decision:block + exit 2 (rc=$C2_RC, out=$C2_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# X7: same input as X6 through a real spawned child process — stderr must be
#     empty. A ReferenceError from a let/destructure asymmetry (Risk #1/#2)
#     leaks a stack trace here even when the exit code happens to look right.
# ---------------------------------------------------------------------------
run_X7() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "x7sid"
    seed_sup_armed "$tn" "x7sid"
    run_c2 "$tn" "x7sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$C2_ERR" ] && [ "$C2_RC" -eq 2 ]; then
        pass "X7: spawned C2 blocks with empty stderr (no ReferenceError leak)"
    else
        fail "X7: expected exit 2 with empty stderr (rc=$C2_RC, stderr=$C2_ERR)"
    fi
}

# ---------------------------------------------------------------------------
# T17 (block side of the T11 pair): workflow_init complete but a downstream
#     step still pending -> C4 STILL blocks. Proves the pre-workflow-init
#     exemption does not over-broadly suppress legitimate C4 nudges.
# ---------------------------------------------------------------------------
run_T17() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "t17sid"
    run_c4 "$tn" "t17sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C4_RC" -eq 2 ] && echo "$C4_OUT" | grep -q '"decision":"block"'; then
        pass "T17: C4 still blocks once the workflow has started with a pending step"
    else
        fail "T17: expected decision:block + exit 2 (rc=$C4_RC, out=$C4_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# T18: pre-init C4 records ZERO supervisor findings — block-suppression and
#     record-suppression are coupled for the pre-workflow-init exemption.
# ---------------------------------------------------------------------------
run_T18() {
    local tmp tn ok
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_preinit "$tn" "t18sid"
    run_c4 "$tn" "t18sid"
    ok=0
    no_new_finding "$tmp" "t18sid" && ok=1
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] && [ "$ok" -eq 1 ]; then
        pass "T18: pre-init C4 exits silently AND records no supervisor finding"
    else
        fail "T18: expected silent exit 0 with no finding recorded (rc=$C4_RC, out=$C4_OUT, no_finding=$ok)"
    fi
}

# ---------------------------------------------------------------------------
# Z1: cleanupZombies is the marker family's sweeper. #1665 removed the
#     `.background-work` arm, so this case now drives the surviving sibling
#     `.next-step-paused` — the sweep block itself must keep working, and the
#     two properties an age sweep can silently lose are still pinned:
#       (a) containment — nothing outside the workflow dir is ever unlinked,
#           even when a same-named stale marker sits in the parent directory;
#       (b) resilience — an entry whose unlink FAILS (a directory carrying a
#           marker suffix) must not abort the sweep; the stale markers that
#           follow it in the listing are still reclaimed.
# ---------------------------------------------------------------------------
run_Z1() {
    local tmp tn wf problems=""
    tmp="$(make_tmp)"; wf="$tmp/wf"; mkdir -p "$wf"
    tn="$(node_path "$wf")"
    # (a) same-named stale markers one level up — must survive the sweep
    : > "$tmp/z1-outside.next-step-paused"
    age_file "$tmp/z1-outside.next-step-paused" 30
    # (b) an undeletable entry that sorts BEFORE the stale markers
    mkdir -p "$wf/z1-aaa.next-step-paused"
    age_file "$wf/z1-aaa.next-step-paused" 30
    : > "$wf/z1-zzz.next-step-paused"
    : > "$wf/z1-zzy.next-step-paused"
    age_file "$wf/z1-zzz.next-step-paused" 30
    age_file "$wf/z1-zzy.next-step-paused" 30
    : > "$wf/z1-fresh.next-step-paused"

    CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
    local rc=$?

    [ "$rc" -eq 0 ] || problems="$problems [sweep-threw rc=$rc]"
    [ -f "$tmp/z1-outside.next-step-paused" ] || problems="$problems [deleted-outside-marker]"
    [ ! -f "$wf/z1-zzz.next-step-paused" ] || problems="$problems [stale-marker-survived-after-failing-entry]"
    [ ! -f "$wf/z1-zzy.next-step-paused" ] || problems="$problems [stale-marker-zzy-survived-after-failing-entry]"
    [ -f "$wf/z1-fresh.next-step-paused" ] || problems="$problems [fresh-marker-deleted]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "Z1: cleanupZombies stays inside the workflow dir and keeps sweeping past an entry it cannot unlink"
    else
        fail "Z1: sweep containment/resilience broken;$problems"
    fi
}
