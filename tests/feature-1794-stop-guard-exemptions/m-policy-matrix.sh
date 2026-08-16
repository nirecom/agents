# m-policy-matrix.sh — M1-M3: EXEMPTION_MATRIX (hooks/lib/stop-exemption-policy.js)
# cross-checked against each consumer's actual implementation. The matrix is
# declarative-only, so nothing enforces it at runtime — these cases ARE the
# enforcement. Sourced by tests/feature-1794-stop-guard-exemptions.sh.
# Tests: hooks/lib/stop-exemption-policy.js, hooks/stop-premature-stop-guard.js
# Tags: stop-hook, exemption-matrix, regression-1794, scope:issue-specific, pwsh-not-required, TL1

# ---------------------------------------------------------------------------
# M1-a: the matrix key set and the C4_EXEMPTIONS id list are identical, in the
#       same order. A row added to one and forgotten in the other is the exact
#       silent asymmetry (CPR-ORTH) the module header warns about.
# ---------------------------------------------------------------------------
run_M1a() {
    local out
    out=$("$RWT" 20 node -e "
const { EXEMPTION_MATRIX } = require('$POLICY_NODE');
const { C4_EXEMPTIONS } = require('$_AGENTS_DIR_NODE/hooks/stop-premature-stop-guard.js');
const matrix = Object.keys(EXEMPTION_MATRIX);
const table = C4_EXEMPTIONS.map((e) => e.id);
const expected = ['workflow-off','next-step-paused','pre-workflow-init','step-in-flight','delegated-reason'];
const problems = [];
if (matrix.join(',') !== table.join(',')) {
  problems.push('drift matrix=' + matrix.join(',') + ' table=' + table.join(','));
}
if (matrix.join(',') !== expected.join(',')) {
  problems.push('unexpected-rows=' + matrix.join(','));
}
process.stdout.write(problems.length ? 'BAD ' + problems.join(' | ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M1-a: EXEMPTION_MATRIX keys == C4_EXEMPTIONS ids == the 5 expected rows (same set, same order)"
    else
        fail "M1-a: matrix/table drift; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# M1-b: structural contract — the object is frozen, every row has exactly the
#       three boolean columns {c4, c2, nextStep}, and every c4 column is true
#       (C4 is the union consumer: every primitive exempts it).
# ---------------------------------------------------------------------------
run_M1b() {
    local out
    out=$("$RWT" 20 node -e "
const { EXEMPTION_MATRIX } = require('$POLICY_NODE');
const problems = [];
if (!Object.isFrozen(EXEMPTION_MATRIX)) problems.push('not-frozen');
for (const [id, row] of Object.entries(EXEMPTION_MATRIX)) {
  const cols = Object.keys(row).sort().join(',');
  if (cols !== 'c2,c4,nextStep') problems.push(id + ':cols=' + cols);
  for (const k of ['c4', 'c2', 'nextStep']) {
    if (typeof row[k] !== 'boolean') problems.push(id + ':' + k + '-not-boolean');
  }
  if (row.c4 !== true) problems.push(id + ':c4-not-true');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M1-b: matrix is frozen, every row is {c4,c2,nextStep} booleans, every c4 is true"
    else
        fail "M1-b: structural contract broken; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# M1-c: the nextStep column, cross-checked against the REAL bin/workflow/next-step
#       for every marker-backed primitive (pre-workflow-init/step-in-flight/
#       delegated-reason have no session marker — covered by M1-d/M1-e instead).
#       Each observation is positively anchored (marker on disk, a real
#       ACTION= line, the row's own REASON when paused, a real ACTION=invoke +
#       NEXT_SKILL when not, and an unmarked control run) so a broken setup
#       cannot masquerade as a passing row. See git history for the fuller
#       rationale this replaced.
# ---------------------------------------------------------------------------
run_M1c() {
    local tmp tn id suffix want reason got failures="" base_out
    for id in workflow-off next-step-paused; do
        case "$id" in
            workflow-off)     suffix="workflow-off";     reason="workflow-off-quiet" ;;
            next-step-paused) suffix="next-step-paused"; reason="next-step-paused" ;;
        esac
        want=$("$RWT" 15 node -e "
process.stdout.write(String(require('$POLICY_NODE').EXEMPTION_MATRIX['$id'].nextStep));" 2>/dev/null)
        case "$want" in
            true|false) : ;;
            *) failures="$failures [$id: matrix column unreadable: '${want:-<err>}']"; continue ;;
        esac
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        seed_started "$tn" "m1csid"

        # control run: no marker at all -> next-step must be recommending a step.
        run_next_step "$tn" "m1csid"
        base_out="$NS_OUT"
        if ! echo "$base_out" | grep -q '^ACTION=invoke$'; then
            failures="$failures [$id: control (no marker) was not ACTION=invoke: $(echo "$base_out" | tr '\n' ' ')]"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi

        if [ "$id" = "next-step-paused" ]; then
            seed_pause_marker "$tn" "m1csid"
        else
            : > "$tmp/m1csid.$suffix"
        fi
        # precondition: the marker really is on disk. Without this, a silently
        # failed seed would look exactly like a legitimate nextStep:false row.
        if [ ! -f "$tmp/m1csid.$suffix" ]; then
            failures="$failures [$id: marker m1csid.$suffix was never created — setup failed]"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi

        run_next_step "$tn" "m1csid"
        if ! echo "$NS_OUT" | grep -q '^ACTION='; then
            failures="$failures [$id: next-step produced no ACTION line: '$(echo "$NS_OUT" | tr '\n' ' ')']"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi
        if echo "$NS_OUT" | grep -q '^ACTION=paused$'; then got="true"; else got="false"; fi
        if [ "$got" != "$want" ]; then
            failures="$failures [$id: matrix=$want observed-paused=$got]"
        elif [ "$want" = "true" ]; then
            # positive anchor: the pause must carry THIS row's reason
            echo "$NS_OUT" | grep -q "^REASON='$reason'$" ||
                failures="$failures [$id: paused but REASON is not '$reason': $(echo "$NS_OUT" | tr '\n' ' ')]"
        else
            # positive anchor: a real recommendation, not merely "not paused"
            echo "$NS_OUT" | grep -q '^ACTION=invoke$' ||
                failures="$failures [$id: expected ACTION=invoke, got $(echo "$NS_OUT" | tr '\n' ' ')]"
            echo "$NS_OUT" | grep -qE '^NEXT_SKILL=.+$' ||
                failures="$failures [$id: ACTION=invoke with an empty NEXT_SKILL]"
        fi
        rm -rf "$tmp" 2>/dev/null || true
    done
    if [ -z "$failures" ]; then
        pass "M1-c: the nextStep column matches real next-step behaviour for every marker-backed row (reason-anchored, marker-attributed)"
    else
        fail "M1-c: nextStep column diverges from next-step;$failures"
    fi
}

# ---------------------------------------------------------------------------
# M1-d: the two non-marker rows are wired at the right decision phase —
#       `pre-workflow-init` is decidable from session state (phase=session),
#       `delegated-reason` only after next-step has spoken
#       (phase=next-step-output), and it is driven by DELEGATED_REASONS.
# ---------------------------------------------------------------------------
run_M1d() {
    local out
    out=$("$RWT" 20 node -e "
const g = require('$_AGENTS_DIR_NODE/hooks/stop-premature-stop-guard.js');
const byId = Object.fromEntries(g.C4_EXEMPTIONS.map((e) => [e.id, e]));
const problems = [];
const sessionRows = ['workflow-off','next-step-paused','pre-workflow-init','step-in-flight'];
for (const id of sessionRows) {
  if (!byId[id] || byId[id].phase !== 'session') problems.push(id + ':phase');
}
if (!byId['delegated-reason'] || byId['delegated-reason'].phase !== 'next-step-output') {
  problems.push('delegated-reason:phase');
}
const deps = g.buildExemptionDeps();
if (g.firstExemption('next-step-output', { sid: 'x', reason: 'pre_final_report_gate' }, deps) !== 'delegated-reason') {
  problems.push('delegated-reason:not-matched');
}
if (g.firstExemption('next-step-output', { sid: 'x', reason: 'research' }, deps) !== null) {
  problems.push('delegated-reason:over-matched');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M1-d: pre-workflow-init is phase=session; delegated-reason is phase=next-step-output and matches only pre_final_report_gate"
    else
        fail "M1-d: phase wiring wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# M1-e (#1665, generalised by #2013): the row that replaced `background-work`.
#       It is state-derived, not marker-backed, so it needs its own driver: seed
#       an in_progress step and read both columns off the REAL consumers.
#         - c4:true      -> the real C4 hook exits silently
#         - nextStep:false -> next-step keeps recommending a step (ACTION=invoke
#           with a non-empty NEXT_SKILL), the deliberate difference from the
#           removed row, whose nextStep column was true

#       Both members are driven: write_code (the original #1665 case) and
#       research (an allowlisted step, the #2013 case). The control run (same
#       session, nothing in flight) must block, so the observed silence is
#       attributable to the in-flight status alone.
# ---------------------------------------------------------------------------
run_M1e() {
    local tmp tn want step problems=""
    want=$("$RWT" 15 node -e "
process.stdout.write(String(require('$POLICY_NODE').EXEMPTION_MATRIX['step-in-flight'].nextStep));" 2>/dev/null)
    [ "$want" = "false" ] || problems="$problems [matrix nextStep column is '${want:-<err>}', expected false]"

    for step in write_code research; do
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        seed_started "$tn" "m1esid"
        # control: nothing in flight -> C4 must block
        run_c4 "$tn" "m1esid"
        [ "$C4_RC" -eq 2 ] || problems="$problems [$step control: C4 did not block with nothing in flight (rc=$C4_RC)]"

        seed_step_in_flight "$tn" "m1esid" "$step"
        run_c4 "$tn" "m1esid"
        { [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ]; } ||
            problems="$problems [$step c4:true broken — expected silent exit 0 (rc=$C4_RC, out=$C4_OUT)]"

        run_next_step "$tn" "m1esid"
        echo "$NS_OUT" | grep -q '^ACTION=paused$' &&
            problems="$problems [$step nextStep:false broken — next-step went quiet: $(echo "$NS_OUT" | tr '
' ' ')]"
        echo "$NS_OUT" | grep -q '^ACTION=invoke$' ||
            problems="$problems [$step expected ACTION=invoke, got $(echo "$NS_OUT" | tr '
' ' ')]"
        echo "$NS_OUT" | grep -qE '^NEXT_SKILL=.+$' ||
            problems="$problems [$step ACTION=invoke with an empty NEXT_SKILL]"
        rm -rf "$tmp" 2>/dev/null || true
    done

    if [ -z "$problems" ]; then
        pass "M1-e: step-in-flight is c4:true / nextStep:false for write_code AND an allowlisted step, against the real consumers"
    else
        fail "M1-e: step-in-flight columns diverge from the consumers;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M2: firstExemption() semantics — phase filtering, first-match-wins order, and
#     the fail-CLOSED throw contract (a throwing predicate is NOT exempt; its id
#     lands in `degraded` and evaluation continues to the next row).
# ---------------------------------------------------------------------------
run_M2() {
    local out
    out=$("$RWT" 20 node -e "
const { firstExemption } = require('$_AGENTS_DIR_NODE/hooks/stop-premature-stop-guard.js');
const problems = [];
const none = {
  isWorkflowOff: () => false, isNextStepPaused: () => false, isWorkflowStarted: () => true,
  anyStepInFlight: () => null,
};
// nothing holds -> null, and a session-phase hit is invisible to the other phase
if (firstExemption('session', { sid: 's' }, none) !== null) problems.push('empty-not-null');
if (firstExemption('next-step-output', { sid: 's', reason: 'pre_final_report_gate' }, none) !== 'delegated-reason') {
  problems.push('phase-filter-out');
}
if (firstExemption('session', { sid: 's', reason: 'pre_final_report_gate' }, none) !== null) {
  problems.push('phase-leak-in');
}
// first-match-wins: workflow-off precedes step-in-flight in the table
const both = Object.assign({}, none, { isWorkflowOff: () => true, anyStepInFlight: () => 'research' });
if (firstExemption('session', { sid: 's' }, both) !== 'workflow-off') problems.push('order');
// a throwing predicate is not exempt; it is recorded as degraded and the scan continues
const boom = Object.assign({}, none, {
  isWorkflowOff: () => { throw new Error('boom'); }, anyStepInFlight: () => 'research',
});
const degraded = [];
if (firstExemption('session', { sid: 's' }, boom, degraded) !== 'step-in-flight') problems.push('throw-halts-scan');
if (degraded.join(',') !== 'workflow-off') problems.push('degraded=' + degraded.join(','));
// a throwing predicate on its own never yields an exemption
const onlyBoom = Object.assign({}, none, { isWorkflowOff: () => { throw new Error('boom'); } });
if (firstExemption('session', { sid: 's' }, onlyBoom, []) !== null) problems.push('throw-treated-as-exempt');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M2: firstExemption filters by phase, is first-match-wins, and treats a throwing predicate as NOT exempt (degraded)"
    else
        fail "M2: firstExemption semantics wrong; got '${out:-<err>}'"
    fi
}

# _m3_c2_with_marker <sid> <marker-suffix|none|step-in-flight> — seed a
# started session with the C2 scheduled-review alert armed, arm the named
# exemption, run the real C2 hook. `step-in-flight` is state-derived
# (#1665/#2013) and has no marker file, so it is armed through the state store.
_m3_c2_with_marker() {
    local sid="$1" suffix="$2" tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "$sid"
    seed_sup_armed "$tn" "$sid"
    case "$suffix" in
        none) : ;;
        step-in-flight) seed_step_in_flight "$tn" "$sid" research ;;
        next-step-paused) seed_pause_marker "$tn" "$sid" ;;
        *) : > "$tmp/$sid.$suffix" ;;
    esac
    run_c2 "$tn" "$sid"
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# M3-a: the C4-only primitive (step-in-flight, c2:false) must NOT reach
#       into C2: with write_code in flight and the scheduled-review alert armed,
#       C2 still blocks, exactly as with nothing armed.
#       `delegated-reason` (also c2:false) is unreachable from C2 by
#       construction — it lives in the next-step-output phase, and C2 never
#       runs next-step.
# ---------------------------------------------------------------------------
run_M3a() {
    local suffix failures=""
    for suffix in none step-in-flight; do
        _m3_c2_with_marker "m3a-$suffix" "$suffix"
        if [ "$C2_RC" -ne 2 ] || ! echo "$C2_OUT" | grep -q '"decision":"block"'; then
            failures="$failures [$suffix: rc=$C2_RC]"
        fi
    done
    if [ -z "$failures" ]; then
        pass "M3-a: c2:false holds for step-in-flight — C2 still blocks while an allowlisted step is in flight"
    else
        fail "M3-a: a C4-only exemption suppressed C2;$failures"
    fi
}

# ---------------------------------------------------------------------------
# M3-b: workflow-off and next-step-paused are also c2:false, yet C2 IS quiet
#       for both. That is not this exemption layer: it is the pre-existing
#       blanket session-quiet layer at the top of hooks/supervisor-guard.js
#       (isWorkflowOff early-exit, and the #1607 next-step-paused quiet block
#       already covered by tests/feat-1607-next-step-pause.sh case P9).
#       The matrix's c2 column is therefore scoped to the #1794/#1685 exemption
#       layer, not to "C2 blocks". This case pins the observed behaviour so the
#       scoping stays deliberate rather than accidental.
# ---------------------------------------------------------------------------
run_M3b() {
    local suffix failures=""
    for suffix in workflow-off next-step-paused; do
        _m3_c2_with_marker "m3b-$suffix" "$suffix"
        if [ "$C2_RC" -ne 0 ] || [ -n "$C2_OUT" ]; then
            failures="$failures [$suffix: rc=$C2_RC out=$C2_OUT]"
        fi
    done
    if [ -z "$failures" ]; then
        pass "M3-b: workflow-off / next-step-paused quiet C2 through the blanket session-quiet layer, not the exemption table"
    else
        fail "M3-b: expected silent exit 0 from the blanket quiet layer;$failures"
    fi
}

# ---------------------------------------------------------------------------
# M3-c: pre-workflow-init is the only c2:true row. Its behaviour is already
#       proven by the X5/X6 pair (X5 suppressed pre-init, X6 blocks once
#       workflow_init is complete), so this case only pins the column value —
#       it deliberately does not duplicate the hook runs.
# ---------------------------------------------------------------------------
run_M3c() {
    local out
    out=$("$RWT" 15 node -e "
const { EXEMPTION_MATRIX } = require('$POLICY_NODE');
const c2true = Object.entries(EXEMPTION_MATRIX).filter(([, r]) => r.c2).map(([id]) => id);
process.stdout.write(c2true.join(',') === 'pre-workflow-init' ? 'OK' : 'BAD:' + c2true.join(','));" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "M3-c: pre-workflow-init is the only c2:true row (behaviour proven by the X5/X6 pair)"
    else
        fail "M3-c: expected pre-workflow-init as the sole c2:true row; got '${out:-<err>}'"
    fi
}
