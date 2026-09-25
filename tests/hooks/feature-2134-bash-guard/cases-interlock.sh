# tests/feature-2134-bash-guard/cases-interlock.sh
# Tests: hooks/lib/early-write-gate.js, hooks/bash-guard/judge.js, hooks/workflow-gate/early-gate.js
# Tags: hook, bash-guard, early-write-gate, workflow-off, precedence, scope:issue-specific, pwsh-not-required, TL2
# I1-I4: the early-write-gate interlock and its bypass precedence. Sourced by the dispatcher.

# WHY AN INTERLOCK AT ALL (codex round 1, C6). While the early write gate is actively blocking
# a pre-init session, a second deny from bash-guard buries the one message that says how to
# recover -- so the guard stays quiet exactly while the gate is armed. The trap is the bypass:
# WORKFLOW_OFF makes the gate inactive, yet a status reader that asks only "is a step pending"
# still answers active=true, silencing the guard for a whole session that has no gate at all.
# isWorkflowOff must be read FIRST, before any step scan. The rows below pin that order.

bg_write_state() {
    local sid="$1" status="$2" step steps=""
    for step in $BG_STEPS; do
        steps="$steps,\"$step\":{\"status\":\"$status\",\"updated_at\":null}"
    done
    printf '{"version":1,"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z","is_bugfix":false,"git_branch":"feature/2134-bash-guard-pretooluse","steps":{%s},"workflow_type":"wf-code"}' \
        "$sid" "${steps#,}" > "$CLAUDE_WORKFLOW_DIR/$sid.json"
}

# I1: gate armed (every step pending, no marker). Status reports active, and the guard defers
# on a command it would otherwise deny -- the early gate owns the screen.
BG_SID_ARMED="sid-bg-gate-armed"
bg_write_state "$BG_SID_ARMED" "pending"
ROWS=$((ROWS + 1))
assert_eq "I1: with a pending workflow and no marker the early write gate is active" \
    "true	workflow_init	-" "$(probe gate '' "$BG_SID_ARMED")"
assert_eq "I1: while the early gate is armed bash-guard defers instead of double-blocking" \
    "allow" "$(verdict_of 'git status && ls' "$BG_SID_ARMED")"

# I2: the same state plus a WORKFLOW_OFF marker. The gate is inactive, so nothing else is
# talking -- and bash-guard is a presentation guard the marker never bypasses, so it denies.
BG_SID_OFF="sid-bg-gate-off"
bg_write_state "$BG_SID_OFF" "pending"
: > "$CLAUDE_WORKFLOW_DIR/${BG_SID_OFF}.workflow-off"
ROWS=$((ROWS + 1))
assert_eq "I2: a WORKFLOW_OFF marker deactivates the gate and names itself as the reason" \
    "false	-	workflow-off" "$(probe gate '' "$BG_SID_OFF")"
assert_eq "I2: WORKFLOW_OFF does not disarm bash-guard (bypass precedence, C6)" \
    "deny" "$(verdict_of 'git status && ls' "$BG_SID_OFF")"

# I3: a fully complete workflow. The gate is inactive for an ordinary reason, and the guard is
# armed -- this is the steady state of nearly every session.
BG_SID_DONE="sid-bg-gate-done"
bg_write_state "$BG_SID_DONE" "complete"
ROWS=$((ROWS + 1))
assert_eq "I3: with no step pending the gate is inactive" \
    "false	-	no-pending-tier" "$(probe gate '' "$BG_SID_DONE")"
assert_eq "I3: with the gate inactive bash-guard denies a compound command" \
    "deny" "$(verdict_of 'git status && ls' "$BG_SID_DONE")"

# I4: the status reader must agree with the gate it reports on. early-gate.js decides from the
# same session, so a reader that disagrees is a second source of truth (CPR-SSOT) and puts the
# guard's silence out of step with the blocking it was meant to defer to.
i4_early() {
    local sid="$1"
    printf '%s' "{\"session_id\":\"$sid\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$AGENTS_DIR/README.md\",\"content\":\"x\"}}" \
        | run_with_timeout 30 node "$(node_path "$AGENTS_DIR/hooks/workflow-gate.js")" 2>/dev/null \
        | grep -c 'block' || true
}
ROWS=$((ROWS + 1))
assert_eq "I4/armed: earlyWriteGateStatus(active=true) matches early-gate actually blocking" \
    "1" "$(i4_early "$BG_SID_ARMED")"
ROWS=$((ROWS + 1))
assert_eq "I4/off: earlyWriteGateStatus(active=false) matches early-gate letting the write pass" \
    "0" "$(i4_early "$BG_SID_OFF")"

# I5: no session state at all -- CLAUDE_SESSION_ID absent (or set but the state file was never
# written). The gate cannot be active for a session it has no record of, and the reason must say
# WHY (no-state), not just report inactive the same way I3's completed-workflow case does --
# a reader that collapses the two would make a genuinely absent session look like "done".
#
# I5a must not pass '' as the session id: judge-probe.js's argv-defaulting (`process.argv[4] ||
# "sid-bg-armed"`) turns an empty string into "sid-bg-armed", and the dispatcher pre-seeds a
# fully-complete state for exactly that session (bg_settled_state "sid-bg-armed" in
# feature-2134-bash-guard.sh) -- so an empty-string probe would hit the SAME all-complete state
# I3 queries, not genuine absence. Use an explicit sentinel id with no state file at all instead.
BG_SID_NO_STATE="sid-bg-gate-no-state"
BG_SID_NO_STATE_AT_ALL="sid-bg-gate-no-state-whatsoever"
ROWS=$((ROWS + 1))
assert_eq "I5a: a session id with no state file on disk (not the argv-default fallback) reports inactive with reason no-state" \
    "false	-	no-state" "$(probe gate '' "$BG_SID_NO_STATE_AT_ALL")"
ROWS=$((ROWS + 1))
assert_eq "I5b: a session id with no state file on disk also reports inactive with reason no-state" \
    "false	-	no-state" "$(probe gate '' "$BG_SID_NO_STATE")"

# SKIPPED: the pendingTier=Tier2/Tier3 variants of I1.
# Because: the interlock branches on active vs inactive only -- which tier is pending changes
#          the early gate's message, not whether bash-guard defers.
# L3 gap: a live session where the gate flips mid-conversation; only an end-to-end run shows
#          the guard re-arming at the moment workflow_init completes.
