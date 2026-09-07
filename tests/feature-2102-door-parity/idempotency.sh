#!/usr/bin/env bash
# Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/state-io/events.js, hooks/workflow-mark.js, hooks/workflow-mark/mark-step-handler.js, bin/workflow/next-step, bin/workflow/lib/next-step/advance-shared.js
# Tags: tl2, workflow, idempotency, event-stream, door-parity, scope:issue-specific, pwsh-not-required

# INV-2 (#2102): the advance gate short-circuits a repeat (`already=true`, nothing
# appended) while the sentinel gate deliberately re-writes. Both arms are PINNED rather
# than reconciled. The folded projection is identical either way, so every count below
# is read off the raw append-only event stream.

# TL3 gap (what this test does NOT catch): whether a live session actually re-issues the
# completion call (e.g. after a Stop-guard retry), and whether the second call's stdout
# reaches the model unchanged. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED
# preflight, bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
MARK_HOOK="$AGENTS_DIR_N/hooks/workflow-mark.js"
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"; NEUTRAL="$TMPDIR_BASE/neutral"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR" "$NEUTRAL"
CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"; export WORKFLOW_PLANS_DIR
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
count_lines() { printf '%s\n' "$2" | grep -c -- "$1"; }
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# write_tests needs real staged evidence in BOTH doors, so the fixture is a linked
# worktree with tests/ staged; the main worktree supplies CLAUDE_PROJECT_DIR so the
# sentinel door's priority-0 (input.cwd differs) branch is the one exercised.
MAIN="$TMPDIR_BASE/main"; LINKED="$TMPDIR_BASE/linked"
git init -q "$MAIN" >/dev/null 2>&1
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config user.email "t@example.com"
git -C "$MAIN" config user.name "t"
printf 'seed\n' > "$MAIN/README.md"
git -C "$MAIN" add README.md >/dev/null 2>&1
git -C "$MAIN" commit -qm seed >/dev/null 2>&1
git -C "$MAIN" worktree add -q -b wt2102i "$LINKED" >/dev/null 2>&1
git -C "$LINKED" config core.hooksPath /dev/null
mkdir -p "$LINKED/tests"
printf '# fixture test\n' > "$LINKED/tests/fixture-2102.sh"
git -C "$LINKED" add tests/ >/dev/null 2>&1
LINKED_N="$(nrm "$LINKED")"
CLAUDE_PROJECT_DIR="$(nrm "$MAIN")"; export CLAUDE_PROJECT_DIR

check "F0: the linked worktree has tests/ staged" "tests/fixture-2102.sh" \
  "$(git -C "$LINKED" diff --cached --name-only | tr -d '\r')"

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
make_state() {
  local sid="$1" complete="$2" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[2102]}" > "$WORKFLOW_DIR/${sid}.json"
}
at_write_tests() { make_state "$1" "workflow_init clarify_intent research outline detail branching_complete"; }
at_research()    { make_state "$1" "workflow_init clarify_intent"; }

step_status() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD=status \
    run_with_timeout node "$PROBE" field 2>/dev/null || echo "PROBE_FAIL"
}
ev_count() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD=step_status \
    run_with_timeout node "$PROBE" eventcount 2>/dev/null || echo "PROBE_FAIL"
}

ERRF="$TMPDIR_BASE/err.txt"
OUT=""; ERR=""; RC=0
# --next is always passed so ADVANCE_SCOPE and the ACTION block are exercised on both
# the first call and the identical repeat -- see I1/I3 below for what each must show.
run_cli() {
  local sid="$1" step="$2"
  RC=0
  OUT="$(cd "$LINKED" && run_with_timeout node "$NS" --session "$sid" \
    --advance --step "$step" --complete --next 2>"$ERRF")" || RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}
mk_payload() {
  SID="$1" STEP="$2" ICWD="$3" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo \"<<WORKFLOW_MARK_STEP_"+process.env.STEP+"_complete>>\""},tool_response:{exit_code:0},session_id:process.env.SID,cwd:process.env.ICWD}))'
}
run_sentinel() {
  local sid="$1" step="$2"
  mk_payload "$sid" "$step" "$LINKED_N" > "$TMPDIR_BASE/payload.json"
  RC=0
  OUT="$(cd "$NEUTRAL" && run_with_timeout node "$MARK_HOOK" < "$TMPDIR_BASE/payload.json" 2>"$ERRF")" || RC=$?
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}

echo "=== I1: CLI door, write_tests -- the repeat short-circuits and appends nothing ==="
# CLAUDE_PROJECT_DIR is pinned at MAIN for the whole file (line ~70), which carries no
# staged test evidence -- so this fixture does not hit the F2 evidence pre-resolution
# defect advance-scope.sh's A1 is pinned on, and the first call's ACTION block is real,
# checkable output today (values confirmed against a live run of this exact fixture).
at_write_tests i1
run_cli i1 write_tests
check "I1: first call exits 0" 0 "$RC"
check_contains "I1: first call reports the advance" "ADVANCED=write_tests status=complete" "$OUT"
check_not_contains "I1: first call does NOT report already=true" "already=true" "$OUT"
check_contains "I1: first call reports current-step" "ADVANCE_SCOPE=current-step" "$OUT"
check_contains "I1: first call's ACTION is invoke" "ACTION=invoke" "$OUT"
check_contains "I1: first call's next skill is review-tests" "NEXT_SKILL=review-tests" "$OUT"
check_contains "I1: first call's reason is review_tests" "REASON='review_tests'" "$OUT"
check "I1: write_tests is complete" '"complete"' "$(step_status i1 write_tests)"
I1_N="$(ev_count i1 write_tests)"
check "I1: exactly one step_status event after the first call" 1 "$I1_N"
run_cli i1 write_tests
check "I1: the repeat exits 0" 0 "$RC"
check_contains "I1: the repeat still reports the advance line" "ADVANCED=write_tests status=complete" "$OUT"
check_contains "I1: the repeat reports already=true" "already=true" "$OUT"
check "I1: the repeat appended NO second step_status event" "$I1_N" "$(ev_count i1 write_tests)"
# By the time the repeat call reads state, write_tests is ALREADY complete on disk (from
# the first call), so the session's real current step has moved on to review_tests --
# resolveCurrentStep(sid) (advance-shared.js, read before this call's own write) walks
# past write_tests and the repeat is correctly out of scope for it. not-current-step
# here is the correct signal, not a defect: re-settling a step that already moved past
# the frontier must not hand back stale advice for the step the caller re-named.
check_contains "I1: the repeat reports not-current-step (correct -- see comment above)" \
  "ADVANCE_SCOPE=not-current-step" "$OUT"
check "I1: the repeat emits zero ACTION lines" 0 "$(count_lines '^ACTION=' "$OUT")"
check "I1: the repeat emits zero NEXT_SKILL lines" 0 "$(count_lines '^NEXT_SKILL=' "$OUT")"

echo ""
echo "=== I2: sentinel door, write_tests -- the repeat DOES re-write (pinned asymmetry) ==="
# Not a defect to fix: the sentinel gate must keep re-writing so a re-emitted
# NOT_NEEDED sentinel with a new reason replaces the recorded one (migration note 5).
at_write_tests i2
run_sentinel i2 write_tests
check "I2: first call exits 0" 0 "$RC"
check "I2: write_tests is complete" '"complete"' "$(step_status i2 write_tests)"
I2_N="$(ev_count i2 write_tests)"
check "I2: exactly one step_status event after the first call" 1 "$I2_N"
run_sentinel i2 write_tests
check "I2: the repeat exits 0" 0 "$RC"
check "I2: the repeat DID append a second step_status event" 2 "$(ev_count i2 write_tests)"
check "I2: the projected status is unchanged" '"complete"' "$(step_status i2 write_tests)"

echo ""
echo "=== I3: CLI door, research -- same short-circuit on the second migrated door ==="
# research carries no on-disk evidence predicate, so both calls below are unconditionally
# real (not gated on the F2 fix) -- values confirmed against a live run of this fixture.
at_research i3
run_cli i3 research
check "I3: first call exits 0" 0 "$RC"
check_not_contains "I3: first call does NOT report already=true" "already=true" "$OUT"
check_contains "I3: first call reports current-step" "ADVANCE_SCOPE=current-step" "$OUT"
check_contains "I3: first call's ACTION is invoke" "ACTION=invoke" "$OUT"
check_contains "I3: first call's next skill is make-outline-plan" "NEXT_SKILL=make-outline-plan" "$OUT"
check_contains "I3: first call's reason is outline" "REASON='outline'" "$OUT"
check "I3: research is complete" '"complete"' "$(step_status i3 research)"
I3_N="$(ev_count i3 research)"
check "I3: exactly one step_status event after the first call" 1 "$I3_N"
run_cli i3 research
check "I3: the repeat exits 0" 0 "$RC"
check_contains "I3: the repeat reports already=true" "already=true" "$OUT"
check "I3: the repeat appended NO second step_status event" "$I3_N" "$(ev_count i3 research)"
# Same reasoning as I1: research is already complete on disk by the time the repeat call
# reads state, so the frontier has moved to outline and not-current-step is correct.
check_contains "I3: the repeat reports not-current-step (correct -- see I1 comment)" \
  "ADVANCE_SCOPE=not-current-step" "$OUT"
check "I3: the repeat emits zero ACTION lines" 0 "$(count_lines '^ACTION=' "$OUT")"
check "I3: the repeat emits zero NEXT_SKILL lines" 0 "$(count_lines '^NEXT_SKILL=' "$OUT")"

echo ""
echo "=== I4: sentinel door, research -- the same re-write asymmetry ==="
at_research i4
run_sentinel i4 research
check "I4: first call exits 0" 0 "$RC"
check "I4: research is complete" '"complete"' "$(step_status i4 research)"
I4_N="$(ev_count i4 research)"
check "I4: exactly one step_status event after the first call" 1 "$I4_N"
run_sentinel i4 research
check "I4: the repeat exits 0" 0 "$RC"
check "I4: the repeat DID append a second step_status event" 2 "$(ev_count i4 research)"

echo ""
echo "=== I5: the asymmetry is a property of the GATE, not of the step ==="
# Cross-check: for the same step the two doors' repeat-counts must differ. If a future
# change made the sentinel gate short-circuit too, these go red and I2/I4 stop being a
# silent restatement of I1/I3.
check "I5a: write_tests -- CLI repeat count differs from sentinel repeat count" \
  "1-2" "$(ev_count i1 write_tests)-$(ev_count i2 write_tests)"
check "I5b: research -- CLI repeat count differs from sentinel repeat count" \
  "1-2" "$(ev_count i3 research)-$(ev_count i4 research)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
