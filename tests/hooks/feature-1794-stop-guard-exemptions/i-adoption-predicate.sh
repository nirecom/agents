# i-adoption-predicate.sh
# Tests: hooks/workflow-state/lifecycle.js, hooks/workflow-state/state-io/events.js
# Tags: stop-hook, session-inherit, provenance, regression-1794, scope:issue-specific, pwsh-not-required, TL1
#
# I10 / I10b / I11 / I14 — the TL1 truth tables for hasSelfRecordedStepSettlement,
# the #1794 adoption predicate. It answers ONE question about a raw state record:
# did THIS session record a step settlement of its own? That is the AND of four
# conditions on a single event —
#   1. kind === 'step_status'
#   2. genuine provenance (observed | declared; never backfilled)
#   3. isSettledStatus(status) (complete | skipped)
#   4. origin is in the ADOPTION_ORIGINS allow-list (mark-step)
#
# I10 varies exactly ONE field at a time off a known-true baseline, so a row's
# expected value can only be explained by the field that moved (mutation
# detection). I10b keeps the multi-field combinatorial rows for the shapes that
# actually occur in the wild. I11 pins event ORDERING. I14 pins the fail-CLOSED
# contract for malformed input (detail.md D5).
#
# Sourced by tests/feature-1794-stop-guard-exemptions.sh.

# pred_eval <js> — runs <js> (which must define `rows` as [label, state, want][])
# against the WORKTREE copy of lifecycle.js. In scope for <js>:
#   BASE  the genuine baseline event (step_status/complete/observed/mark-step)
#   ev(o) BASE with o merged in (multi-field rows)
#   one(o) BASE with the single override o applied; a value of `undefined`
#          DELETES the field instead of setting it
# Echoes OK or BAD:<per-row diagnostics>. A row whose evaluation throws reports
# got='THREW:...' rather than crashing the harness, so "predicate never throws"
# is observable in the failure text.
pred_eval() {
    "$RWT" 20 node -e "
const L = require('$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js');
const fn = L.hasSelfRecordedStepSettlement;
if (typeof fn !== 'function') { process.stdout.write('BAD:hasSelfRecordedStepSettlement-not-exported'); process.exit(0); }
const BASE = Object.freeze({ kind: 'step_status', step: 'research', status: 'complete', provenance: 'observed', origin: 'mark-step' });
const ev = (o) => Object.assign({}, BASE, o);
const one = (o) => {
  const e = Object.assign({}, BASE);
  for (const k of Object.keys(o)) { if (o[k] === undefined) delete e[k]; else e[k] = o[k]; }
  return { events: [e] };
};
$1
const bad = [];
for (const row of rows) {
  const [label, state, want] = row;
  let got;
  try { got = fn(state); } catch (e) { got = 'THREW:' + e.message; }
  if (got !== want) bad.push(label + '(want=' + want + ',got=' + JSON.stringify(got) + ')');
}
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');" 2>&1
}

# ---------------------------------------------------------------------------
# I10: SINGLE-VARIABLE truth table. Every row is the genuine baseline with
#      exactly one field changed or deleted, so no row can pass by accident:
#      flipping one condition of the four-way AND must flip the answer, and
#      moving within a condition's accepted set must NOT. The `one()` builder
#      plus the arity self-check below make the single-variable property
#      structural rather than a comment.
# ---------------------------------------------------------------------------
run_I10() {
    local out
    out=$(pred_eval "
const flips = [
  // --- baseline: zero fields changed, must be true ---
  ['00-baseline-step_status/complete/observed/mark-step', {}, true],
  // --- condition 1: kind ---
  ['01-kind=session_model', { kind: 'session_model' }, false],
  ['02-kind=complexity_evaluation', { kind: 'complexity_evaluation' }, false],
  ['03-kind=worktree', { kind: 'worktree' }, false],
  ['04-kind=plan_approval', { kind: 'plan_approval' }, false],
  ['05-kind-deleted', { kind: undefined }, false],
  // --- condition 2: provenance ---
  ['06-provenance=declared', { provenance: 'declared' }, true],
  ['07-provenance=backfilled', { provenance: 'backfilled' }, false],
  ['08-provenance=unknown-value', { provenance: 'guessed' }, false],
  ['09-provenance-deleted', { provenance: undefined }, false],
  // --- condition 3: settled status ---
  ['10-status=skipped', { status: 'skipped' }, true],
  ['11-status=pending', { status: 'pending' }, false],
  ['12-status=in_progress', { status: 'in_progress' }, false],
  ['13-status-deleted', { status: undefined }, false],
  // --- condition 4: origin allow-list ---
  ['14-origin=session-inherit', { origin: 'session-inherit' }, false],
  ['15-origin=next-step-evidence-resolution', { origin: 'next-step-evidence-resolution' }, false],
  ['16-origin=next-step-recorded-verdict-skip', { origin: 'next-step-recorded-verdict-skip' }, false],
  ['17-origin=unknown-future-writer', { origin: 'some-new-automation' }, false],
  ['18-origin-deleted', { origin: undefined }, false],
];
const rows = [];
for (const [label, o, want] of flips) {
  // Structural guard: more than one override would make the row a
  // multi-variable row masquerading as a single-variable one. Emit an
  // always-failing row rather than silently accepting it.
  if (Object.keys(o).length > 1) { rows.push([label + '-IS-NOT-SINGLE-VARIABLE', null, true]); continue; }
  rows.push([label, one(o), want]);
}")
    if [ "$out" = "OK" ]; then
        pass "I10: hasSelfRecordedStepSettlement single-variable truth table (18 one-field flips off a true baseline)"
    else
        fail "I10: single-variable truth table mismatch; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# I10b: the combinatorial rows — the whole-event shapes that actually appear in
#       a live state stream, kept alongside I10 because a real event moves
#       several fields at once and the predicate must judge the combination.
# ---------------------------------------------------------------------------
run_I10b() {
    local out
    out=$(pred_eval "
const rows = [
  ['1-mark-step-complete', { events: [ev({ status: 'complete', provenance: 'observed', origin: 'mark-step' })] }, true],
  ['2-mark-step-skipped-declared', { events: [ev({ status: 'skipped', provenance: 'declared', origin: 'mark-step' })] }, true],
  ['3-next-step-evidence-resolution', { events: [ev({ status: 'complete', provenance: 'observed', origin: 'next-step-evidence-resolution' })] }, false],
  ['4-next-step-recorded-verdict-skip', { events: [ev({ status: 'skipped', provenance: 'observed', origin: 'next-step-recorded-verdict-skip' })] }, false],
  ['5-session-inherit-backfilled', { events: [ev({ status: 'complete', provenance: 'backfilled', origin: 'session-inherit' })] }, false],
  ['6-mark-step-pending', { events: [ev({ status: 'pending', provenance: 'observed', origin: 'mark-step' })] }, false],
  ['7-session-model', { events: [{ kind: 'session_model', id: 'claude-opus-5', source: 'transcript', provenance: 'observed', origin: 'record-session-model' }] }, false],
  ['8-complexity-evaluation', { events: [{ kind: 'complexity_evaluation', level: 'high', signals: ['S1'], provenance: 'observed', origin: 'record-complexity-evaluation' }] }, false],
];")
    if [ "$out" = "OK" ]; then
        pass "I10b: hasSelfRecordedStepSettlement combinatorial rows (real-world event shapes)"
    else
        fail "I10b: combinatorial truth table mismatch; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# I11: EVENT ORDERING. Adoption is a property of the stream, not of its last
#      record, so it must be order-INDEPENDENT in one direction (later
#      auto/backfilled noise never erases a real settlement) and order-SENSITIVE
#      in the other (a stream is not adopted until the genuine event is
#      appended). The `*-before` rows are the exact prefixes of their `*-after`
#      counterparts, so the pair pins the transition point itself.
# ---------------------------------------------------------------------------
run_I11() {
    local out
    out=$(pred_eval "
const GEN  = ev({ step: 'research', status: 'complete', provenance: 'observed', origin: 'mark-step' });
const INH  = ev({ step: 'workflow_init', status: 'complete', provenance: 'backfilled', origin: 'session-inherit' });
const AUTO = ev({ step: 'clarify_intent', status: 'complete', provenance: 'observed', origin: 'next-step-evidence-resolution' });
const MODEL = { kind: 'session_model', id: 'claude-opus-5', source: 'transcript', provenance: 'observed', origin: 'record-session-model' };
const rows = [
  // (a) genuine first, noise appended afterwards -> stays true
  ['a1-genuine-only', { events: [GEN] }, true],
  ['a2-genuine-then-inherited', { events: [GEN, INH] }, true],
  ['a3-genuine-then-auto-then-inherited', { events: [GEN, AUTO, INH, MODEL] }, true],
  // (b) noise first, genuine appended later -> becomes true at that point
  ['b1-noise-prefix-before', { events: [INH, INH, AUTO, MODEL] }, false],
  ['b2-noise-prefix-then-genuine', { events: [INH, INH, AUTO, MODEL, GEN] }, true],
  // (c) genuine sandwiched in the middle — position is irrelevant
  ['c1-genuine-in-the-middle', { events: [INH, GEN, AUTO] }, true],
  // (d) same events, genuine removed -> false (the (c) row minus one record)
  ['d1-same-stream-without-the-genuine-event', { events: [INH, AUTO] }, false],
];")
    if [ "$out" = "OK" ]; then
        pass "I11: adoption is position-independent and only becomes true once a genuine settlement is appended"
    else
        fail "I11: event-ordering mismatch; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# I14: malformed input must fail CLOSED (detail.md D5) — falsy state, non-array
#      events, empty events, non-object elements at any position, and an
#      exception raised during evaluation all return `false`, and none of them
#      may escape as a throw. `got='THREW:...'` in the diagnostics is the
#      throw-escaped signal. The positive control keeps the case non-vacuous:
#      an implementation that returns a hardcoded `false` fails on it.
# ---------------------------------------------------------------------------
run_I14() {
    local out
    out=$(pred_eval "
const GEN = ev({ status: 'complete', provenance: 'observed', origin: 'mark-step' });
const INH = ev({ status: 'complete', provenance: 'backfilled', origin: 'session-inherit' });
const AUTO = ev({ status: 'complete', provenance: 'observed', origin: 'next-step-evidence-resolution' });
const boomState = { get events() { throw new Error('boom-state'); } };
const boomElement = new Proxy({}, { get() { throw new Error('boom-element'); } });
const rows = [
  // --- positive control (non-vacuity) ---
  ['00-control-genuine', { events: [GEN] }, true],
  // --- state itself falsy ---
  ['01-state-null', null, false],
  ['02-state-undefined', undefined, false],
  ['03-state-false', false, false],
  ['04-state-empty-string', '', false],
  ['05-state-zero', 0, false],
  // --- events missing entirely ---
  ['06-events-missing', { session_id: 'x', steps: {} }, false],
  ['07-events-null', { events: null }, false],
  ['08-events-undefined', { events: undefined }, false],
  // --- events present but not an array ---
  ['09-events-string', { events: 'step_status' }, false],
  ['10-events-object', { events: { 0: GEN, length: 1 } }, false],
  ['11-events-number', { events: 42 }, false],
  ['12-events-boolean', { events: true }, false],
  ['13-events-function', { events: () => [GEN] }, false],
  // --- events an empty array ---
  ['14-events-empty-array', { events: [] }, false],
  // --- non-object elements, at every position ---
  ['15-element-null-only', { events: [null] }, false],
  ['16-element-undefined-only', { events: [undefined] }, false],
  ['17-element-string-only', { events: ['step_status'] }, false],
  ['18-element-number-only', { events: [42] }, false],
  ['19-element-null-first', { events: [null, INH] }, false],
  ['20-element-null-last', { events: [INH, null] }, false],
  ['21-element-null-middle', { events: [INH, null, AUTO] }, false],
  ['22-element-mixed-junk', { events: [null, 'x', 42, undefined, false] }, false],
  // --- object elements missing the fields the predicate reads ---
  ['23-element-empty-object', { events: [{}] }, false],
  ['24-element-missing-kind', { events: [{ step: 'research', status: 'complete', provenance: 'observed', origin: 'mark-step' }] }, false],
  ['25-element-kind-only', { events: [{ kind: 'step_status' }] }, false],
  ['26-element-array', { events: [[]] }, false],
  // --- an exception raised while evaluating ---
  ['27-events-getter-throws', boomState, false],
  ['28-element-getter-throws', { events: [boomElement] }, false],
];")
    if [ "$out" = "OK" ]; then
        pass "I14: hasSelfRecordedStepSettlement fails CLOSED on every malformed shape and never throws"
    else
        fail "I14: malformed-input contract broken (THREW=escaped exception); got '${out:-<err>}'"
    fi
}
