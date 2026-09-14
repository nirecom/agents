# allowlist-matrix.sh — L9: the L1/L2 verdict matrix for the OTHER allowlist
# members. Sourced by tests/fix-2279-lookahead-pending-readers.sh.
# Tests: hooks/workflow-state/lifecycle.js, hooks/workflow-state/inheritance/adopt.js, hooks/lib/step-in-flight-policy.js
# Tags: resume-session, adoption, wi-10-lookahead, step-in-flight, allowlist, matrix, regression-2279, scope:issue-specific, pwsh-not-required, TL1

_m_trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# L1-L5 measure `research`, the only step the lookahead can SYNTHESIZE
# (LOOKAHEAD_PREINIT_STEP) — but #2013's auto-mark stamps the same
# `postuse-in-flight` origin on whichever allowlisted step is current when a
# subagent is dispatched, so the adoption readers meet a lookahead-origin
# `detail` / `write_tests` / `review_tests` mark just as routinely.

# Both readers are asserted per row: lifecycle.isEffectivelyPendingStep and
# adopt.isAllPending, the gate that consumes it. Asserting only the predicate
# would let a consumer that never calls it pass.

# `-` in the origin column means markStep's own default. Only the two "records
# nothing of the session's own" shapes read as effectively pending.
_m_table() {
    cat <<'EOF'
# step         | status      | origin             | effectively pending?
detail         | pending     | -                  | true
detail         | in_progress | postuse-in-flight  | true
detail         | in_progress | mark-step          | false
detail         | complete    | -                  | false
detail         | skipped     | -                  | false
write_tests    | pending     | -                  | true
write_tests    | in_progress | postuse-in-flight  | true
write_tests    | in_progress | mark-step          | false
write_tests    | complete    | -                  | false
write_tests    | skipped     | -                  | false
review_tests   | pending     | -                  | true
review_tests   | in_progress | postuse-in-flight  | true
review_tests   | in_progress | mark-step          | false
review_tests   | complete    | -                  | false
review_tests   | skipped     | -                  | false
EOF
}

# One node process for the whole table: every row is a separate sid inside one
# fixture store, so the 15 rows cost one spawn rather than thirty.
run_L9() {
    local tmp tn rows="" step status origin want problems
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    while IFS='|' read -r step status origin want; do
        step="$(_m_trim "$step")"
        case "$step" in ''|'#'*) continue ;; esac
        rows="$rows$step:$(_m_trim "$status"):$(_m_trim "$origin"):$(_m_trim "$want") "
    done <<EOF
$(_m_table)
EOF

    problems=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" ROWS="$rows" "$RWT" 60 node -e "
const io = require('$SIO');
const { isEffectivelyPendingStep } = require('$LIFECYCLE');
const { isAllPending } = require('$ADOPT');
const CA = require('$COMPLETION_APPROVAL');
const bad = [];
let seen = 0;
for (const row of String(process.env.ROWS).trim().split(/\s+/)) {
  seen++;
  const [step, status, origin, want] = row.split(':');
  const sid = ['m', step, status, origin].join('-');
  const label = step + '/' + status + '/' + origin;
  // outline/detail ->complete is approval-gated (#1133): without a recorded
  // approval markStep throws and the row would silently seed nothing.
  if (status === 'complete' && CA.isApprovalGatedStep(step)) {
    CA.recordPlanApproval(sid, step, { source: 'reset-sentinel', reason: '2279 L9 fixture' });
  }
  try {
    io.markStep(sid, step, status, {}, origin === '-' ? undefined : { provenance: 'observed', origin });
  } catch (e) {
    bad.push(label + ':seed-threw:' + e.message);
    continue;
  }
  const state = io.readState(sid);
  const onDisk = state && state.steps && state.steps[step] && state.steps[step].status;
  if (onDisk !== status) { bad.push(label + ':fixture-status=' + onDisk); continue; }
  const wantBool = want === 'true';
  const eff = isEffectivelyPendingStep(state, step);
  const ap = isAllPending(state);
  if (eff !== wantBool) bad.push(label + ':isEffectivelyPendingStep=' + eff + '(want ' + wantBool + ')');
  if (ap !== wantBool) bad.push(label + ':isAllPending=' + ap + '(want ' + wantBool + ')');
}
// The OK token, not silence, is the pass signal: a module that failed to load
// would print nothing, and an emptiness test would read that as a clean table.
if (seen !== 15) bad.push('rows-evaluated=' + seen + '(want 15)');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' ') : 'OK');" 2>/dev/null)

    rm -rf "$tmp" 2>/dev/null || true
    if [ "$problems" = "OK" ]; then
        pass "L9: the lookahead-pending matrix holds for detail, write_tests and review_tests too — both readers discount a lookahead-origin in_progress and keep honouring every other recorded status (CPR-ORTH with L1/L2)"
    else
        fail "L9: the allowlist members other than 'research' disagree with the L1/L2 verdicts; $problems"
    fi
}

# L10: the COMPOSITE axis. Every L9 row is a state whose ONLY record is that
# row's step, so isAllPending is never asked its real question — "is every OTHER
# step still pending while THIS one is promoted?" — which is the shape the WI-10
# lookahead meets in life. A reader answering from the promoted step alone
# passes all 15 L9 rows and still lets an adoption bulldoze recorded work.

# Fixed axis: the promoted step is lookahead-marked in every row. Varying axis:
# the one other step the state also carries.
_m_composite_table() {
    cat <<'EOF'
# promoted     | other          | other status | other origin      | all pending?
detail         | -              | -            | -                 | true
detail         | workflow_init  | complete     | -                 | false
detail         | clarify_intent | in_progress  | mark-step         | false
detail         | research       | in_progress  | postuse-in-flight | true
write_tests    | -              | -            | -                 | true
write_tests    | workflow_init  | complete     | -                 | false
write_tests    | clarify_intent | in_progress  | mark-step         | false
write_tests    | research       | in_progress  | postuse-in-flight | true
review_tests   | -              | -            | -                 | true
review_tests   | workflow_init  | complete     | -                 | false
review_tests   | clarify_intent | in_progress  | mark-step         | false
review_tests   | research       | in_progress  | postuse-in-flight | true
EOF
}

run_L10() {
    local tmp tn rows="" promoted other status origin want problems
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    while IFS='|' read -r promoted other status origin want; do
        promoted="$(_m_trim "$promoted")"
        case "$promoted" in ''|'#'*) continue ;; esac
        rows="$rows$promoted:$(_m_trim "$other"):$(_m_trim "$status"):$(_m_trim "$origin"):$(_m_trim "$want") "
    done <<EOF
$(_m_composite_table)
EOF

    problems=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" ROWS="$rows" "$RWT" 60 node -e "
const io = require('$SIO');
const { isEffectivelyPendingStep } = require('$LIFECYCLE');
const { isAllPending } = require('$ADOPT');
const bad = [];
let seen = 0;
for (const row of String(process.env.ROWS).trim().split(/\s+/)) {
  seen++;
  const [promoted, other, status, origin, want] = row.split(':');
  const sid = ['c', promoted, other, status].join('-');
  const label = promoted + '+' + other + '/' + status + '/' + origin;
  try {
    io.markStep(sid, promoted, 'in_progress', {}, { provenance: 'observed', origin: 'postuse-in-flight' });
    if (other !== '-') {
      io.markStep(sid, other, status, {}, origin === '-' ? undefined : { provenance: 'observed', origin });
    }
  } catch (e) {
    bad.push(label + ':seed-threw:' + e.message);
    continue;
  }
  const state = io.readState(sid);
  const steps = (state && state.steps) || {};
  // Fixture anchors: both records must be on disk in the shape the row names.
  if (!steps[promoted] || steps[promoted].status !== 'in_progress') {
    bad.push(label + ':fixture-promoted=' + (steps[promoted] && steps[promoted].status));
    continue;
  }
  if (other !== '-' && (!steps[other] || steps[other].status !== status)) {
    bad.push(label + ':fixture-other=' + (steps[other] && steps[other].status));
    continue;
  }
  // A false row must turn on the OTHER step, never on the discount lapsing for
  // the promoted one — which is lookahead-marked in every row.
  if (isEffectivelyPendingStep(state, promoted) !== true) {
    bad.push(label + ':promoted-not-effectively-pending');
  }
  const wantBool = want === 'true';
  const ap = isAllPending(state);
  if (ap !== wantBool) bad.push(label + ':isAllPending=' + ap + '(want ' + wantBool + ')');
}
if (seen !== 12) bad.push('rows-evaluated=' + seen + '(want 12)');
process.stdout.write(bad.length ? 'BAD:' + bad.join(' ') : 'OK');" 2>/dev/null)

    rm -rf "$tmp" 2>/dev/null || true
    if [ "$problems" = "OK" ]; then
        pass "L10: with a lookahead-marked detail / write_tests / review_tests AND a second recorded step, isAllPending answers from the whole state — still adoptable when the other step is pending or lookahead-marked, refused as soon as one step carries the session's own work"
    else
        fail "L10: isAllPending's whole-state verdict is wrong for a lookahead-promoted allowlist step alongside another record; $problems"
    fi
}
