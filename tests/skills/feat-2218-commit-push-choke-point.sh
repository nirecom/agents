#!/usr/bin/env bash
# tests/skills/feat-2218-commit-push-choke-point.sh
# Tests: skills/commit-push/SKILL.md, skills/_shared/commit-push-dispatch.md, hooks/lib/handoff-artifact.js
# Tags: commit-push, handoff, choke-point, class-d, class-e, static-check, table-driven, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 12 — the worker outcomes are the last thing a session learns before it stops, and seven of them stop it. Since #2527 the outcome lines live in skills/_shared/commit-push-dispatch.md "## Outcomes" (shared by /commit-push and /merge-to-main): every outcome keeps a line, every line names its class (record blocked / record landed), the class-to-key mapping line names commit-push:blocked / commit-push:pushed, and SKILL.md does not grow.

# TL3 gap: CP-2 is prompt text, so nothing here proves a model actually emits the recording call at runtime — only that the instruction covers all ten outcomes and that the step's size invariant holds. Full behavioral verification requires running /commit-push end to end against a real worker dispatch (all seven blocked outcomes and all three success outcomes), which no automated layer in this repo drives. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): G2 is expected to FAIL — the outcome lines carry no handoff key yet. G1/G3 are structural invariants and are GREEN by design.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
SKILL="$SCRIPT_CHECKOUT_ROOT/skills/commit-push/SKILL.md"
DISPATCH="$SCRIPT_CHECKOUT_ROOT/skills/_shared/commit-push-dispatch.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SKILL_NODE="$(node_path "$SKILL")"
DISPATCH_NODE="$(node_path "$DISPATCH")"

# The step's size at the time this contract was written. The recording must ride
# on the lines that already exist, so this number is the assertion, not a note.
CP2_BASELINE_LINES=120

# The eleven outcomes (up_to_date added by #2527) and the class each is recorded
# under: a blocked run is a D-class "why the session stopped here", a landed push
# is an E-class artifact the next session can look up.
OUTCOME_TABLE='
branch_mismatch blocked
staging_incomplete blocked
staging_check_failed blocked
gate_blocked blocked
push_failed blocked
conflict blocked
bootstrap_pending blocked
pushed landed
pr_created landed
pr_reused landed
up_to_date landed
'

# Parse the "## Outcomes" lines once and answer one question per invocation, so a
# failure names the outcome that broke rather than "the file changed".
probe() {
    local mode="$1"
    env MODE="$mode" TABLE="$OUTCOME_TABLE" \
        "$RWT" 30 node -e "
const fs = require('fs');
const lines = fs.readFileSync('$SKILL_NODE', 'utf8').split(/\r?\n/);
const dlines = fs.readFileSync('$DISPATCH_NODE', 'utf8').split(/\r?\n/);
const start = dlines.indexOf('## Outcomes');
const section = start === -1 ? [] : dlines.slice(start + 1);
const end = section.findIndex((l) => /^## /.test(l));
const outcomeLines = end === -1 ? section : section.slice(0, end);
// An outcome directive is a line of the form: On \`<outcome>\` [or \`<other>\`]: ...
const owner = new Map();
for (const line of outcomeLines) {
  if (!/^\s*On \`/.test(line)) continue;
  const head = line.slice(0, line.indexOf(':') === -1 ? line.length : line.indexOf(':'));
  for (const m of head.matchAll(/\`([a-z_]+)\`/g)) {
    if (!owner.has(m[1])) owner.set(m[1], line);
  }
}
const rows = process.env.TABLE.trim().split(/\n/).map((r) => r.trim().split(/\s+/));
const problems = [];
if (process.env.MODE === 'inventory') {
  for (const [outcome] of rows) if (!owner.has(outcome)) problems.push('no-CP-2-line-for:' + outcome);
  if (owner.size !== rows.length) problems.push('outcome-count:' + owner.size + ' want:' + rows.length + ' saw:' + [...owner.keys()].join(','));
} else if (process.env.MODE === 'keys') {
  for (const [outcome, cls] of rows) {
    const line = owner.get(outcome);
    if (!line) { problems.push('no-CP-2-line-for:' + outcome); continue; }
    if (line.toLowerCase().indexOf('record ' + cls) === -1) problems.push(outcome + '-line-records-no-' + cls);
  }
  // The class-to-key mapping is stated once (CPR-SSOT) on the Outcomes lead line.
  const mapLine = outcomeLines.find((l) => /handoff-append/.test(l)) || '';
  if (!/blocked[^;]*--class D[^;]*--key commit-push:blocked/.test(mapLine)) problems.push('no-blocked->D/commit-push:blocked-mapping');
  if (!/landed[^;]*--class E[^;]*--key commit-push:pushed/.test(mapLine)) problems.push('no-landed->E/commit-push:pushed-mapping');
} else if (process.env.MODE === 'size') {
  const n = lines[lines.length - 1] === '' ? lines.length - 1 : lines.length;
  if (n > $CP2_BASELINE_LINES) problems.push('grew-to:' + n + ' baseline:$CP2_BASELINE_LINES');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1
}

# G1 — the inventory the other two cases rest on. Ten outcomes, each owning
# exactly one CP-2 directive line; a renamed or dropped outcome invalidates the
# recording contract before any key check would notice.
run_G1() {
    local out
    out="$(probe inventory)"
    if [ "$out" = "OK" ]; then
        pass "G1: commit-push-dispatch.md Outcomes carries a directive line for each of the eleven worker outcomes and no twelfth"
    else
        fail "G1: —$out"
    fi
}

# G2 — the recording itself, table driven over the same ten rows: the seven
# stopping outcomes are recorded under commit-push:blocked (class D), the three
# landing ones under commit-push:pushed (class E). Assertion is on the line that
# already handles the outcome, which is what makes "no new lines" achievable.
run_G2() {
    local out
    out="$(probe keys)"
    if [ "$out" = "OK" ]; then
        pass "G2: every outcome line names its class, and the class line maps blocked/landed to commit-push:blocked/commit-push:pushed"
    else
        fail "G2: —$out"
    fi
}

# G3 — the invariant that keeps G2 from being satisfied the easy way. Ten new
# "also record X" lines would pass G2 and break the step: SKILL.md is a prompt
# file, and CP-2 is already its longest section.
run_G3() {
    local out
    out="$(probe size)"
    if [ "$out" = "OK" ]; then
        pass "G3: skills/commit-push/SKILL.md stays at or under its $CP2_BASELINE_LINES-line baseline — the recording rides on existing lines"
    else
        fail "G3: —$out"
    fi
}

if [ ! -f "$SKILL" ]; then
    fail "SKILL NOT FOUND: skills/commit-push/SKILL.md"
else
    run_G1
    run_G2
    run_G3
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
