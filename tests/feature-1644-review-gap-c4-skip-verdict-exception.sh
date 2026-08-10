#!/usr/bin/env bash
# Tests: bin/workflow/record-skip-verdict, hooks/workflow-state/state-io/skip-verdict.js, tests/feature-1644-sibling-cli-advance.sh
# Tags: tl2, workflow, advance, named-exception, record-skip-verdict, class-completeness, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C4 — the NAMED EXCEPTION to the advance class.
#
# Why this file exists: every other CLI under bin/workflow/ that settles a step
# learned `--advance` / `--next` in #1644. record-skip-verdict deliberately did
# NOT, and its header states why: its only caller is the skip-verifier subagent,
# and a subagent must not advance the workflow on its own behalf — recording a
# verdict is a PRECONDITION for advancing, not the advance itself. The main
# conversation observes the subagent and calls `next-step --advance --next`.
#
# So this file PINS THE DESIGN INTENT. It must fail if someone "completes the
# class" by teaching record-skip-verdict to advance, and it must equally fail if
# the CLI stops recording verdicts correctly. It does NOT demand the flags.
#
# Sibling boundary (no duplication): tests/feature-1644-sibling-cli-advance.sh
# S11 already owns the three-way partition of bin/workflow/ (advance members /
# named exceptions / non-members) and registers record-skip-verdict in
# NAMED_EXCEPTIONS. What S11 does NOT do — and what is added here — is prove
# (a) the registration is backed by a source-level rationale rather than by a
# test-side literal, and (b) the CLI actually REFUSES --advance / --next at
# runtime with no state effect.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real skip-verifier subagent invokes this CLI with the argv shape
#   asserted here, and whether the main conversation then issues the follow-up
#   `next-step --advance --next` that this CLI deliberately does not issue.
# - Whether settings.json permissions.allow admits the record-skip-verdict argv
#   form without an approval dialog in a live session.
# Closest-to-action mitigation: surfaced at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
RSV="$AGENTS_DIR_N/bin/workflow/record-skip-verdict"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
# CPR-SSOT: the one fixture-state reader shared by every #1644 test file.
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
SIBLING_TEST="$AGENTS_DIR/tests/feature-1644-sibling-cli-advance.sh"

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

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

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

OUT=""; ERR=""; RC=0
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
state_bytes() { cat "$WORKFLOW_DIR/${1}.json" 2>/dev/null | tr -d '\r'; }

echo "=== C4-1: the confirm path records the verdict and says so exactly ==="
at_outline c1
run_cli node "$RSV" --session c1 --target outline --verdict confirm --reason "outline artifact was unnecessary"
check "C4-1: exit 0" 0 "$RC"
# Byte-exact: the subagent's caller parses this line by prefix, so the shape is
# part of the contract, not incidental chatter.
check "C4-1: stdout is exactly RECORDED=outline verdict=confirm" \
  "RECORDED=outline verdict=confirm" "$OUT"
check "C4-1: readSkipVerdict reflects the confirm" '"confirm"' "$(step_sub c1 outline skip_verdict.verdict)"
check_contains "C4-1: the source names the CLI and carries the reason" \
  "record-skip-verdict-cli:outline artifact was unnecessary" "$(step_sub c1 outline skip_verdict.source)"
# Recording a verdict is a PRECONDITION for advancing, never the advance: the
# step's own status must be untouched by a confirm.
check "C4-1: the step status is untouched by the recording" '"pending"' "$(step_status c1 outline)"

echo ""
echo "=== C4-2: the veto path is the symmetric counterpart (CPR-ORTH) ==="
at_outline c2
run_cli node "$RSV" --session c2 --target outline --verdict veto --reason "outline was in fact required"
check "C4-2: exit 0" 0 "$RC"
check "C4-2: stdout is exactly RECORDED=outline verdict=veto" \
  "RECORDED=outline verdict=veto" "$OUT"
check "C4-2: readSkipVerdict reflects the veto" '"veto"' "$(step_sub c2 outline skip_verdict.verdict)"
check "C4-2: a veto does not settle the step either" '"pending"' "$(step_status c2 outline)"

echo ""
echo "=== C4-3: --target detail is the other symmetric member ==="
at_outline c3
run_cli node "$RSV" --session c3 --target detail --verdict confirm --reason "detail plan adds nothing here"
check "C4-3a: detail confirm exits 0" 0 "$RC"
check "C4-3a: stdout names detail" "RECORDED=detail verdict=confirm" "$OUT"
check "C4-3a: detail verdict is recorded" '"confirm"' "$(step_sub c3 detail skip_verdict.verdict)"
# ...and the sibling target is NOT written: a per-target write that leaked into
# both steps would pass every assertion above.
check "C4-3a: the outline verdict is untouched" 'null' "$(step_sub c3 outline skip_verdict.verdict)"

at_outline c3b
run_cli node "$RSV" --session c3b --target detail --verdict veto --reason "detail plan is still required"
check "C4-3b: detail veto exits 0" 0 "$RC"
check "C4-3b: stdout names the veto" "RECORDED=detail verdict=veto" "$OUT"
check "C4-3b: detail veto is recorded" '"veto"' "$(step_sub c3b detail skip_verdict.verdict)"

echo ""
echo "=== C4-4: NAMED EXCEPTION — --advance / --next are REJECTED ==="
# This is the load-bearing case. record-skip-verdict parses with node's
# parseArgs({strict:true}), so an advance-class flag is an argument error rather
# than a silently ignored token. The main conversation — not this subagent-only
# CLI — performs the advance via `next-step --advance --next`.
at_outline c4a
BEFORE="$(state_bytes c4a)"
run_cli node "$RSV" --session c4a --target outline --verdict confirm --reason "advance must be refused" --advance
if [ "$RC" -ne 0 ]; then pass "C4-4a: --advance exits nonzero (rc=$RC)"; else fail "C4-4a: --advance exits nonzero -- got 0"; fi
check_not_contains "C4-4a: no ADVANCED= line is emitted" "ADVANCED=" "$OUT"
check_not_contains "C4-4a: no ACTION= block is emitted" "ACTION=" "$OUT"
check_not_contains "C4-4a: not even the RECORDED= line is emitted" "RECORDED=" "$OUT"
# Pattern 1 (negative assertion): the protected resource itself is unchanged.
check "C4-4a: the target step is still pending" '"pending"' "$(step_status c4a outline)"
check "C4-4a: no verdict was recorded either" 'null' "$(step_sub c4a outline skip_verdict.verdict)"
check "C4-4a: the state file is byte-for-byte unchanged" "$BEFORE" "$(state_bytes c4a)"

at_outline c4b
BEFORE="$(state_bytes c4b)"
run_cli node "$RSV" --session c4b --target outline --verdict confirm --reason "next must be refused" --next
if [ "$RC" -ne 0 ]; then pass "C4-4b: --next exits nonzero (rc=$RC)"; else fail "C4-4b: --next exits nonzero -- got 0"; fi
check_not_contains "C4-4b: no ACTION= block is emitted" "ACTION=" "$OUT"
check_not_contains "C4-4b: no NEXT_SKILL= line is emitted" "NEXT_SKILL=" "$OUT"
check "C4-4b: the target step is still pending" '"pending"' "$(step_status c4b outline)"
check "C4-4b: the state file is byte-for-byte unchanged" "$BEFORE" "$(state_bytes c4b)"

echo ""
echo "=== C4-5: the exception is registered, not merely unimplemented ==="
# Two independent registrations must agree, so neither side can drift alone:
#  (1) the SOURCE documents the rationale at the exception itself, and
#  (2) the sibling class-completeness guard lists it under NAMED_EXCEPTIONS
#      rather than under the advance members.
HDR="$(sed -n '1,20p' "$AGENTS_DIR/bin/workflow/record-skip-verdict")"
check_contains "C4-5a: the source declares itself a NAMED EXCEPTION" "NAMED EXCEPTION" "$HDR"
check_contains "C4-5a: ...to the #1644 advance class specifically" "advance class" "$HDR"
check_contains "C4-5a: ...and names the subagent rationale" "subagent" "$HDR"
# The absence check is what makes this an exception rather than a member: no
# --advance implementation may quietly appear in the file. Only the `//` comment
# lines that document the exception are allowed to mention the token.
ADV_NONCOMMENT="$(grep -n -- '--advance' "$AGENTS_DIR/bin/workflow/record-skip-verdict" \
  | grep -vE '^[0-9]+:(//|\s*\*)' || true)"
check "C4-5b: no non-comment --advance token exists in the source" "" "$ADV_NONCOMMENT"

if [ -f "$SIBLING_TEST" ]; then
  EXC_LINE="$(grep -n '^NAMED_EXCEPTIONS=' "$SIBLING_TEST" || true)"
  check_contains "C4-5c: the sibling guard registers it under NAMED_EXCEPTIONS" \
    "record-skip-verdict" "$EXC_LINE"
  MEM_LINE="$(grep -n '^ADVANCE_MEMBERS=' "$SIBLING_TEST" || true)"
  check_not_contains "C4-5c: ...and NOT under ADVANCE_MEMBERS" "record-skip-verdict" "$MEM_LINE"
else
  fail "C4-5c: the sibling class-completeness guard exists -- $SIBLING_TEST not found"
fi

echo ""
echo "=== C4-6: error cases refuse and leave the state untouched ==="
# refuses <label> <sid> -- <argv...>
refuses() {
  local label="$1" sid="$2"; shift 3
  at_outline "$sid"
  local before; before="$(state_bytes "$sid")"
  run_cli node "$RSV" "$@"
  check "$label: exit 1" 1 "$RC"
  check_not_contains "$label: no RECORDED= line" "RECORDED=" "$OUT"
  check "$label: no verdict recorded" 'null' "$(step_sub "$sid" outline skip_verdict.verdict)"
  check "$label: state byte-for-byte unchanged" "$before" "$(state_bytes "$sid")"
}

refuses "C4-6a invalid --target" c6a -- --session c6a --target research --verdict confirm --reason "bad target"
refuses "C4-6b invalid --verdict" c6b -- --session c6b --target outline --verdict maybe --reason "bad verdict"
# `pending` is the internal initial value written by the A-4 co-write; the CLI
# refuses it explicitly so a subagent cannot un-resolve a verdict it already gave.
refuses "C4-6c --verdict pending is explicitly refused" c6c -- --session c6c --target outline --verdict pending --reason "reset the verdict"
refuses "C4-6d missing --verdict" c6d -- --session c6d --target outline --reason "no verdict given"
refuses "C4-6e missing --target" c6e -- --session c6e --verdict confirm --reason "no target given"
refuses "C4-6f missing --session" c6f -- --target outline --verdict confirm --reason "no session given"

# --reason is optional: its absence must NOT be an error, or the subagent's
# minimal call shape would break. The recorded source falls back to no-reason.
at_outline c6g
run_cli node "$RSV" --session c6g --target outline --verdict confirm
check "C4-6g: --reason is optional (exit 0)" 0 "$RC"
check_contains "C4-6g: the fallback source is recorded" "no-reason" "$(step_sub c6g outline skip_verdict.source)"

# The error diagnostics go to stderr, never stdout — a caller that parses stdout
# by prefix must not see a refusal as a recording.
at_outline c6h
run_cli node "$RSV" --session c6h --target outline --verdict maybe --reason "diagnostic stream check"
check_contains "C4-6h: the refusal diagnostic names the CLI on stderr" "record-skip-verdict:" "$ERR"
check "C4-6h: stdout stays empty on a refusal" "" "$OUT"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
