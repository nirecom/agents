#!/usr/bin/env bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/cli.js, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/state-ops.js, bin/workflow/record-skip-judgment, bin/workflow/record-complexity-and-skip, bin/workflow/set-workflow-type, bin/workflow/record-skip-verdict, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, forward-cli, subprocess, idempotency, event-stream, scope:issue-specific, pwsh-not-required

# Observes the forward operation through a REAL subprocess boundary on all four
# advance-class CLIs. Existing cases assert only the folded PROJECTION, which is
# identical whether a repeat call appended a duplicate event or nothing at all --
# idempotency is a statement about the raw append-only event stream, so these
# cases read it directly via the shared state-probe `eventcount` mode. Already
# covered elsewhere and deliberately not repeated here: ADVANCE_SCOPE verdicts
# (feature-1644-advance-transaction/projection.sh A15), same-CLI already=true
# (.../basic.sh A5), sibling-CLI already=true (feature-1644-sibling-cli-advance.sh S15).

# TL3 gap: live settings.json permission-dialog admission, the migrated SKILL.md
# steps' actual call shape, and concurrent-session convergence are not checked
# here -- see WORKFLOW_USER_VERIFIED preflight (skill-orchestration category).

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
RSJ="$AGENTS_DIR_N/bin/workflow/record-skip-judgment"
SWT="$AGENTS_DIR_N/bin/workflow/set-workflow-type"
RSV="$AGENTS_DIR_N/bin/workflow/record-skip-verdict"
RCAS="$AGENTS_DIR/bin/workflow/record-complexity-and-skip"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Pinned as a PAIR (#1799) so supervisor-emit never appends to the real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Empty fixture config dir: no CONFIRM_* is inherited from the repo's own .env,
# so every approval-gated branch under test is armed rather than accidentally off.
CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
CONFIG_EMPTY_N="$(nrm "$CONFIG_EMPTY")"
export AGENTS_CONFIG_DIR="$CONFIG_EMPTY_N"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- expected [$2] in: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 -- did NOT expect [$2] in: $3"; else pass "$1"; fi
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
make_state() {
  local sid="$1" complete="$2" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[1644]}" > "$WORKFLOW_DIR/${sid}.json"
}
at_outline() { make_state "$1" "workflow_init clarify_intent research"; }
at_research() { make_state "$1" "workflow_init clarify_intent"; }

OUT=""; ERR=""; RC=0
# run_cli <argv...> — a REAL subprocess; stdout/stderr/exit code are all captured.
run_cli() {
  local errf="$TMPDIR_BASE/cli.err"
  RC=0
  OUT="$(run_with_timeout "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
probe() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="${4:-}" \
    run_with_timeout node "$PROBE" "$3" 2>/dev/null || echo "PROBE_FAIL"
}
step_status() { probe "$1" "$2" field status; }
step_sub()    { probe "$1" "$2" sub "$3"; }
# Raw-stream event count for a step (optionally one kind) — the ONLY view that
# can tell "appended nothing" apart from "appended an identical duplicate".
ev_count()    { probe "$1" "$2" eventcount "${3:-}"; }
action_lines() { printf '%s\n' "$OUT" | grep -c '^ACTION=' || true; }

echo "=== C3-1: next-step --advance status matrix through a real subprocess ==="
# complete
at_research c31a
run_cli node "$NS" --session c31a --advance --step research --complete
check "C3-1a: --complete exits 0" 0 "$RC"
check "C3-1a: stdout carries the advance line" "ADVANCED=research status=complete" "$OUT"
# EXACT match, not a substring: the canonical value-less form pollutes nothing
# on stderr, which is the regression guard. The legacy form's own deprecation
# line is asserted separately by C3-1a-legacy below.
check "C3-1a: stderr is empty on success" "" "$ERR"
check "C3-1a: research is complete" '"complete"' "$(step_status c31a research)"
C31A_OUT="$OUT"

# C3-1a-legacy: the deprecated --status form still works, on its own session id.
at_research c31alegacy
run_cli node "$NS" --session c31alegacy --advance --step research --status complete
check "C3-1a-legacy: the deprecated --status complete form still exits 0" 0 "$RC"
check "C3-1a-legacy: its stdout is byte-identical to the canonical form" "$C31A_OUT" "$OUT"
check_contains "C3-1a-legacy: the deprecation notice goes to stderr" "deprecated" "$ERR"
check "C3-1a-legacy: research is complete" '"complete"' "$(step_status c31alegacy research)"

# skipped (research is in SKIPPABLE_STEPS and needs no CLI-side approval route)
at_research c31b
run_cli node "$NS" --session c31b --advance --step research --status skipped \
  --skip-reason "the survey artifact from the parent session already covers this"
check "C3-1b: --status skipped exits 0" 0 "$RC"
check "C3-1b: stdout carries the advance line" "ADVANCED=research status=skipped" "$OUT"
check "C3-1b: research is skipped" '"skipped"' "$(step_status c31b research)"
check_contains "C3-1b: the reason reaches the state verbatim" \
  "the survey artifact" "$(step_sub c31b research skip_reason)"

# pending (the --reset capability under the forward-operation flag)
at_outline c31c
check "C3-1c: research starts complete" '"complete"' "$(step_status c31c research)"
run_cli node "$NS" --session c31c --advance --step research --status pending
check "C3-1c: --status pending exits 0" 0 "$RC"
check "C3-1c: stdout carries the advance line" "ADVANCED=research status=pending" "$OUT"
check "C3-1c: research is back to pending" '"pending"' "$(step_status c31c research)"

echo ""
echo "=== C3-2: ADVANCE_SCOPE on the SIBLING CLIs, --next present and absent ==="
# A15 pins both verdicts for next-step only. The scope line is emitted by the
# SHARED runAdvance, so a sibling that forgets to forward `next` would still
# pass every next-step case.
at_outline c32a
run_cli node "$RSJ" --session c32a --target outline --c1 true --c2 true --advance --next
check "C3-2a: record-skip-judgment --advance --next exits 0" 0 "$RC"
check_contains "C3-2a: scope is current-step" "ADVANCE_SCOPE=current-step" "$OUT"
check "C3-2a: exactly one ACTION line" 1 "$(action_lines)"

# Same call WITHOUT --next: no scope line and no ACTION block at all.
at_outline c32b
run_cli node "$RSJ" --session c32b --target outline --c1 true --c2 true --advance
check "C3-2b: without --next exits 0" 0 "$RC"
check_not_contains "C3-2b: no ADVANCE_SCOPE line without --next" "ADVANCE_SCOPE=" "$OUT"
check "C3-2b: no ACTION line without --next" 0 "$(action_lines)"

# not-current-step arm: the session is at outline, so settling `detail` is out of
# scope and the ACTION block must be withheld even though --next was asked for.
make_state c32c ""
run_cli node "$RSJ" --session c32c --target detail --c1 true --c2 true --c3 true --advance --next
check "C3-2c: out-of-scope sibling advance still exits 0" 0 "$RC"
check_contains "C3-2c: the record is still reported" "ADVANCED=detail status=skipped" "$OUT"
check_contains "C3-2c: scope is not-current-step" "ADVANCE_SCOPE=not-current-step" "$OUT"
check "C3-2c: no ACTION line for an out-of-scope step" 0 "$(action_lines)"

# set-workflow-type: same two verdicts on the third member of the class.
make_state c32d ""
run_cli node "$SWT" --session c32d --type wf-code --advance --step workflow_init --status complete --next
check "C3-2d: set-workflow-type --advance --next exits 0" 0 "$RC"
check_contains "C3-2d: scope is current-step" "ADVANCE_SCOPE=current-step" "$OUT"
check "C3-2d: exactly one ACTION line" 1 "$(action_lines)"

at_outline c32e
run_cli node "$SWT" --session c32e --type wf-code --advance --step cleanup --status complete --next
check "C3-2e: out-of-scope set-workflow-type advance exits 0" 0 "$RC"
check_contains "C3-2e: scope is not-current-step" "ADVANCE_SCOPE=not-current-step" "$OUT"
check "C3-2e: no ACTION line for an out-of-scope step" 0 "$(action_lines)"
check "C3-2e: the record still landed" '"complete"' "$(step_status c32e cleanup)"

echo ""
echo "=== C3-3: a repeated --advance appends NOTHING to the event stream ==="
# next-step arm. The projection is unchanged either way (A5 already pins that),
# so the falsifiable statement is the raw step_status event count.
at_outline c33a
run_cli node "$NS" --session c33a --advance --step outline --status skipped \
  --skip-reason "the approach is already fixed by the issue body"
check "C3-3a: first advance exits 0" 0 "$RC"
C33A_N="$(ev_count c33a outline step_status)"
check "C3-3a: exactly one step_status event after the first call" 1 "$C33A_N"
run_cli node "$NS" --session c33a --advance --step outline --status skipped \
  --skip-reason "the approach is already fixed by the issue body"
check "C3-3a: the repeat exits 0" 0 "$RC"
check_contains "C3-3a: the repeat reports already=true" "already=true" "$OUT"
check "C3-3a: the repeat appended NO second step_status event" "$C33A_N" "$(ev_count c33a outline step_status)"

# record-skip-judgment arm — same statement on a sibling.
at_outline c33b
run_cli node "$RSJ" --session c33b --target outline --c1 true --c2 true --advance
C33B_N="$(ev_count c33b outline step_status)"
check "C3-3b: exactly one step_status event after the first call" 1 "$C33B_N"
run_cli node "$RSJ" --session c33b --target outline --c1 true --c2 true --advance
check "C3-3b: the repeat exits 0" 0 "$RC"
check "C3-3b: the repeat appended NO second step_status event" "$C33B_N" "$(ev_count c33b outline step_status)"

# set-workflow-type arm.
make_state c33c ""
run_cli node "$SWT" --session c33c --type wf-meta --advance --step workflow_init --status complete
C33C_N="$(ev_count c33c workflow_init step_status)"
run_cli node "$SWT" --session c33c --type wf-meta --advance --step workflow_init --status complete
check "C3-3c: the repeat exits 0" 0 "$RC"
check "C3-3c: the repeat appended NO second step_status event" "$C33C_N" "$(ev_count c33c workflow_init step_status)"

# record-complexity-and-skip arm (delegates to record-skip-judgment --advance).
# The real config dir is required: RCAS resolves its siblings through AGENTS_CONFIG_DIR.
make_state c33d "workflow_init clarify_intent research"
printf '# intent\n' > "$PLANS_DIR/c33d-intent.md"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session c33d --signals "" --target outline --advance
check "C3-3d: first record-complexity-and-skip --advance exits 0" 0 "$RC"
C33D_N="$(ev_count c33d outline step_status)"
check "C3-3d: exactly one step_status event after the first call" 1 "$C33D_N"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session c33d --signals "" --target outline --advance
check "C3-3d: the repeat exits 0" 0 "$RC"
check "C3-3d: the repeat appended NO second step_status event" "$C33D_N" "$(ev_count c33d outline step_status)"

echo ""
echo "=== C3-4: a repeated workflow_init advance does not re-run the downstream reset ==="
# A6b asserts the PROJECTION survives. The reset is an appended batch of 14
# annotation+status pairs, so a re-fire that happens to land on already-pending
# steps is invisible there and visible only in the stream.
make_state c34 ""
run_cli node "$NS" --session c34 --advance --step workflow_init --status complete
check "C3-4: first workflow_init advance exits 0" 0 "$RC"
C34_RES="$(ev_count c34 research)"
C34_ALL="$(ev_count c34 '')"
run_cli node "$NS" --session c34 --advance --step workflow_init --status complete
check "C3-4: the repeat exits 0" 0 "$RC"
check_contains "C3-4: the repeat reports already=true" "already=true" "$OUT"
check "C3-4: no extra downstream-reset events for research" "$C34_RES" "$(ev_count c34 research)"
check "C3-4: the whole event stream is unchanged" "$C34_ALL" "$(ev_count c34 '')"

echo ""
echo "=== C3-5: a repeated --advance does not overwrite a resolved skip verdict ==="
# The A-4 co-write (#1681) writes skip_verdict=pending. Once skip-verifier has
# resolved it to `confirm`, a re-issued --advance must NOT reset it to pending —
# that would silently re-open a decision the verifier already made.
at_outline c35
run_cli node "$NS" --session c35 --advance --step outline --status skipped \
  --skip-reason "the approach is already fixed by the issue body"
check "C3-5: the skip exits 0" 0 "$RC"
check "C3-5: the co-written verdict starts pending" '"pending"' "$(step_sub c35 outline skip_verdict.verdict)"
run_cli node "$RSV" --session c35 --target outline --verdict confirm --reason "verified against the intent artifact"
check "C3-5: record-skip-verdict exits 0" 0 "$RC"
check "C3-5: the verdict is now confirm" '"confirm"' "$(step_sub c35 outline skip_verdict.verdict)"
run_cli node "$NS" --session c35 --advance --step outline --status skipped \
  --skip-reason "the approach is already fixed by the issue body"
check "C3-5: the repeat exits 0" 0 "$RC"
check "C3-5: the resolved verdict SURVIVES the repeat" '"confirm"' "$(step_sub c35 outline skip_verdict.verdict)"

# Symmetric arm on a sibling: record-skip-judgment reaches the same writer, so
# the same protection must hold there or the guarantee is next-step-only.
at_outline c35b
run_cli node "$RSJ" --session c35b --target outline --c1 true --c2 true --advance
run_cli node "$RSV" --session c35b --target outline --verdict confirm --reason "verified against the intent artifact"
check "C3-5b: the verdict is confirm before the repeat" '"confirm"' "$(step_sub c35b outline skip_verdict.verdict)"
run_cli node "$RSJ" --session c35b --target outline --c1 true --c2 true --advance
check "C3-5b: the repeat exits 0" 0 "$RC"
check "C3-5b: the resolved verdict SURVIVES the sibling repeat" \
  '"confirm"' "$(step_sub c35b outline skip_verdict.verdict)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
