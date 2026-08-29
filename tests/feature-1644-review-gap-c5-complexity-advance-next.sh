#!/usr/bin/env bash
# Tests: bin/workflow/record-complexity-and-skip, bin/workflow/record-skip-judgment, bin/workflow/record-complexity-evaluation, hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, record-complexity-and-skip, skip-dispatch, class-contract, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C5 — record-complexity-and-skip on the `--advance` path.
#
# Why: this CLI is the one advance-class member that does not settle the step
# itself. It resolves WHICH branch applies (complexity-derived auto vs. the
# orchestrator's own judgment) and, on the auto branch only, DELEGATES the
# forward operation to record-skip-judgment --advance. The two stdout lines it
# emits — SKIP_MODE= and SKIP_DISPATCH= — are the caller's only view of which of
# those three outcomes happened, so each branch is pinned against the resulting
# state, not only against stdout.
#
# ################ DOCUMENTED GAP — SOURCE FOLLOW-UP REQUIRED ################
# `--next` is NOT accepted by this CLI. Its argument loop (bin/workflow/
# record-complexity-and-skip lines 15-26) has cases for --advance, --so-c1 and
# --so-c2 but none for --next, so the flag falls into the catch-all and exits 2
# with "Unknown flag: --next" on stderr. Every other member of the #1644 advance
# class (next-step, record-skip-judgment, set-workflow-type) accepts the
# `--advance --next` pair, so the class contract is INCOMPLETE here.
#
# Case C5-6 below pins the CURRENT behavior deliberately. It is an assertion of
# what the source does today, NOT an endorsement: closing the gap requires a
# SOURCE change (either implement --next by delegating it through to
# record-skip-judgment, or document record-complexity-and-skip as a second named
# exception alongside record-skip-verdict). This test file must not fix it.
# ############################################################################
#
# Sibling boundary (no duplication): tests/feature-1644-sibling-cli-advance.sh
# S9 (legacy pass-through), S10 (exit-3 normalization), S12 (auto vs judgment on
# outline) and S13c/d (argument errors) already exist. Added here: the detail
# target's --c3 delegation, the explicit-false so_c1/so_c2 override, the
# SKIP_DISPATCH token VALUES (S12 asserts only that one such line exists), and
# the --next gap above.
#
# TL3 gap (what this test does NOT catch):
# - Whether skills/clarify-intent and skills/make-outline-plan actually invoke
#   this CLI with --advance rather than the legacy CLI-then-next-step pair.
# - Whether settings.json permissions.allow admits the --advance argv form
#   without an approval dialog in a live session.
# Closest-to-action mitigation: surfaced at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
# RCAS is invoked through bash with a POSIX path (it is a #!/bin/bash script),
# while AGENTS_CONFIG_DIR must be the WORKTREE root so the script can resolve its
# siblings under bin/workflow/ and hooks/workflow-state/.
RCAS="$AGENTS_DIR/bin/workflow/record-complexity-and-skip"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
# CPR-SSOT: the one fixture-state reader shared by every #1644 test file.
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"

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

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Pinned as a PAIR (#1799): a lone CLAUDE_WORKFLOW_DIR still lets supervisor-emit
# append to the developer's real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

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
at_detail()  { make_state "$1" "workflow_init clarify_intent research outline"; }

OUT=""; ERR=""; RC=0
# Every invocation carries AGENTS_CONFIG_DIR=<worktree root>: RCAS resolves its
# siblings through it, and a stub config dir would defeat the delegation this
# file is about. The repo's own .env cannot decide any case here — the only
# config-file branch on the CLI door is CONFIRM_TESTS for write_tests, and the
# targets used below are outline/detail, which the door admits unconditionally.
run_rcas() {
  local errf="$TMPDIR_BASE/rcas.err"
  RC=0
  OUT="$(AGENTS_CONFIG_DIR="$AGENTS_DIR_N" run_with_timeout bash "$RCAS" "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
probe() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="${4:-}" \
    run_with_timeout node "$PROBE" "$3" 2>/dev/null || echo "PROBE_FAIL"
}
step_status() { probe "$1" "$2" field status; }
step_sub()    { probe "$1" "$2" sub "$3"; }
line_count()  { printf '%s\n' "$OUT" | grep -c "$1" || true; }

echo "=== C5-1: outline + auto branch settles the step through the delegate ==="
at_outline a1
printf '# intent\n' > "$PLANS_DIR/a1-intent.md"
run_rcas --session a1 --signals "" --target outline --advance
check "C5-1: exit 0" 0 "$RC"
check_contains "C5-1: SKIP_MODE reports the auto branch" "SKIP_MODE=auto" "$OUT"
check_contains "C5-1: SKIP_DISPATCH reports advanced" "SKIP_DISPATCH=advanced" "$OUT"
check "C5-1: outline is recorded skipped" '"skipped"' "$(step_status a1 outline)"
# The delegate — not RCAS — owns the reason literal and the A-4 co-write, so the
# state proves the delegation actually happened rather than a local shortcut.
check_contains "C5-1: skip_reason carries the recorded-verdict: prefix" \
  "recorded-verdict:" "$(step_sub a1 outline skip_reason)"
check "C5-1: the outline judgment conditions are so_c1/so_c2" \
  'true' "$(step_sub a1 outline skip_judgment.conditions.so_c1)"
check "C5-1: exactly one SKIP_DISPATCH line" 1 "$(line_count '^SKIP_DISPATCH=')"

echo ""
echo "=== C5-2: outline + judgment branch leaves the step for the orchestrator ==="
# The symmetric counterpart of C5-1: without it, C5-1 would pass on a CLI that
# advanced unconditionally.
at_outline a2
run_rcas --session a2 --signals "S2-architecture" --target outline --advance
check "C5-2: exit 0" 0 "$RC"
check_contains "C5-2: SKIP_MODE reports the judgment branch" "SKIP_MODE=judgment" "$OUT"
check_contains "C5-2: SKIP_DISPATCH reports need-judgment" "SKIP_DISPATCH=need-judgment" "$OUT"
check "C5-2: outline stays pending" '"pending"' "$(step_status a2 outline)"
check_not_contains "C5-2: no ADVANCED= line is emitted" "ADVANCED=" "$OUT"
check "C5-2: no skip judgment was recorded either" 'null' "$(step_sub a2 outline skip_judgment.all_conditions_met)"

echo ""
echo "=== C5-3: detail + auto branch takes the --c3 delegation ==="
# detail's condition schema is sd_c1/sd_c2/sd_c3, and record-skip-judgment
# REFUSES --target detail without --c3. RCAS therefore has to add the flag
# itself; if it did not, the delegate would exit 1 and RCAS would normalize to 3.
at_detail a3
printf '# outline\n' > "$PLANS_DIR/a3-outline.md"
run_rcas --session a3 --signals "" --target detail --advance
check "C5-3: exit 0 (the --c3 delegation succeeded)" 0 "$RC"
check_contains "C5-3: SKIP_MODE reports the auto branch" "SKIP_MODE=auto" "$OUT"
check_contains "C5-3: SKIP_DISPATCH reports advanced" "SKIP_DISPATCH=advanced" "$OUT"
check "C5-3: detail is recorded skipped" '"skipped"' "$(step_status a3 detail)"
check "C5-3: the third detail condition was supplied" 'true' "$(step_sub a3 detail skip_judgment.conditions.sd_c3)"
check "C5-3: all three detail conditions are met" 'true' "$(step_sub a3 detail skip_judgment.all_conditions_met)"
# ...and the sibling target is untouched: a delegation that ignored --target
# would have rewritten outline (complete in this fixture) to skipped instead.
check "C5-3: outline keeps its fixture status" '"complete"' "$(step_status a3 outline)"
check "C5-3: no outline judgment was written" 'null' "$(step_sub a3 outline skip_judgment.all_conditions_met)"

echo ""
echo "=== C5-4: an explicitly false condition outranks the auto branch ==="
# The caller's own judgment beats the complexity-derived auto branch. Both
# members of the pair are covered (CPR-ORTH): a guard that read only so_c1 would
# pass a single-arm test.
at_outline a4a
run_rcas --session a4a --signals "" --target outline --advance --so-c1 false
check "C5-4a: --so-c1 false exits 0 early" 0 "$RC"
check_contains "C5-4a: SKIP_MODE still reports the resolved auto branch" "SKIP_MODE=auto" "$OUT"
check_contains "C5-4a: SKIP_DISPATCH reports no-skip" "SKIP_DISPATCH=no-skip" "$OUT"
check "C5-4a: outline is NOT skipped" '"pending"' "$(step_status a4a outline)"
check_not_contains "C5-4a: the delegate never ran" "ADVANCED=" "$OUT"
check "C5-4a: no skip judgment was recorded" 'null' "$(step_sub a4a outline skip_judgment.all_conditions_met)"

at_outline a4b
run_rcas --session a4b --signals "" --target outline --advance --so-c2 false
check "C5-4b: --so-c2 false exits 0 early" 0 "$RC"
check_contains "C5-4b: SKIP_DISPATCH reports no-skip" "SKIP_DISPATCH=no-skip" "$OUT"
check "C5-4b: outline is NOT skipped" '"pending"' "$(step_status a4b outline)"

# Control arm: the same call with the conditions TRUE still advances, so C5-4
# cannot be passing because --so-c1/--so-c2 disable the advance path entirely.
at_outline a4c
run_rcas --session a4c --signals "" --target outline --advance --so-c1 true --so-c2 true
check "C5-4c: explicitly TRUE conditions still advance" 0 "$RC"
check_contains "C5-4c: SKIP_DISPATCH reports advanced" "SKIP_DISPATCH=advanced" "$OUT"
check "C5-4c: outline is skipped" '"skipped"' "$(step_status a4c outline)"

echo ""
echo "=== C5-5: the legacy (non---advance) path is untouched ==="
# stdout is exactly the bare token, with NO trailing newline and no SKIP_* lines:
# callers capture it into a shell variable and compare it literally.
at_outline a5a
run_rcas --session a5a --signals "" --target outline
check "C5-5a: exit 0" 0 "$RC"
check "C5-5a: stdout is exactly the bare auto token" "auto" "$OUT"
check_not_contains "C5-5a: no SKIP_MODE line leaks into the legacy form" "SKIP_MODE=" "$OUT"
check_not_contains "C5-5a: no SKIP_DISPATCH line leaks either" "SKIP_DISPATCH=" "$OUT"
check "C5-5a: the legacy form settles nothing" '"pending"' "$(step_status a5a outline)"
# ...but it DOES still record the judgment (its pre-#1644 job), so "settles
# nothing" cannot be mistaken for "did nothing".
check "C5-5a: the judgment itself is still recorded" 'true' "$(step_sub a5a outline skip_judgment.all_conditions_met)"

at_outline a5b
run_rcas --session a5b --signals "S2-architecture" --target outline
check "C5-5b: stdout is exactly the bare judgment token" "judgment" "$OUT"
check_not_contains "C5-5b: no SKIP_* line in the legacy judgment form" "SKIP_" "$OUT"

at_detail a5c
run_rcas --session a5c --signals "" --target detail
check "C5-5c: the detail legacy form is the bare auto token too" "auto" "$OUT"
check "C5-5c: the detail legacy form settles nothing" '"pending"' "$(step_status a5c detail)"

echo ""
echo "=== C5-6: DOCUMENTED GAP — --next is not accepted (pinned, not endorsed) ==="
# See the banner at the top of this file. The class contract says
# `--advance [--next]`; this member implements only the first half. Pinned as
# CURRENT behavior so the gap is visible and so an eventual source fix has to
# come here and update the expectation deliberately.
at_outline a6
run_rcas --session a6 --signals "" --target outline --advance --next
check "C5-6a: --next exits 2 (the unknown-flag code, NOT the advance-path 3)" 2 "$RC"
check_contains "C5-6a: stderr names the rejected flag verbatim" "Unknown flag: --next" "$ERR"
check_not_contains "C5-6a: no ACTION= block is emitted" "ACTION=" "$OUT"
check_not_contains "C5-6a: no NEXT_SKILL= line is emitted" "NEXT_SKILL=" "$OUT"
# The rejection happens in the argument loop, BEFORE any node child runs, so the
# whole call is inert — nothing recorded, nothing settled.
check "C5-6a: outline stays pending" '"pending"' "$(step_status a6 outline)"
check "C5-6a: no complexity evaluation was recorded either" 'PROBE_ERR' \
  "$(PROBE_SID=a6 run_with_timeout node -e '
      const wf = require(process.env.WFSTATE_MODULE);
      const s = wf.readState(process.env.PROBE_SID) || {};
      process.stdout.write(s.complexity_evaluation ? "recorded" : "PROBE_ERR");
    ' 2>/dev/null || echo PROBE_FAIL)"

# The bare --next form (without --advance) hits the same catch-all. Recorded so
# the gap's shape is unambiguous: this is not "--next requires --advance"
# validation (which is what record-skip-judgment does), it is "no such flag".
at_outline a6b
run_rcas --session a6b --signals "" --target outline --next
check "C5-6b: bare --next exits 2 as well" 2 "$RC"
check_contains "C5-6b: the same unknown-flag diagnostic" "Unknown flag: --next" "$ERR"
# Contrast pin (CPR-ORTH evidence that the class really does differ here):
# record-skip-judgment rejects the same bare form with exit 1 and a DIFFERENT
# diagnostic, because it knows the flag and is validating its combination.
RSJ_ERR="$( (run_with_timeout node "$AGENTS_DIR_N/bin/workflow/record-skip-judgment" \
  --session a6b --target outline --c1 true --c2 true --next >/dev/null) 2>&1 || true)"
check_contains "C5-6b: a class member that KNOWS --next says so differently" \
  "--next is only meaningful with --advance" "$RSJ_ERR"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
