#!/usr/bin/env bash
# tests/feat-2218-commit-push-choke-point.sh
# Tests: skills/commit-push/SKILL.md, hooks/lib/handoff-artifact.js
# Tags: commit-push, handoff, choke-point, class-d, class-e, static-check, table-driven, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 12 — CP-2's ten worker outcomes are the last thing a session learns before it stops, and seven of them stop it. The record is attached to the outcome lines that already exist rather than to seven new ones, so this file's job is to hold that shape: every outcome keeps a line, every line names the key its class is recorded under, and the step does not grow to get there (plan Step 12: zero net line growth).

# TL3 gap: CP-2 is prompt text, so nothing here proves a model actually emits the recording call at runtime — only that the instruction covers all ten outcomes and that the step's size invariant holds. Full behavioral verification requires running /commit-push end to end against a real worker dispatch (all seven blocked outcomes and all three success outcomes), which no automated layer in this repo drives. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): G2 is expected to FAIL — the outcome lines carry no handoff key yet. G1/G3 are structural invariants and are GREEN by design.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SKILL="$AGENTS_DIR/skills/commit-push/SKILL.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SKILL_NODE="$(node_path "$SKILL")"

# The step's size at the time this contract was written. The recording must ride
# on the lines that already exist, so this number is the assertion, not a note.
CP2_BASELINE_LINES=120

# The ten outcomes and the class each is recorded under: a blocked run is a
# D-class "why the session stopped here", a landed push is an E-class artifact
# the next session can look up.
OUTCOME_TABLE='
branch_mismatch commit-push:blocked
staging_incomplete commit-push:blocked
staging_check_failed commit-push:blocked
gate_blocked commit-push:blocked
push_failed commit-push:blocked
conflict commit-push:blocked
bootstrap_pending commit-push:blocked
pushed commit-push:pushed
pr_created commit-push:pushed
pr_reused commit-push:pushed
'

# Parse the outcome lines once and answer one question per invocation, so a
# failure names the outcome that broke rather than "the file changed".
probe() {
    local mode="$1"
    env MODE="$mode" TABLE="$OUTCOME_TABLE" \
        "$RWT" 30 node -e "
const fs = require('fs');
const text = fs.readFileSync('$SKILL_NODE', 'utf8');
const lines = text.split(/\r?\n/);
// An outcome directive is a CP-2 line of the form: On \`<outcome>\` [or \`<other>\`]: ...
const owner = new Map();
for (const line of lines) {
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
  for (const [outcome, key] of rows) {
    const line = owner.get(outcome);
    if (!line) { problems.push('no-CP-2-line-for:' + outcome); continue; }
    if (line.indexOf(key) === -1) problems.push(outcome + '-line-records-no-' + key);
  }
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
        pass "G1: CP-2 carries a directive line for each of the ten worker outcomes and no eleventh"
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
        pass "G2: every CP-2 outcome line names the handoff key its class is recorded under"
    else
        fail "G2: —$out — issue #2218 Step 12 attaches commit-push:blocked / commit-push:pushed to the existing CP-2 outcome lines; write_code has not run"
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
