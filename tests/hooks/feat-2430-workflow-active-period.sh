#!/usr/bin/env bash
# tests/hooks/feat-2430-workflow-active-period.sh
# Tests: hooks/lib/workflow-active-period.js
# Tags: handoff, workflow-active-period, truth-table, never-throw, regression-2430, scope:issue-specific, pwsh-not-required, TL1

# Issue #2430 — every handoff writer except gate-block now asks one predicate "is this session inside its workflow active period?" (workflow_init complete, final_report not complete, no WORKFLOW_OFF, no pause covering the current step). Outside that period there is no workflow to resume, so a breadcrumb is noise. One truth table pins the predicate for all of them (CPR-SSOT).

# TDD (write_code has not run): every row is expected to FAIL with "MODULE NOT FOUND" until hooks/lib/workflow-active-period.js exists.

set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

MOD="hooks/lib/workflow-active-period.js"
TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/wf" "$TMP/home"
export CLAUDE_WORKFLOW_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR="$CLAUDE_WORKFLOW_DIR"
export HOME="$(np "$TMP/home")" USERPROFILE="$(np "$TMP/home")"
export AGENTS="$(np "$AGENTS_DIR")"
cd "$TMP" || exit 1

if [ ! -f "$AGENTS_DIR/$MOD" ]; then
    fail "MODULE NOT FOUND: $MOD — expected per issue #2430, not yet implemented (write_code has not run)"
    echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# One script seeds every row, then evaluates the predicate per row. Each row
# prints `<row> <result>`; a seeding failure prints SEEDFAIL so a broken fixture
# can never read as the expected `false`.
cat > "$TMP/t1.js" <<'JS'
const fs = require('fs');
const path = require('path');
const A = process.env.AGENTS, W = process.env.CLAUDE_WORKFLOW_DIR;
const S = require(A + '/hooks/workflow-state/state-io');
const { resolveCurrentEffectiveStep } = require(A + '/hooks/workflow-state/current-step');
const out = [];
const seedActive = (sid) => {
  S.writeState(sid, S.createInitialState(sid, { cwd: '/x', git_branch: 'feature/x' }));
  S.markStep(sid, 'workflow_init', 'complete');
};
const status = (sid, step) => { try { return ((S.readState(sid).steps || {})[step] || {}).status; } catch (e) { return 'ERR'; } };
const pause = (sid, forStep, expiresInMs) => fs.writeFileSync(path.join(W, sid + '.next-step-paused'), JSON.stringify({
  version: 2, reason: 'fixture', for_step: forStep, set_at: new Date().toISOString(),
  expires_at: new Date(Date.now() + expiresInMs).toISOString(),
}));
const seeds = {};
seeds['init-pending'] = () => S.writeState('init-pending', S.createInitialState('init-pending', { cwd: '/x', git_branch: 'feature/x' }));
seeds['active'] = () => seedActive('active');
seeds['final-report-complete'] = () => { seedActive('final-report-complete'); S.markStep('final-report-complete', 'final_report', 'complete'); return status('final-report-complete', 'final_report') === 'complete'; };
seeds['workflow-off'] = () => { seedActive('workflow-off'); fs.writeFileSync(path.join(W, 'workflow-off.workflow-off'), ''); };
seeds['pause-session-wide'] = () => { seedActive('pause-session-wide'); pause('pause-session-wide', 'any', 3600000); };
seeds['pause-current-step'] = () => { seedActive('pause-current-step'); const cur = resolveCurrentEffectiveStep('pause-current-step'); if (!cur) return false; pause('pause-current-step', cur, 3600000); };
seeds['pause-other-step'] = () => { seedActive('pause-other-step'); const cur = resolveCurrentEffectiveStep('pause-other-step'); if (!cur || cur === 'write_code') return false; pause('pause-other-step', 'write_code', 3600000); };
seeds['pause-expired'] = () => { seedActive('pause-expired'); pause('pause-expired', 'any', -60000); };
seeds['corrupt-state'] = () => fs.writeFileSync(path.join(W, 'corrupt-state.json'), '{ not json');
for (const [sid, fn] of Object.entries(seeds)) {
  try { if (fn() === false) out.push(sid + ' SEEDFAIL'); } catch (e) { out.push(sid + ' SEEDFAIL:' + e.message); }
}
let mod;
try { mod = require(A + '/hooks/lib/workflow-active-period.js'); } catch (e) { out.push('require ERR:' + e.message); }
const ask = (row, sid) => {
  if (out.some((l) => l.startsWith(row + ' SEEDFAIL'))) return;
  try {
    const v = mod && mod.isWorkflowActivePeriod ? mod.isWorkflowActivePeriod(sid) : 'no-export';
    out.push(row + ' ' + (typeof v === 'boolean' ? String(v) : 'non-boolean:' + JSON.stringify(v)));
  } catch (e) { out.push(row + ' THREW:' + e.message); }
};
ask('no-state', 'no-state');
for (const sid of Object.keys(seeds)) ask(sid, sid);
const bad = [['invalid-traversal', '../escape'], ['invalid-empty', ''], ['invalid-null', null], ['invalid-space', 'a b']];
for (const [row, sid] of bad) ask(row, sid);
process.stdout.write(out.join('\n') + '\n');
JS

RESULTS="$(run_with_timeout 60 node "$(np "$TMP/t1.js")" 2>&1)"

# row <name> <expected> <why> — one truth-table row, one verdict.
row() {
    local got
    got="$(printf '%s\n' "$RESULTS" | grep -E "^$1 " | head -n 1)"
    got="${got#"$1 "}"
    if [ "$got" = "$2" ]; then
        pass "T-1 $1: isWorkflowActivePeriod -> $2 ($3)"
    else
        fail "T-1 $1: $3" "want=$2 got=${got:-<no row; script output: ${RESULTS:0:300}>}"
    fi
}

row no-state false "no state file: no workflow to resume"
row init-pending false "workflow_init not complete yet"
row active true "workflow_init complete and final_report pending"
row final-report-complete false "the terminal step final_report is complete"
row workflow-off false "a WORKFLOW_OFF marker suspends the workflow"
row pause-session-wide false "an unexpired session-wide pause"
row pause-current-step false "an unexpired pause scoped to the current step"
row pause-other-step true "a pause scoped to another step does not cover the current one"
row pause-expired true "an expired pause is not active"
row corrupt-state false "a corrupt state file reads as inactive without throwing"
row invalid-traversal false "a path-traversal sid"
row invalid-empty false "an empty sid"
row invalid-null false "a null sid"
row invalid-space false "a sid with a space"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
