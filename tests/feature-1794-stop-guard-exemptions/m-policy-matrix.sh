# m-policy-matrix.sh — M1-M3: EXEMPTION_MATRIX (hooks/lib/stop-exemption-policy.js)
# cross-checked against each consumer's actual implementation. The matrix is
# declarative-only, so nothing enforces it at runtime — these cases ARE the
# enforcement. Sourced by tests/feature-1794-stop-guard-exemptions.sh.

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
const expected = ['workflow-off','next-step-paused','pre-workflow-init','background-work','delegated-reason'];
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
# M1-c: the nextStep column is checked against the REAL bin/workflow/next-step
#       for every marker-backed primitive. nextStep:true must quiet next-step
#       (ACTION=paused); nextStep:false must leave it recommending a step.
#       `pre-workflow-init` and `delegated-reason` have no session marker and
#       are covered by M1-d instead.
#
#       Every observation is positively anchored, so a broken setup cannot
#       masquerade as a nextStep:false row:
#         - the marker file must EXIST before next-step is asked anything
#         - next-step must produce its 4-line contract (non-empty ACTION line)
#         - nextStep:true rows must report the row's OWN REASON, not merely
#           "some pause"
#         - nextStep:false rows must report a real recommendation
#           (ACTION=invoke + a non-empty NEXT_SKILL), not just "not paused"
#         - the same session WITHOUT the marker must be ACTION=invoke, so the
#           observed pause is attributable to the marker and nothing else
# ---------------------------------------------------------------------------
run_M1c() {
    local tmp tn id suffix want reason got failures="" base_out
    for id in workflow-off next-step-paused background-work; do
        case "$id" in
            workflow-off)     suffix="workflow-off";     reason="workflow-off-quiet" ;;
            next-step-paused) suffix="next-step-paused"; reason="next-step-paused" ;;
            background-work)  suffix="background-work";  reason="background-work-in-flight" ;;
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

        if [ "$suffix" = "background-work" ]; then
            write_bg_marker "$tmp" "m1csid" "3600000"
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
const sessionRows = ['workflow-off','next-step-paused','pre-workflow-init','background-work'];
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
  isBackgroundWorkInFlight: () => false,
};
// nothing holds -> null, and a session-phase hit is invisible to the other phase
if (firstExemption('session', { sid: 's' }, none) !== null) problems.push('empty-not-null');
if (firstExemption('next-step-output', { sid: 's', reason: 'pre_final_report_gate' }, none) !== 'delegated-reason') {
  problems.push('phase-filter-out');
}
if (firstExemption('session', { sid: 's', reason: 'pre_final_report_gate' }, none) !== null) {
  problems.push('phase-leak-in');
}
// first-match-wins: workflow-off precedes background-work in the table
const both = Object.assign({}, none, { isWorkflowOff: () => true, isBackgroundWorkInFlight: () => true });
if (firstExemption('session', { sid: 's' }, both) !== 'workflow-off') problems.push('order');
// a throwing predicate is not exempt; it is recorded as degraded and the scan continues
const boom = Object.assign({}, none, {
  isWorkflowOff: () => { throw new Error('boom'); }, isBackgroundWorkInFlight: () => true,
});
const degraded = [];
if (firstExemption('session', { sid: 's' }, boom, degraded) !== 'background-work') problems.push('throw-halts-scan');
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

# _m3_c2_with_marker <sid> <marker-suffix|none> — seed a started session with the
# C2 scheduled-review alert armed, drop the named marker, run the real C2 hook.
_m3_c2_with_marker() {
    local sid="$1" suffix="$2" tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "$sid"
    seed_sup_armed "$tn" "$sid"
    case "$suffix" in
        none) : ;;
        background-work) write_bg_marker "$tmp" "$sid" "3600000" ;;
        *) : > "$tmp/$sid.$suffix" ;;
    esac
    run_c2 "$tn" "$sid"
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# M3-a: the C4-only marker primitive (background-work, c2:false) must NOT reach
#       into C2: with the marker present and the
#       scheduled-review alert armed, C2 still blocks, exactly as with no marker.
#       `delegated-reason` (also c2:false) has no session marker and is
#       unreachable from C2 by construction — it lives in the next-step-output
#       phase, and C2 never runs next-step.
# ---------------------------------------------------------------------------
run_M3a() {
    local suffix failures=""
    for suffix in none background-work; do
        _m3_c2_with_marker "m3a-$suffix" "$suffix"
        if [ "$C2_RC" -ne 2 ] || ! echo "$C2_OUT" | grep -q '"decision":"block"'; then
            failures="$failures [$suffix: rc=$C2_RC]"
        fi
    done
    if [ -z "$failures" ]; then
        pass "M3-a: c2:false holds for background-work — C2 still blocks with the marker present"
    else
        fail "M3-a: a C4-only marker suppressed C2;$failures"
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
