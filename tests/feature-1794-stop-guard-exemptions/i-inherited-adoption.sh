# i-inherited-adoption.sh
# Tests: hooks/workflow-state/lifecycle.js, hooks/session-start.js, hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, bin/workflow/lib/next-step/verdict.js
# Tags: stop-hook, supervisor-guard, session-inherit, provenance, regression-1794, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# I1-I9 — #1794 regression: isWorkflowStarted() must judge ADOPTION (did THIS
# session record a step settlement of its own?), not the projected view. A heir
# created by session-start inherits every step_status as provenance:"backfilled"
# / origin:"session-inherit", yet projectState folds only status+updated_at, so
# the derived view is indistinguishable from a genuine complete and C4/C2 fire on
# a session that never ran /workflow-init.
#
# The shared drivers (inh_wf / inh_guard / inh_probe / inh_anchor) live in
# helpers/inheritance.sh — i-guard-robustness.sh uses them too. The TL1 predicate
# truth tables live in i-adoption-predicate.sh.
#
# Sourced by tests/feature-1794-stop-guard-exemptions.sh.

# ---------------------------------------------------------------------------
# I1: an inherited-only heir projects workflow_init=complete while EVERY
#     step_status event is backfilled — the positive anchor is asserted first so
#     a fixture that never inherited cannot hand the case a vacuous "false".
# ---------------------------------------------------------------------------
run_I1() {
    local tmp out
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i1-donor" "i1-heir" "complete"
    out=$(inh_probe "$tmp" "i1-heir" "
const ss = st.events.filter((e) => e.kind === 'step_status');
const nonBackfilled = ss.filter((e) => e.provenance !== 'backfilled')
  .map((e) => e.step + ':' + e.provenance + '/' + e.origin);
console.log('projected=' + ((st.current.steps.workflow_init || {}).status) +
  ' step_status_events=' + ss.length +
  ' non_backfilled=' + (nonBackfilled.join(',') || '0') +
  ' started=' + started());")
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "projected=complete step_status_events=3 non_backfilled=0 started=false" ]; then
        pass "I1: inherited-only heir projects complete but isWorkflowStarted is false"
    else
        fail "I1: want 'projected=complete step_status_events=3 non_backfilled=0 started=false'; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# I2: the same heir through the REAL C4 Stop hook — silent, and no supervisor
#     finding recorded (block-suppression and record-suppression are coupled).
#     The inherited-only POSITIVE ANCHOR is asserted first: without it a fixture
#     where inheritance never happened would make C4 silent for the wrong reason
#     (nothing to guard against) and hand the case a false pass.
# ---------------------------------------------------------------------------
run_I2() {
    local tmp ok anchor problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i2-donor" "i2-heir" "complete"
    anchor=$(inh_anchor "$tmp" "i2-heir")
    [ "$anchor" = "ANCHOR_OK" ] || problems="$problems [anchor:${anchor:-<err>}]"
    inh_guard c4 "$tmp" "i2-heir"
    ok=0; no_new_finding "$tmp/wf" "i2-heir" && ok=1
    rm -rf "$tmp" 2>/dev/null || true
    [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] || problems="$problems [c4 rc=$C4_RC out=$C4_OUT]"
    [ "$ok" -eq 1 ] || problems="$problems [c4-recorded-a-finding]"
    if [ -z "$problems" ]; then
        pass "I2: C4 stays silent on a verified inherited-only heir and records no finding"
    else
        fail "I2: expected inherited-only anchor + silent exit 0 with no finding;$problems"
    fi
}

# ---------------------------------------------------------------------------
# I3: same heir, C2 scheduled-review armed — the EM Supervisor review must not
#     be forced on a session that never ran /workflow-init. Same positive anchor
#     as I2, plus a second anchor on the trigger itself: alert_armed_at must
#     really be set in the supervisor state, or C2's silence proves nothing.
# ---------------------------------------------------------------------------
run_I3() {
    local tmp anchor problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i3-donor" "i3-heir" "complete"
    anchor=$(inh_anchor "$tmp" "i3-heir")
    [ "$anchor" = "ANCHOR_OK" ] || problems="$problems [anchor:${anchor:-<err>}]"
    seed_sup_armed "$(inh_wf "$tmp")" "i3-heir"
    grep -q '"alert_armed_at":"' "$tmp/wf/i3-heir-supervisor-state.json" 2>/dev/null \
        || problems="$problems [trigger-not-armed]"
    inh_guard c2 "$tmp" "i3-heir"
    rm -rf "$tmp" 2>/dev/null || true
    [ "$C2_RC" -eq 0 ] && [ -z "$C2_OUT" ] || problems="$problems [c2 rc=$C2_RC out=$C2_OUT]"
    if [ -z "$problems" ]; then
        pass "I3: C2 exits 0 silently for a verified inherited-only heir with alert_armed_at"
    else
        fail "I3: expected inherited-only anchor + armed trigger + silent exit 0;$problems"
    fi
}

# ---------------------------------------------------------------------------
# I4 (MANDATORY paired test): the SAME heir as I2/I3 plus ONE genuine markStep
#     of this session's own (origin `mark-step`) — a legitimate resume. Both
#     guards must come back to life. Without this row an implementation that
#     always returns false would satisfy I1-I3, I5, I6, I8 and I9.
# ---------------------------------------------------------------------------
run_I4() {
    local tmp problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i4-donor" "i4-heir" "complete"
    inh_node "$tmp" "require('$STATEIO_NODE').markStep('i4-heir', 'research', 'complete');"
    seed_sup_armed "$(inh_wf "$tmp")" "i4-heir"
    inh_guard c4 "$tmp" "i4-heir"
    [ "$C4_RC" -eq 2 ] || problems="$problems [c4-rc=$C4_RC]"
    echo "$C4_OUT" | grep -q '"decision":"block"' || problems="$problems [c4-not-block:$C4_OUT]"
    inh_guard c2 "$tmp" "i4-heir"
    [ "$C2_RC" -eq 2 ] || problems="$problems [c2-rc=$C2_RC]"
    echo "$C2_OUT" | grep -q '"decision":"block"' || problems="$problems [c2-not-block:$C2_OUT]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "I4: one real mark-step settlement re-arms BOTH C4 and C2 on an inherited heir"
    else
        fail "I4: guards are dead on a legitimate resume;$problems"
    fi
}

# ---------------------------------------------------------------------------
# I5: recording-only session (session_model + complexity_evaluation, no
#     step_status at all). Catches a naive "any non-backfilled event" predicate.
# ---------------------------------------------------------------------------
run_I5() {
    local tmp out
    tmp="$(make_tmp)"
    mkdir -p "$tmp/home" "$tmp/cfg" "$tmp/tr"
    mk_fixture_repo "$tmp/repo"
    seed_recording_only "$tmp" "i5-sid"
    out=$(inh_probe "$tmp" "i5-sid" "
const kinds = st.events.map((e) => e.kind).sort().join('+');
console.log('kinds=' + kinds + ' started=' + started());")
    inh_guard c4 "$tmp" "i5-sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "kinds=complexity_evaluation+session_model started=false" ] \
        && [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ]; then
        pass "I5: recording-only events do not count as adoption; C4 stays silent"
    else
        fail "I5: want 'kinds=complexity_evaluation+session_model started=false' + silent C4; got '${out:-<err>}' (rc=$C4_RC, out=$C4_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# I6: a self-recorded but UNSETTLED status (workflow_init pending, origin
#     mark-step, provenance observed) — pins the isSettledStatus condition.
# ---------------------------------------------------------------------------
run_I6() {
    local tmp out
    tmp="$(make_tmp)"
    mkdir -p "$tmp/wf" "$tmp/home" "$tmp/cfg" "$tmp/tr"
    mk_fixture_repo "$tmp/repo"
    seed_preinit "$(inh_wf "$tmp")" "i6-sid"
    out=$(inh_probe "$tmp" "i6-sid" "
const e = st.events.filter((x) => x.kind === 'step_status').pop() || {};
console.log('event=' + e.status + '/' + e.provenance + '/' + e.origin + ' started=' + started());")
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "event=pending/observed/mark-step started=false" ]; then
        pass "I6: an observed mark-step PENDING status is not adoption"
    else
        fail "I6: want 'event=pending/observed/mark-step started=false'; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# I7 (paired over-suppression check): inherited-only heir whose supervisor state
#     carries cumulative_severity=error. The adoption exemption covers the
#     scheduled-review path only — a real severity escalation must still BLOCK.
# ---------------------------------------------------------------------------
run_I7() {
    local tmp
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i7-donor" "i7-heir" "complete"
    seed_sup_error "$(inh_wf "$tmp")" "i7-heir"
    inh_guard c2 "$tmp" "i7-heir"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C2_RC" -eq 2 ] && echo "$C2_OUT" | grep -q '"decision":"block"'; then
        pass "I7: C2 still blocks on cumSev=error for an inherited-only heir"
    else
        fail "I7: expected decision:block + exit 2 (rc=$C2_RC, out=$C2_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# I8 (the C1 reproduction — the reason condition 4 exists): session-start.js
#     itself spawns bin/workflow/next-step, whose persistResolutions() calls
#     markStep(..., "complete") with the default provenance `observed`. Without
#     the ADOPTION_ORIGINS condition an inherited session gains a non-backfilled
#     settlement with ZERO user action and the whole fix is nullified.
#     (a) positive anchor — the auto-persisted clarify_intent event must really
#         be there, carrying the non-adoption origin next-step-evidence-resolution;
#     (b) the predicate is still false; (c) C4 silent + no finding; (d) C2 silent.
# ---------------------------------------------------------------------------
run_I8() {
    local tmp out ok problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i8-donor" "i8-heir" "pending"
    out=$(inh_probe "$tmp" "i8-heir" "
const e = st.events.filter((x) => x.kind === 'step_status' && x.step === 'clarify_intent').pop();
console.log('auto=' + (e ? e.status + '/' + e.provenance + '/' + e.origin : 'MISSING') +
  ' started=' + started());")
    case "$out" in
        "auto=complete/observed/next-step-evidence-resolution started=false") ;;
        *) problems="$problems [probe:$out]" ;;
    esac
    inh_guard c4 "$tmp" "i8-heir"
    [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] || problems="$problems [c4 rc=$C4_RC out=$C4_OUT]"
    ok=0; no_new_finding "$tmp/wf" "i8-heir" && ok=1
    [ "$ok" -eq 1 ] || problems="$problems [c4-recorded-a-finding]"
    seed_sup_armed "$(inh_wf "$tmp")" "i8-heir"
    inh_guard c2 "$tmp" "i8-heir"
    [ "$C2_RC" -eq 0 ] && [ -z "$C2_OUT" ] || problems="$problems [c2 rc=$C2_RC out=$C2_OUT]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "I8: next-step's own auto-persist does not count as adoption; C4/C2 stay silent"
    else
        fail "I8: C1 reproduction — want auto=complete/observed/next-step-evidence-resolution + started=false + silent C4/C2;$problems"
    fi
}

# ---------------------------------------------------------------------------
# I9: pins the INTENTIONAL asymmetry. next-step keeps honouring the inherited
#     projection (it advises the continuation of the donor's progress and does
#     NOT rewind to workflow-init), while the adoption predicate says false.
#     Both facts are asserted in ONE case so a change that "fixes" the asymmetry
#     by rewinding next-step cannot pass unnoticed.
# ---------------------------------------------------------------------------
run_I9() {
    local tmp out problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i9-donor" "i9-heir" "complete"
    run_next_step "$(inh_wf "$tmp")" "i9-heir"
    echo "$NS_OUT" | grep -q '^NEXT_SKILL=survey-code$' || problems="$problems [next-skill:$(echo "$NS_OUT" | tr '\n' ' ')]"
    echo "$NS_OUT" | grep -q 'workflow-init' && problems="$problems [rewound-to-workflow-init]"
    out=$(inh_probe "$tmp" "i9-heir" "console.log('started=' + started());")
    [ "$out" = "started=false" ] || problems="$problems [predicate:$out]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "I9: next-step still advances the inherited progress while adoption stays false"
    else
        fail "I9: asymmetry broken;$problems"
    fi
}

# I10 (the TL1 allow-list truth table), I11 (event ordering) and I14 (malformed
# / fail-CLOSED rows) live in i-adoption-predicate.sh.
# I12 (C1 sentinel hang on an inherited heir) and I13 (idempotency) live in
# i-guard-robustness.sh.
