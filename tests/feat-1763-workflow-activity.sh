#!/usr/bin/env bash
# tests/feat-1763-workflow-activity.sh
# Tests: hooks/lib/workflow-activity.js
# Tags: issue-create, provenance, workflow-activity, layer-c, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - A real in-flight workflow session's state file shape drifting from the fixture.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S10c: isWorkflowActive() — the vocabulary-independent third provenance observation
# point. Contract: wsid unresolvable → inactive; readRawState() null → inactive;
# a workflow is active only while it is PART WAY through — some step already off
# "pending" AND some step not yet terminal. Never started (all "pending") and finished
# (all complete/skipped) are both inactive; anything unreadable is active (fail-closed).
# It must use readRawState (raw file) — NOT readState (synthesizing) — so that a
# session with no state file on disk is reported inactive.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
MOD="$AGENTS_DIR/hooks/lib/workflow-activity.js"
STATE_IO="$AGENTS_DIR/hooks/workflow-state/state-io.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

MOD_PRESENT=no; [ -f "$MOD" ] && MOD_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

WSID="20990101-000000"

# new_env <name> → creates $WORK/<name>/{state,plans,cwd} and echoes the base dir.
# cwd carries WORKTREE_NOTES.md so resolveWorkflowSessionId() priority 1 pins the wsid.
new_env() {
    local base="$WORK/$1"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: %s\n' "$WSID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$WSID-intent.md"
    printf '%s' "$base"
}

# write_state <base> <steps-json>
write_state() {
    STEPS="$2" "$RWT" 12 node -e "
const fs = require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  version: 1, session_id: '$WSID', created_at: new Date().toISOString(),
  workflow_type: 'wf-code', steps: JSON.parse(process.env.STEPS)
}));" "$(node_path "$1/state/$WSID.json")" 2>/dev/null
}

# probe <base> [--no-notes] → "active" | "inactive" | "<missing>"
probe() {
    local base="$1"; shift
    [ "$MOD_PRESENT" = "yes" ] || { printf '<missing>'; return; }
    # Config pinning (rules/test.md): workflow activity is a property of the
    # workflow state alone. Both switches are declared here so a developer .env
    # that turns provenance off cannot make the probe answer differently.
    ( cd "$base/cwd" 2>/dev/null || exit 1
      CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
      WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
      CLAUDE_CODE_SESSION_ID="$WSID" \
      ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        "$RWT" 15 node -e "
try {
  const m = require(process.argv[1]);
  process.stdout.write(m.isWorkflowActive() ? 'active' : 'inactive');
} catch (e) { process.stdout.write('err:' + e.message); }
" "$(node_path "$MOD")" 2>/dev/null )
}

check() {  # <label> <want> <base>
    local got; got=$(probe "$3")
    if [ "$got" = "<missing>" ]; then
        fail "$1" "RED-EXPECTED: hooks/lib/workflow-activity.js not yet created (want=$2)"
    else
        assert_eq "$1" "$2" "$got"
    fi
}

ALL_PENDING='{"research":{"status":"pending"},"write_tests":{"status":"pending"},"write_code":{"status":"pending"}}'
ONE_COMPLETE='{"research":{"status":"complete"},"write_tests":{"status":"pending"},"write_code":{"status":"pending"}}'
ONE_INPROGRESS='{"research":{"status":"pending"},"write_tests":{"status":"in_progress"},"write_code":{"status":"pending"}}'
ONLY_SKIPPED='{"research":{"status":"skipped"},"write_tests":{"status":"pending"},"write_code":{"status":"pending"}}'

echo "=== isWorkflowActive() — S10c contract ==="

# W1: no state file at all → inactive.
B1=$(new_env w1)
check "W1-no-state-file-inactive" "inactive" "$B1"

# W2: state file present, every step pending → inactive.
B2=$(new_env w2); write_state "$B2" "$ALL_PENDING"
check "W2-all-pending-inactive" "inactive" "$B2"

# W3: one step complete → active.
B3=$(new_env w3); write_state "$B3" "$ONE_COMPLETE"
check "W3-one-complete-active" "active" "$B3"

# W4: one step in_progress → active.
B4=$(new_env w4); write_state "$B4" "$ONE_INPROGRESS"
check "W4-one-in-progress-active" "active" "$B4"

# W5: a deliberately skipped step is a real workflow decision → active.
B5=$(new_env w5); write_state "$B5" "$ONLY_SKIPPED"
check "W5-skipped-step-active" "active" "$B5"

# W6: wsid unresolvable (no WORKTREE_NOTES.md, no plan artifacts, no env sid) → inactive.
B6="$WORK/w6"; mkdir -p "$B6/state" "$B6/plans" "$B6/cwd"
if [ "$MOD_PRESENT" != "yes" ]; then
    fail "W6-no-wsid-inactive" "RED-EXPECTED: hooks/lib/workflow-activity.js not yet created (want=inactive)"
else
    GOT=$( cd "$B6/cwd" && \
        CLAUDE_WORKFLOW_DIR="$(node_path "$B6/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$B6/plans")" \
        CLAUDE_CODE_SESSION_ID="" CLAUDE_SESSION_ID="" CLAUDE_ENV_FILE="" \
        ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
            "$RWT" 15 node -e "
try { const m = require(process.argv[1]);
  process.stdout.write(m.isWorkflowActive() ? 'active' : 'inactive');
} catch (e) { process.stdout.write('err:' + e.message); }
" "$(node_path "$MOD")" 2>/dev/null )
    assert_eq "W6-no-wsid-inactive" "inactive" "$GOT"
fi

echo ""
echo "=== absence vs ignorance: only evidence of absence may answer 'inactive' ==="
# W1 and W9 are the same observation from opposite sides, and the module reaches both
# through the SAME `readRawState() === null`. Absence — no file — is evidence: nothing
# is running, so layer C may hand `user-explicit` on. Ignorance — a file that is there
# but cannot be read — is not evidence of anything, and answering `inactive` there
# would grant the highest privilege precisely when observation failed. Without W9 the
# module could collapse both into one `return false` and W1 would still be green.

# W9: state file present but unparseable → active (fail-closed).
B9=$(new_env w9)
printf '%s' '{"version":1,"steps":{"research":{"status":"pen' > "$B9/state/$WSID.json"
check "W9-unparseable-state-active" "active" "$B9"

# W10: parseable, but not the shape the module knows how to interpret. Same class as
# W9 — the module cannot tell whether a workflow is running, so it must not say no.
B10=$(new_env w10)
printf '%s' '["research","write_code"]' > "$B10/state/$WSID.json"
check "W10-unexpected-shape-active" "active" "$B10"

# W11: valid object, `steps` absent entirely. Distinct from W2 (steps present, all
# pending = a real workflow that has not started): here there is nothing to read a
# status from, which is ignorance again, not an all-pending workflow.
B11=$(new_env w11)
printf '%s' '{"version":1,"session_id":"'"$WSID"'","workflow_type":"wf-code"}' \
    > "$B11/state/$WSID.json"
check "W11-steps-absent-active" "active" "$B11"

# W12: an empty steps map. The module reads it as "no step has moved off pending",
# same as W2 — pinned because it is the boundary between W2 and W11 and the two
# neighbours disagree, so a refactor could silently move this row either way.
B12=$(new_env w12); write_state "$B12" '{}'
check "W12-empty-steps-inactive" "inactive" "$B12"

echo ""
echo "=== in flight vs finished: only a PART WAY through workflow is active ==="
# "Some step is off pending" is true forever once a session has run, so on its own it
# makes every later turn on the machine read as mid-workflow and layer C stops
# classifying anything ever again — the failure is silent and permanent, which is why
# W3/W4/W5 alone could not catch it. In flight means BOTH halves hold: something has
# started AND something has not finished. Never-started (W2) and finished (W13/W14)
# are the two ends, and both are inactive.

ALL_COMPLETE='{"research":{"status":"complete"},"write_tests":{"status":"complete"},"write_code":{"status":"complete"}}'
ALL_TERMINAL_MIXED='{"research":{"status":"complete"},"write_tests":{"status":"skipped"},"write_code":{"status":"complete"}}'
MID_FLIGHT='{"research":{"status":"complete"},"write_tests":{"status":"complete"},"write_code":{"status":"pending"}}'

# W13: the regression itself. A workflow that ran to completion is finished, not in
# flight — the state file is a record of the past, and it never disappears.
B13=$(new_env w13); write_state "$B13" "$ALL_COMPLETE"
check "W13-all-complete-inactive" "inactive" "$B13"

# W14: `skipped` is terminal in exactly the same way `complete` is (CPR-5) — a skipped
# step is a decision already taken, not work still outstanding. A rule that only looked
# for `complete` would call this finished workflow active.
B14=$(new_env w14); write_state "$B14" "$ALL_TERMINAL_MIXED"
check "W14-all-terminal-mixed-inactive" "inactive" "$B14"

# W15: the in-flight case stated explicitly. W3 has one complete step and would still
# pass under a rule that ignores the unfinished half, so the mixture is asserted here
# rather than inferred — this is the row that must NOT move when W13 goes inactive.
B15=$(new_env w15); write_state "$B15" "$MID_FLIGHT"
check "W15-some-complete-some-pending-active" "active" "$B15"

# W16/W17: the fail-closed direction of the same change. The distinction is decided by
# reading each step's status, so a step whose status cannot be read is ignorance again
# — and it is placed among otherwise-finished steps on purpose, where treating it as
# terminal would flip the answer to `inactive` and hand out the highest privilege.
B16=$(new_env w16)
write_state "$B16" '{"research":{"status":"complete"},"write_tests":"not-an-object","write_code":{"status":"complete"}}'
check "W16-malformed-entry-among-complete-active" "active" "$B16"

B17=$(new_env w17)
write_state "$B17" '{"research":{"status":"complete"},"write_tests":{"note":"status key missing"},"write_code":{"status":"complete"}}'
check "W17-status-absent-among-complete-active" "active" "$B17"

echo ""
echo "=== readRawState vs readState (S10c: the raw file, not the synthesized state) ==="

# W7: readState() runs applyStateMigrations(), which fills in steps that were never
# written to disk (as `pending`). readRawState() returns exactly what is on disk.
# The distinction is the whole reason S10c mandates readRawState: a state file that
# was written by an unrelated code path must not look like a 14-step workflow.
# Precondition check — if this ever stops holding, W1/W2 stop meaning anything.
B7=$(new_env w7)
printf '%s' '{"version":1,"session_id":"'"$WSID"'","workflow_type":"wf-code","steps":{}}' \
    > "$B7/state/$WSID.json"
SYNTH=$( cd "$B7/cwd" && \
    CLAUDE_WORKFLOW_DIR="$(node_path "$B7/state")" \
    WORKFLOW_PLANS_DIR="$(node_path "$B7/plans")" \
    ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        "$RWT" 15 node -e "
try {
  const io = require(process.argv[1]);
  const raw = io.readRawState(process.argv[2]);
  const syn = io.readState(process.argv[2]);
  const rawN = raw && raw.steps ? Object.keys(raw.steps).length : -1;
  const synN = syn && syn.steps ? Object.keys(syn.steps).length : -1;
  process.stdout.write(synN > rawN ? 'distinct' : 'same:raw=' + rawN + ',syn=' + synN);
} catch (e) { process.stdout.write('err:' + e.message); }
" "$(node_path "$STATE_IO")" "$WSID" 2>/dev/null )
if [ "$SYNTH" = "distinct" ]; then
    pass "W7-readRawState-and-readState-differ-on-unwritten-steps"
else
    fail "W7-readRawState-and-readState-differ-on-unwritten-steps" \
         "precondition for the S10c choice does not hold (got: $SYNTH)"
fi

# W8: the module must name readRawState, not readState, in its source.
if [ "$MOD_PRESENT" != "yes" ]; then
    fail "W8-uses-readRawState" "RED-EXPECTED: hooks/lib/workflow-activity.js not yet created"
else
    if grep -q "readRawState" "$MOD" && ! grep -qE "readState\s*\(" "$MOD"; then
        pass "W8-uses-readRawState"
    else
        fail "W8-uses-readRawState" "module must call readRawState() and not readState()"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
