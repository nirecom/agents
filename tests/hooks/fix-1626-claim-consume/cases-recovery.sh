# Part of tests/hooks/fix-1626-claim-consume.sh (sourced, not standalone).
# Tests: hooks/supervisor-off-proposal-shim.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/workflow-state/state-io/zombie-cleanup.js
# Tags: off-clearance, claim, bookkeeping, recovery, zombie-cleanup, scope:issue-specific, pwsh-not-required, TL2
# C7-C11 — post-claim bookkeeping and recovery: workflow-mark consume,
# cleanupZombies sweeping, crash-residue deadlock/recovery, audit-failure policy.

# ============================================================================
# C7 — consume bookkeeping: workflow-mark's OFF activation only UNLINKS the
# .claimed file (it must never validate or claim), records off_clearance_consumed,
# and a second activation is an idempotent no-op (absent).
# ============================================================================
run_C7() {
    local tmp tn ok=1 states_before
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c7sid"

    WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
require(process.argv[1]).handle({cmd:process.argv[2],sessionId:'c7sid',pushMessage:()=>{},signalFatal:()=>{}});" \
        "$HANDLER_NODE" "$WF_BOUND" >/dev/null 2>&1

    [ -f "$tmp/c7sid.off-clearance.claimed" ] && ok=0
    grep -q "off_clearance_consumed" "$tmp/c7sid.control/supervisor-state.json" 2>/dev/null || ok=0

    # second activation → idempotent no-op (no crash, no additional consumed entry)
    states_before=$(grep -o "off_clearance_consumed" "$tmp/c7sid.control/supervisor-state.json" 2>/dev/null | wc -l | tr -d ' ')
    WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
require(process.argv[1]).handle({cmd:process.argv[2],sessionId:'c7sid',pushMessage:()=>{},signalFatal:()=>{}});" \
        "$HANDLER_NODE" "$WF_BOUND" >/dev/null 2>&1
    local states_after; states_after=$(grep -o "off_clearance_consumed" "$tmp/c7sid.control/supervisor-state.json" 2>/dev/null | wc -l | tr -d ' ')
    [ "$states_before" = "$states_after" ] || ok=0

    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C7: OFF activation unlinks the .claimed file + audits off_clearance_consumed; re-run is an idempotent no-op"
    else
        fail "C7: RED-EXPECTED (handler still consumes the BARE token, not .claimed): claimed_left/audit mismatch"
    fi
}

# ============================================================================
# C8 — zombie cleanup: an old-mtime .claimed file must be swept, and a fresh one
# preserved (CPR-ORTH counterpart — the sweep must not over-reap).
# Pattern mirrors tests/bin/fix-session-id-fixes-451-469-543/cleanup-zombies-469.sh.
# ============================================================================
backdate_node() {  # <file> <days>
    "$RWT" 10 node -e "
const fs=require('fs');const t=(Date.now()-Number(process.argv[2])*86400000)/1000;
fs.utimesSync(process.argv[1],t,t);" "$1" "$2" 2>/dev/null || true
}
run_C8() {
    local tmp tn ok=1
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c8stale"
    write_claimed "$tn" "c8fresh"
    backdate_node "$tmp/c8stale.off-clearance.claimed" 14

    CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
require(process.argv[1]).cleanupZombies(7);" "$STATE_IO_NODE" >/dev/null 2>&1

    [ -f "$tmp/c8stale.off-clearance.claimed" ] && ok=0     # must be reaped
    [ -f "$tmp/c8fresh.off-clearance.claimed" ] || ok=0     # must be preserved
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C8: cleanupZombies reaps a 14-day-old .off-clearance.claimed and preserves a fresh one"
    else
        fail "C8: RED-EXPECTED (.claimed suffix not in the cleanupZombies sweep set)"
    fi
}


# ============================================================================
# C9 - crash consistency + DOUBLE-CONSUME prevention.
# Two filesystem ops: create <sid>.off-clearance.claimed (wx), then remove bare.
# A crash between them leaves BOTH on disk. Must be fail-CLOSED deadlock (not free
# pass; covered by C4, re-asserted here as the crash SCENARIO not the
# stale-fingerprint one), and recoverable by re-minting — recovered claim token
# is STILL single-use.
# SKIPPED: true fault injection — needs debugger/patched shim; residual state
# {bare + .claimed} is constructed directly. TL3 gap: real mid-syscall kill.
# ============================================================================
run_C9() {
    local tmp tn stubbin r rc out ok=1 detail=""
    tmp=$(make_tmp); tn=$(node_path "$tmp")

    # --- (1) first claim on a clean valid token succeeds -------------------
    write_bare "$tn" "c9sid"
    r=$(run_shim "$tn" "c9sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "0" ] || { ok=0; detail="$detail first-claim-rc=$rc"; }
    is_block "$out" && { ok=0; detail="$detail first-claim-blocked"; }

    # --- (2) DOUBLE CONSUME: the very same token cannot authorize twice ----
    # After a successful claim the bare token is gone and only .claimed remains,
    # so the second proposal must be refused. This is the single-use contract.
    r=$(run_shim "$tn" "c9sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "2" ] || { ok=0; detail="$detail second-claim-rc=$rc(expected 2)"; }
    is_block "$out" || { ok=0; detail="$detail second-claim-not-blocked"; }
    local nclaim; nclaim=$(count_glob "$tmp/*.off-clearance.claimed")
    [ "$nclaim" = "1" ] || { ok=0; detail="$detail claimed-count=$nclaim"; }
    [ -f "$tmp/c9sid.off-clearance" ] && { ok=0; detail="$detail bare-reappeared"; }

    # --- (3) crash residue {bare + .claimed} is a fail-CLOSED deadlock -----
    write_bare "$tn" "c9sid"          # simulates a crash before the bare unlink
    r=$(run_shim "$tn" "c9sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "2" ] || { ok=0; detail="$detail crash-state-rc=$rc(expected 2)"; }
    is_block "$out" || { ok=0; detail="$detail crash-state-not-blocked"; }
    [ -f "$tmp/c9sid.off-clearance" ] || { ok=0; detail="$detail crash-state-bare-consumed"; }

    # --- (4) recovery: re-mint resets the stale .claimed -------------------
    stubbin=$(make_tmp)
    write_examiner_stub "$stubbin/codex" ALLOW "legit workflow bug"
    PATH="$stubbin:$PATH" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" WORKFLOW_PLANS_DIR="$tn" \
        CLAUDE_WORKFLOW_DIR="$tn" SESSION_ID="c9sid" CLAUDE_CODE_SESSION_ID="c9sid" \
        "$RWT" 40 bash "$REQ" --target workflow --category workflow-bug --detail "next-step bug" >/dev/null 2>&1
    rm -r -f "$stubbin" 2>/dev/null || true
    [ -f "$tmp/c9sid.off-clearance.claimed" ] && { ok=0; detail="$detail remint-left-stale-claim"; }

    r=$(run_shim "$tn" "c9sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "0" ] || { ok=0; detail="$detail post-remint-rc=$rc"; }
    is_block "$out" && { ok=0; detail="$detail post-remint-blocked"; }

    # --- (5) and the RECOVERED token is single-use too ---------------------
    r=$(run_shim "$tn" "c9sid" "$WF_BOUND"); rc="${r%%|*}"; out="${r#*|}"
    [ "$rc" = "2" ] || { ok=0; detail="$detail recovered-reuse-rc=$rc(expected 2)"; }
    is_block "$out" || { ok=0; detail="$detail recovered-reuse-not-blocked"; }

    rm -r -f "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C9: crash residue {bare + .claimed} deadlocks fail-CLOSED, re-mint recovers it, and NO token (original or recovered) can be consumed twice"
    else
        fail "C9: RED-EXPECTED (atomic claim / single-use not implemented):$detail"
    fi
}

# ============================================================================
# C10 - audit-write failure must NOT block the primary state transition.
# appendAudit() is non-blocking: audit loss must never block an approved override,
# but a dropped entry must be announced on stderr. Injection: pre-create the
# control-dir supervisor-state.json path (#2434) as a DIRECTORY so the audit write
# throws. Asserted: .claimed consumed, OFF marker written, exit 0, WARNING on stderr.
# ============================================================================
run_C10() {
    local tmp tn ok=1 rc err detail=""
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c10sid"
    mkdir -p "$tmp/c10sid.control/supervisor-state.json"    # force every audit write to throw

    err=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
require(process.argv[1]).handle({cmd:process.argv[2],sessionId:'c10sid',pushMessage:()=>{},signalFatal:()=>{}});" \
        "$HANDLER_NODE" "$WF_BOUND" 2>&1 >/dev/null)
    rc=$?

    [ "$rc" = "0" ] || { ok=0; detail="$detail handler-rc=$rc"; }
    [ -f "$tmp/c10sid.off-clearance.claimed" ] && { ok=0; detail="$detail claimed-not-consumed"; }
    [ -f "$tmp/c10sid.workflow-off" ] || { ok=0; detail="$detail off-marker-missing"; }
    echo "$err" | grep -qi "warning" || { ok=0; detail="$detail no-warning-on-stderr"; }

    rm -r -f "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C10: audit write forced to fail -> .claimed still consumed, OFF marker still written, exit 0, WARNING on stderr (audit loss never blocks the override)"
    else
        fail "C10: RED-EXPECTED (handler consumes the BARE token, not .claimed):$detail"
    fi
}

# ============================================================================
# C11 - cleanupZombies: IDEMPOTENCY and the CUTOFF BOUNDARY.
# C8 proves .claimed is in the sweep set. Two extra properties added here:
#   (a) idempotency — running twice must be a no-op the second time.
#   (b) cutoff boundary — 7.05d swept, 6.95d preserved (strict mtimeMs < cutoff).
#       An off-by-one or seconds-vs-ms units error fails here but not in C8.
# ============================================================================
run_C11() {
    local tmp tn ok=1 rc1 rc2 detail=""
    tmp=$(make_tmp); tn=$(node_path "$tmp")
    write_claimed "$tn" "c11old"      # just OLDER than the 7-day cutoff -> swept
    write_claimed "$tn" "c11new"      # just NEWER than the cutoff       -> preserved
    backdate_node "$tmp/c11old.off-clearance.claimed" 7.05
    backdate_node "$tmp/c11new.off-clearance.claimed" 6.95

    CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
require(process.argv[1]).cleanupZombies(7);" "$STATE_IO_NODE" >/dev/null 2>&1
    rc1=$?

    [ "$rc1" = "0" ] || { ok=0; detail="$detail first-sweep-rc=$rc1"; }
    [ -f "$tmp/c11old.off-clearance.claimed" ] && { ok=0; detail="$detail 7.05d-not-swept"; }
    [ -f "$tmp/c11new.off-clearance.claimed" ] || { ok=0; detail="$detail 6.95d-over-reaped"; }

    # (a) second sweep: idempotent - same outcome, no error, nothing new removed.
    CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 12 node -e "
require(process.argv[1]).cleanupZombies(7);" "$STATE_IO_NODE" >/dev/null 2>&1
    rc2=$?
    [ "$rc2" = "0" ] || { ok=0; detail="$detail second-sweep-rc=$rc2"; }
    [ -f "$tmp/c11old.off-clearance.claimed" ] && { ok=0; detail="$detail 7.05d-reappeared"; }
    [ -f "$tmp/c11new.off-clearance.claimed" ] || { ok=0; detail="$detail 6.95d-swept-on-rerun"; }

    rm -r -f "$tmp" 2>/dev/null || true
    if [ "$ok" = "1" ]; then
        pass "C11: cleanupZombies is idempotent across two runs and honours the exact maxAgeDays cutoff (7.05d swept, 6.95d preserved)"
    else
        fail "C11: RED-EXPECTED (.claimed suffix not in the sweep set / cutoff or idempotency wrong):$detail"
    fi
}
