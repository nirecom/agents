#!/usr/bin/env bash
# Tests: bin/workflow/lib/next-step/advance-shared.js, bin/workflow/next-step, hooks/workflow-state/effective-state.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, scope, evidence-steps, door-parity, scope:issue-specific, pwsh-not-required

# INV-5 + F2 (#2102): `--advance --step <s> --complete --next` must return the ACTION
# block when <s> IS the session's current step. For the five EVIDENCE_STEPS it did not:
# resolveCurrentStep walks a reconciled snapshot that has already pre-resolved write_tests
# from the staged evidence, so the walk steps past it and reports not-current-step.

# TL3 gap (what this test does NOT catch): whether the model actually consumes the ACTION
# block it now receives instead of re-invoking next-step. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category:
# skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"; export WORKFLOW_PLANS_DIR
WF_OUT="$CLAUDE_WORKFLOW_DIR"; export WF_OUT
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
CONFIG_EMPTY="$TMPDIR_BASE/cfg"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"; export AGENTS_CONFIG_DIR

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 -- expected [$2] in: $3" ;; esac
}
check_not_contains() {
  case "$3" in *"$2"*) fail "$1 -- did NOT expect [$2] in: $3" ;; *) pass "$1" ;; esac
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Step spellings come from VALID_STEPS by position; the three checks below are the
# tripwire that turns a reordering into a loud failure rather than a silent no-op.
step_at() {
  IDX="$1" run_with_timeout node -e '
    const wf = require(process.env.WFSTATE_MODULE);
    process.stdout.write(wf.VALID_STEPS[Number(process.env.IDX)] || "");' 2>/dev/null
}
IDX_CLARIFY=1; IDX_RESEARCH=2; IDX_WRITE_TESTS=6; IDX_CLEANUP=13
S_CLARIFY="$(step_at $IDX_CLARIFY)"
S_RESEARCH="$(step_at $IDX_RESEARCH)"
S_WRITE_TESTS="$(step_at $IDX_WRITE_TESTS)"
S_CLEANUP="$(step_at $IDX_CLEANUP)"
check "A0a: VALID_STEPS[$IDX_RESEARCH] is the research step" "research" "$S_RESEARCH"
check "A0b: VALID_STEPS[$IDX_WRITE_TESTS] is the write_tests step" "write_tests" "$S_WRITE_TESTS"
check "A0c: VALID_STEPS[$IDX_CLEANUP] is the cleanup step" "cleanup" "$S_CLEANUP"
check "A0f: VALID_STEPS[$IDX_CLARIFY] is the clarify_intent step" "clarify_intent" "$S_CLARIFY"

# A session parked ON the step at index N: everything before it complete, it and
# everything after pending.
make_state_at() {
  SID="$1" IDX="$2" run_with_timeout node -e '
    const fs = require("fs"), path = require("path");
    const wf = require(process.env.WFSTATE_MODULE);
    const idx = Number(process.env.IDX);
    const steps = {};
    wf.VALID_STEPS.forEach((s, i) => { steps[s] = { status: i < idx ? "complete" : "pending" }; });
    fs.writeFileSync(path.join(process.env.WF_OUT, process.env.SID + ".json"),
      JSON.stringify({ steps, closes_issues: [2102] }));'
}

# Same shape, with ONE hole: the step at HOLE is left raw-pending even though it sits
# before the settle target. This is the classifier fixture for A6/A7 -- make_state_at
# alone cannot tell "excluded only the settle target" from "read raw state throughout",
# because in its states every earlier step is already complete on disk.
make_state_hole() {
  SID="$1" IDX="$2" HOLE="$3" run_with_timeout node -e '
    const fs = require("fs"), path = require("path");
    const wf = require(process.env.WFSTATE_MODULE);
    const idx = Number(process.env.IDX), hole = Number(process.env.HOLE);
    const steps = {};
    wf.VALID_STEPS.forEach((s, i) => {
      steps[s] = { status: (i < idx && i !== hole) ? "complete" : "pending" };
    });
    fs.writeFileSync(path.join(process.env.WF_OUT, process.env.SID + ".json"),
      JSON.stringify({ steps, closes_issues: [2102] }));'
}

# write_tests is gated on real staged test evidence at BOTH the record side
# (resolveTrustedRepoDir, process cwd) and the reconcile side (CLAUDE_PROJECT_DIR),
# so the fixture is a linked worktree with tests/ staged plus its main worktree.
MAIN="$TMPDIR_BASE/main"; LINKED="$TMPDIR_BASE/linked"
git init -q "$MAIN" >/dev/null 2>&1
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config user.email "t@example.com"
git -C "$MAIN" config user.name "t"
printf 'seed\n' > "$MAIN/README.md"
git -C "$MAIN" add README.md >/dev/null 2>&1
git -C "$MAIN" commit -qm seed >/dev/null 2>&1
git -C "$MAIN" worktree add -q -b wt2102s "$LINKED" >/dev/null 2>&1
git -C "$LINKED" config core.hooksPath /dev/null
mkdir -p "$LINKED/tests"
printf '# fixture test\n' > "$LINKED/tests/fixture-2102.sh"
git -C "$LINKED" add tests/ >/dev/null 2>&1
MAIN_N="$(nrm "$MAIN")"; LINKED_N="$(nrm "$LINKED")"
check "A0d: the linked worktree has tests/ staged" "tests/fixture-2102.sh" \
  "$(git -C "$LINKED" diff --cached --name-only | tr -d '\r')"
check "A0e: the main worktree has nothing staged" "" \
  "$(git -C "$MAIN" diff --cached --name-only | tr -d '\r')"

ERRF="$TMPDIR_BASE/err.txt"
OUT=""; ERR=""; RC=0
run_advance_in() {
  local cwd="$1" projdir="$2"; shift 2
  RC=0
  OUT="$(cd "$cwd" && CLAUDE_PROJECT_DIR="$projdir" run_with_timeout node "$NS" "$@" 2>"$ERRF")" || RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}
run_advance() {
  local projdir="$1"; shift
  run_advance_in "$LINKED" "$projdir" "$@"
}
count_lines() { printf '%s\n' "$2" | grep -c -- "$1"; }

echo "=== A1: write_tests is the current step and --next returns its ACTION block ==="
# Before the F2 fix this cell reports not-current-step and emits zero ACTION lines:
# reconcileEffectiveState pre-resolves write_tests from the staged evidence, so
# resolveCurrentStep's walk has already moved past it by the time it is asked.
make_state_at a1 $IDX_WRITE_TESTS
run_advance "$LINKED_N" --session a1 --advance --step "$S_WRITE_TESTS" --complete --next
check "A1a: exits 0" 0 "$RC"
check_contains "A1b: the advance is reported" "ADVANCED=$S_WRITE_TESTS status=complete" "$OUT"
check_contains "A1c: the settled step IS the session's current step" "ADVANCE_SCOPE=current-step" "$OUT"
check_not_contains "A1d: it is not reported out of scope" "ADVANCE_SCOPE=not-current-step" "$OUT"
check "A1e: exactly one ADVANCE_SCOPE line" 1 "$(count_lines '^ADVANCE_SCOPE=' "$OUT")"
check "A1f: exactly one ACTION line" 1 "$(count_lines '^ACTION=' "$OUT")"
# Not just "an ACTION line exists" -- the exact next-step advice write_tests completing
# should produce. Values confirmed against a live run of this same code path with
# CLAUDE_PROJECT_DIR pointed at a worktree with no staged evidence (A2's fixture), which
# sidesteps the F2 defect this cell is pinned on and lets the post-fix values be read off
# the real verdict.js/steps.js pairing (review_tests -> STEP_TO_SKILL["review_tests"]).
check_contains "A1g: ACTION is invoke" "ACTION=invoke" "$OUT"
check_contains "A1h: next skill is review-tests" "NEXT_SKILL=review-tests" "$OUT"
check_contains "A1i: reason is review_tests" "REASON='review_tests'" "$OUT"
check_contains "A1j: hint points at review-tests" "NEXT_HINT='Run /review-tests via the Skill tool.'" "$OUT"

echo ""
echo "=== A2: the same call with CLAUDE_PROJECT_DIR pointing elsewhere (CPR-UNV) ==="
# The verdict must be a property of the session's recorded state, not of which
# worktree happened to be advertised in the environment. A2 is green before the fix
# too -- but for the wrong reason (no evidence is visible from MAIN, so nothing gets
# pre-resolved). A1 vs A2 is therefore the environment-dependence itself.
make_state_at a2 $IDX_WRITE_TESTS
run_advance "$MAIN_N" --session a2 --advance --step "$S_WRITE_TESTS" --complete --next
check "A2a: exits 0" 0 "$RC"
check_contains "A2b: still current-step" "ADVANCE_SCOPE=current-step" "$OUT"
check "A2c: exactly one ACTION line" 1 "$(count_lines '^ACTION=' "$OUT")"

echo ""
echo "=== A3: research -- the second migrated door, not an evidence step ==="
# The control for A1: research carries no on-disk evidence predicate, so it reports
# current-step both before and after the fix. If A3 ever goes red the failure is in the
# advance transaction itself, not in the evidence pre-resolution.
make_state_at a3 $IDX_RESEARCH
run_advance "$LINKED_N" --session a3 --advance --step "$S_RESEARCH" --complete --next
check "A3a: exits 0" 0 "$RC"
check_contains "A3b: the advance is reported" "ADVANCED=$S_RESEARCH status=complete" "$OUT"
check_contains "A3c: current-step" "ADVANCE_SCOPE=current-step" "$OUT"
check "A3d: exactly one ACTION line" 1 "$(count_lines '^ACTION=' "$OUT")"
# research carries no evidence predicate, so this cell is already green today; pinning
# the exact values (not just "an ACTION line exists") is what makes a drift in
# STEP_TO_SKILL or the outline-step ordering show up here instead of only downstream.
check_contains "A3e: ACTION is invoke" "ACTION=invoke" "$OUT"
check_contains "A3f: next skill is make-outline-plan" "NEXT_SKILL=make-outline-plan" "$OUT"
check_contains "A3g: reason is outline" "REASON='outline'" "$OUT"
check_contains "A3h: hint points at make-outline-plan" "NEXT_HINT='Run /make-outline-plan via the Skill tool.'" "$OUT"

echo ""
echo "=== A4: settling a step the session is NOT on returns no ACTION block ==="
# The fail-closed half of the contract: an out-of-scope advance must not hand back a
# next action describing some other step. Without this, A1/A3 would pass under an
# implementation that simply always emitted the ACTION block.
make_state_at a4 $IDX_RESEARCH
run_advance "$LINKED_N" --session a4 --advance --step "$S_CLEANUP" --skipped \
  --skip-reason "fixture: out-of-scope settle" --next
check "A4a: exits 0" 0 "$RC"
check_contains "A4b: the advance is reported" "ADVANCED=$S_CLEANUP status=skipped" "$OUT"
check_contains "A4c: reported as not-current-step" "ADVANCE_SCOPE=not-current-step" "$OUT"
check "A4d: zero ACTION lines" 0 "$(count_lines '^ACTION=' "$OUT")"
check "A4e: zero NEXT_SKILL lines" 0 "$(count_lines '^NEXT_SKILL=' "$OUT")"

echo ""
echo "=== A5: without --next there is no scope line at all ==="
# ADVANCE_SCOPE answers a question only --next asks. Emitting it unasked would make
# the plain advance output non-parseable by existing callers.
make_state_at a5 $IDX_RESEARCH
run_advance "$LINKED_N" --session a5 --advance --step "$S_RESEARCH" --complete
check "A5a: exits 0" 0 "$RC"
check_contains "A5b: the advance is still reported" "ADVANCED=$S_RESEARCH status=complete" "$OUT"
check "A5c: zero ADVANCE_SCOPE lines" 0 "$(count_lines '^ADVANCE_SCOPE=' "$OUT")"
check "A5d: zero ACTION lines" 0 "$(count_lines '^ACTION=' "$OUT")"

echo ""
echo "=== A6: the exclusion is scoped to the settle target, not to the whole walk ==="
# Everything before write_tests is complete EXCEPT clarify_intent, which is raw-pending
# but legitimately evidence-resolved (its plan artifact is on disk). current-step is
# therefore reachable only if write_tests ignores its OWN derived completion (the F2
# defect A1 pins) AND clarify_intent's still flows into the walk. A1-A5 cannot separate
# the two: their fixtures have every earlier step complete on disk, so a build that
# swapped the reconciled walk for raw state passes all five.
make_state_hole a6 $IDX_WRITE_TESTS $IDX_CLARIFY
printf '# fixture intent\n' > "$PLANS_DIR/a6-intent.md"
if [ -f "$PLANS_DIR/a6-intent.md" ]; then pass "A6a: the clarify_intent evidence artifact exists"
else fail "A6a: the clarify_intent evidence artifact was not written"; fi
run_advance "$LINKED_N" --session a6 --advance --step "$S_WRITE_TESTS" --complete --next
check "A6b: exits 0" 0 "$RC"
check_contains "A6c: the advance is reported" "ADVANCED=$S_WRITE_TESTS status=complete" "$OUT"
check_contains "A6d: current-step -- the upstream hole is evidence-resolved" "ADVANCE_SCOPE=current-step" "$OUT"
check_not_contains "A6e: the upstream hole does not steal the scope" "ADVANCE_SCOPE=not-current-step" "$OUT"
check "A6f: exactly one ACTION line" 1 "$(count_lines '^ACTION=' "$OUT")"

echo ""
echo "=== A7: control -- an upstream hole with NO evidence keeps the scope away ==="
# Same fixture with the hole moved to research, which has no evidence predicate and no
# artifact. The session's current step really is research, so settling write_tests must
# be out of scope -- without A7, A6 also passes a build that says current-step always.
make_state_hole a7 $IDX_WRITE_TESTS $IDX_RESEARCH
run_advance "$LINKED_N" --session a7 --advance --step "$S_WRITE_TESTS" --complete --next
check "A7a: exits 0" 0 "$RC"
check_contains "A7b: the advance is reported" "ADVANCED=$S_WRITE_TESTS status=complete" "$OUT"
check_contains "A7c: reported as not-current-step" "ADVANCE_SCOPE=not-current-step" "$OUT"
check "A7d: zero ACTION lines" 0 "$(count_lines '^ACTION=' "$OUT")"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
