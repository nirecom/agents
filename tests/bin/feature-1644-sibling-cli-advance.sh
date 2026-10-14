#!/usr/bin/env bash
# Tests: bin/workflow/record-skip-judgment, bin/workflow/set-workflow-type, bin/workflow/next-step, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, sibling-cli, class-completeness, scope:issue-specific, pwsh-not-required

# #1644 stage 1 — the `--advance` forward operation on the SIBLING workflow CLIs, plus
# the class-completeness guard partitioning bin/workflow/ into advance members / named
# exceptions / non-members. Written BEFORE the implementation.

# TL3 gap: whether the migrated SKILL.md steps issue the single --advance call shape,
# and whether settings.json permissions.allow admits the new argv forms live.
# Mitigation: bin/check-verification-gate.sh category skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SCRIPT_CHECKOUT_ROOT_N="$(nrm "$SCRIPT_CHECKOUT_ROOT")"
RSJ="$SCRIPT_CHECKOUT_ROOT_N/bin/workflow/record-skip-judgment"
SWT="$SCRIPT_CHECKOUT_ROOT_N/bin/workflow/set-workflow-type"
WFSTATE_MODULE="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state"; export WFSTATE_MODULE
PROBE="$SCRIPT_CHECKOUT_ROOT_N/tests/bin/feature-1644-advance-transaction/state-probe.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Pinned as a PAIR (#1799) so supervisor-emit never appends to the real ~/.workflow-plans.
export WORKFLOW_STATE_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
# The broker's ticket store (#2460): pinned so a planted claim never lands in a real home.
export AGENTS_STATE_DIR="$(nrm "$TMPDIR_BASE/agents-state")"
unset CLAUDE_CODE_SESSION_ID
# shellcheck source=../lib/skip-judgment.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/skip-judgment.sh"

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
  # #2277: an unapproved complete plan stage reads as pending; bind approvals.
  run_with_timeout node "$SCRIPT_CHECKOUT_ROOT_N/tests/lib/plan-approval-fixture.js" inject-complete \
    "$(nrm "$WORKFLOW_DIR/${sid}.json")" clarify_intent outline detail >/dev/null 2>&1 || true
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
# Projected step entry with updated_at, skip_verdict and skip_judgment.recorded_at
# removed — the stable shape an idempotent repeat must not disturb. The three
# excluded names are all wall-clock/per-path fields rewritten on every call; the
# substantive halves (status, skip_reason, skip_judgment.conditions, ...) stay in.
step_entry()  { probe "$1" "$2" entry; }
action_lines() { printf '%s\n' "$OUT" | grep -c '^ACTION=' || true; }
# top_field <sid> [field] — a top-level state field (default: deliverable_type, #2527).
top_field() {
  PROBE_SID="$1" TF="${2:-deliverable_type}" run_with_timeout node -e '
    const wf = require(process.env.WFSTATE_MODULE);
    const s = wf.readState(process.env.PROBE_SID) || {};
    const v = (s.current && s.current[process.env.TF]) !== undefined
      ? s.current[process.env.TF] : s[process.env.TF];
    process.stdout.write(JSON.stringify(v === undefined ? null : v));
  ' 2>/dev/null || echo PROBE_FAIL
}

# #2460 stage 4: the --cond/--source/--ticket form. Each session uses its own ticket.
RSJ_OK=(--cond so_c1=true --cond so_c2=true --source subagent --ticket 0123456789abcdef)
RSJ_C2F=(--cond so_c1=true --cond so_c2=false --source subagent --ticket 0123456789abcdef)
RSJ_TID=0123456789abcdef
CONDS_OK='{"so_c1":true,"so_c2":true}'
CONDS_C2F='{"so_c1":true,"so_c2":false}'
# ticketed <sid> [conds-json] [field=json ...] — the finalized claim the CLI verifies against.
ticketed() {
  local sid="$1" conds="${2:-$CONDS_OK}"
  shift
  [ "$#" -gt 0 ] && shift
  plant_finalized_ticket "$SCRIPT_CHECKOUT_ROOT_N" "$sid" outline "$RSJ_TID" "$conds" subagent "$@"
}
judgment() {
  PROBE_SID="$1" run_with_timeout node -e '
    const wf = require(process.env.WFSTATE_MODULE);
    process.stdout.write(JSON.stringify(wf.readSkipJudgment(process.env.PROBE_SID, "outline") || null));
  ' 2>/dev/null || echo PROBE_FAIL
}

echo "=== S1: record-skip-judgment WITHOUT --advance keeps its exact stdout ==="
at_outline s1; ticketed s1
run_cli node "$RSJ" --session s1 --target outline "${RSJ_OK[@]}"
check "S1: exit 0" 0 "$RC"
check "S1: stdout is byte-identical to the pre-#1644 form" \
  "RECORDED=outline all_conditions_met=true" "$OUT"
check "S1: the step itself is NOT settled without --advance" '"pending"' "$(step_status s1 outline)"

echo ""
echo "=== S2: record-skip-judgment --advance settles the target step ==="
at_outline s2; ticketed s2
run_cli node "$RSJ" --session s2 --target outline "${RSJ_OK[@]}" --advance
check "S2: exit 0" 0 "$RC"
check_contains "S2: the legacy judgment line survives" "RECORDED=outline all_conditions_met=true" "$OUT"
check_contains "S2: the advance line reports the settled step" "ADVANCED=outline status=skipped" "$OUT"
# `RECORDED=` stays this CLI's own judgment token. If the advance path also
# emitted one, a prefix-keyed parser would see two lines with the same key and
# incompatible shapes.
check "S2: exactly one RECORDED= line" 1 "$(printf '%s\n' "$OUT" | grep -c '^RECORDED=' || true)"
check "S2: outline is skipped" '"skipped"' "$(step_status s2 outline)"
check "S2: bare --advance emits no ACTION line" 0 "$(action_lines)"
# The recorded verdict is the authority for the skip, so the reason must say so
# in the state itself — a free-text reason here would be indistinguishable from
# a model-authored justification (#1286).
check_contains "S2: skip_reason carries the recorded-verdict: prefix" \
  "recorded-verdict:" "$(step_sub s2 outline skip_reason)"
# A-4 co-write (#1681) is owned by the same single writer on every path.
check "S2: skip_verdict.verdict is pending" '"pending"' "$(step_sub s2 outline skip_verdict.verdict)"

echo ""
echo "=== S3: record-skip-judgment --advance does NOT settle when a condition fails ==="
at_outline s3; ticketed s3 "$CONDS_C2F"
run_cli node "$RSJ" --session s3 --target outline "${RSJ_C2F[@]}" --advance
check "S3: exit 0 (a false judgment is a valid recording, not an error)" 0 "$RC"
check_contains "S3: the judgment is still recorded" "all_conditions_met=false" "$OUT"
check "S3: outline stays pending" '"pending"' "$(step_status s3 outline)"
# What S3 guards is that the forward operation never ran: with all_conditions_met
# false the CLI records the judgment and stops. The advance half announces itself
# with `ADVANCED=<step> status=<status>`, so both halves of that line must be absent.
check_not_contains "S3: no advance line is emitted" "ADVANCED=" "$OUT"
check_not_contains "S3: no step-status line is emitted" "status=skipped" "$OUT"

echo ""
echo "=== S4: record-skip-judgment --advance --next advances the current step ==="
at_outline s4; ticketed s4
run_cli node "$RSJ" --session s4 --target outline "${RSJ_OK[@]}" --advance --next
check "S4: exit 0" 0 "$RC"
check_contains "S4: ADVANCED=outline" "ADVANCED=outline" "$OUT"
check "S4: exactly one ACTION line" 1 "$(action_lines)"

echo ""
echo "=== S5: a failed record emits no ACTION line and exits 2 ==="
BLOCK="$TMPDIR_BASE/blockfile"; : > "$BLOCK"
at_outline s5; ticketed s5
run_cli env WORKFLOW_STATE_DIR="$(nrm "$BLOCK")" node "$RSJ" \
  --session s5 --target outline "${RSJ_OK[@]}" --advance --next
check "S5: unwritable state exits 2" 2 "$RC"
# The ticket check also exits 2, so the code alone would not show the write was reached.
check_contains "S5: the failure is the write, not the ticket check" "write verification failed" "$ERR"
check "S5: no ACTION line on failure" 0 "$(action_lines)"

echo ""
echo "=== S6: set-workflow-type positional form is unchanged ==="
# wf-meta, not wf-code: readState() projects deliverable_type with a "wf-code"
# DEFAULT, so asserting "wf-code" would pass on a session that was never written.
at_outline s6
run_cli node "$SWT" s6 wf-meta
check "S6: exit 0" 0 "$RC"
check "S6: stdout stays empty" "" "$OUT"
check "S6: deliverable_type is recorded" '"wf-meta"' "$(top_field s6)"

echo ""
echo "=== S7: set-workflow-type --advance argument validation ==="
make_state s7a ""
run_cli node "$SWT" --session s7a --type wf-code --advance
check "S7a: --advance without --step/--status exits 1" 1 "$RC"
check "S7a: nothing is recorded" '"pending"' "$(step_status s7a workflow_init)"

make_state s7b ""
run_cli node "$SWT" --session s7b --type wf-code --advance --step workflow_init
check "S7b: --advance without --status exits 1" 1 "$RC"

make_state s7c ""
run_cli node "$SWT" s7c wf-meta --advance --step workflow_init --status complete
check "S7c: mixing positional and flag form exits 1" 1 "$RC"
check "S7c: the mixed form records nothing" '"pending"' "$(step_status s7c workflow_init)"
# "wf-code" here is the projection DEFAULT, i.e. the absence of a write — the one
# value that distinguishes "never recorded" from the wf-meta this call asked for.
check "S7c: the mixed form does not set deliverable_type either" '"wf-code"' "$(top_field s7c)"

echo ""
echo "=== S8: set-workflow-type --advance records the step and the type together ==="
make_state s8 ""
run_cli node "$SWT" --session s8 --type wf-meta --advance --step workflow_init --status complete
check "S8: exit 0" 0 "$RC"
check_contains "S8: the advance line reports the settled step" "ADVANCED=workflow_init status=complete" "$OUT"
check_contains "S8: the type line precedes it" "WORKFLOW_TYPE=wf-meta" "$OUT"
check "S8: workflow_init is complete" '"complete"' "$(step_status s8 workflow_init)"
check "S8: deliverable_type is still recorded" '"wf-meta"' "$(top_field s8)"

echo ""
echo "=== S11: class-completeness guard over bin/workflow/ ==="
# Three-way partition. A new CLI under bin/workflow/ must be classified here
# before it can land, which is what makes the advance class enumerable at all.
ADVANCE_MEMBERS="next-step record-skip-judgment set-deliverable-type set-workflow-type"
# record-skip-verdict is a manual resolver: it records a verdict about a skip
# someone else declared, so it never advances the workflow on its own behalf.
# That is why it is an exception and not a member.
NAMED_EXCEPTIONS="record-skip-verdict"
# derive-complexity-level (#2099) is a NON-member by construction: it is a
# stateless derivation CLI (detail.md D1/D4) that reads no session and writes no
# state, so there is no step for it to advance. S11c below is what pins that —
# it must carry no --advance token at all.
# #2460: jev-judge takes no --advance of its own; its finalize hands --advance to
# a record-skip-judgment child from its library, never from the CLI file.
NON_MEMBERS="adopt-session-state check-plan-approval derive-complexity-level handoff-append jev-judge normalize-judge-signals pr-state read-complexity-evaluation read-merge-base-baseline read-session-facts read-step-status reconcile-state record-complexity-evaluation record-merge-base-baseline release-channel render-issue-comments run-tests-baseline-evidence run-tests-completion-note workflow-init-driver"

ACTUAL="$(ls "$SCRIPT_CHECKOUT_ROOT/bin/workflow" | grep -v '^lib$' | sort | tr '\n' ' ')"
EXPECTED="$(printf '%s %s %s' "$ADVANCE_MEMBERS" "$NAMED_EXCEPTIONS" "$NON_MEMBERS" \
  | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
check "S11a: bin/workflow/ minus lib is exactly the direct sum of the 3 registries" \
  "$EXPECTED" "$ACTUAL"

# (2) every advance member accepts the flag. next-step delegates its parsing to
# bin/workflow/lib/next-step/, so its search scope includes that directory.
for m in $ADVANCE_MEMBERS; do
  if [ "$m" = "next-step" ]; then
    scope="$SCRIPT_CHECKOUT_ROOT/bin/workflow/next-step $SCRIPT_CHECKOUT_ROOT/bin/workflow/lib"
  else
    scope="$SCRIPT_CHECKOUT_ROOT/bin/workflow/$m"
  fi
  # shellcheck disable=SC2086
  if grep -rqF -- '--advance' $scope 2>/dev/null; then
    pass "S11b: $m declares --advance"
  else
    fail "S11b: $m declares --advance -- no --advance token found in $scope"
  fi
done

# ... and (3) no non-member does. Checked statically rather than by invocation:
# workflow-init-driver silently ignores unknown flags, so running it with
# --advance would execute a real workflow init instead of reporting a rejection.
for m in $NON_MEMBERS; do
  # A missing file makes grep exit non-zero, which would otherwise be read as
  # "declares no --advance" — a registered non-member that does not exist yet
  # must fail here, not pass vacuously.
  if [ ! -f "$SCRIPT_CHECKOUT_ROOT/bin/workflow/$m" ]; then
    fail "S11c: $m is registered as a non-member but bin/workflow/$m does not exist"
    continue
  fi
  if grep -qF -- '--advance' "$SCRIPT_CHECKOUT_ROOT/bin/workflow/$m"; then
    fail "S11c: $m must NOT accept --advance -- found an --advance token"
  else
    pass "S11c: $m does not accept --advance"
  fi
done

echo ""
echo "=== S13: --advance argument validation on record-skip-judgment ==="
# next-step has A12 and set-workflow-type has S7a/b/c; without these the class's
# exit-1 contract (plan line 254) is unproven for half its members.
make_state s13a "workflow_init clarify_intent research"
run_cli node "$RSJ" --session s13a "${RSJ_OK[@]}" --advance
check "S13a: record-skip-judgment --advance without --target exits 1" 1 "$RC"
check_not_contains "S13a: the --cond form itself is accepted" "unknown argument: --cond" "$ERR"
check "S13a: nothing is settled" '"pending"' "$(step_status s13a outline)"
check "S13a: no ACTION line" 0 "$(action_lines)"

# --next is defined as meaningful only alongside --advance (plan line 148), so the
# lone form is an argument error rather than a silently ignored flag.
make_state s13b "workflow_init clarify_intent research"
run_cli node "$RSJ" --session s13b --target outline "${RSJ_OK[@]}" --next
check "S13b: record-skip-judgment --next without --advance exits 1" 1 "$RC"
check_contains "S13b: the diagnostic is the --next rule" "--next is only meaningful with --advance" "$ERR"
check "S13b: the judgment is not recorded either" '"pending"' "$(step_status s13b outline)"

echo ""
echo "=== S14: set-workflow-type --advance write failure exits 2 with no ACTION ==="
# The exit-2 half of the class contract (A2 for next-step, S5 for
# record-skip-judgment). A regular file at
# the workflow-dir path makes every write fail with ENOTDIR.
make_state s14 ""
RC=0
OUT="$(WORKFLOW_STATE_DIR="$(nrm "$BLOCK")" run_with_timeout node "$SWT" \
  --session s14 --type wf-code --advance --step workflow_init --status complete --next 2>/dev/null)" || RC=$?
check "S14: unwritable state exits 2" 2 "$RC"
check "S14: no ACTION line on failure" 0 "$(action_lines)"
check_not_contains "S14: no NEXT_SKILL line on failure" "NEXT_SKILL=" "$OUT"
# The fixture state file itself is untouched, so the failure is a write failure and
# not a silent success against some other directory.
check "S14: the real fixture state is unchanged" '"pending"' "$(step_status s14 workflow_init)"

echo ""
echo "=== S15: repeating --advance is a no-op on every sibling ==="
# A5 proves this for next-step only. A sibling that re-fires the write would
# re-run the workflow_init downstream reset or overwrite an A-4 verdict that
# record-skip-verdict has since resolved. #2460: a same-ticket repeat on a
# skipped step does nothing and reports REPLAYED=1 (idempotency table).
at_outline s15a; ticketed s15a
run_cli node "$RSJ" --session s15a --target outline "${RSJ_OK[@]}" --advance
check "S15a: the first record-skip-judgment --advance exits 0" 0 "$RC"
S15A_ENTRY="$(step_entry s15a outline)"
run_cli node "$RSJ" --session s15a --target outline "${RSJ_OK[@]}" --advance
check "S15a: the repeat exits 0" 0 "$RC"
check_contains "S15a: the repeat reports REPLAYED=1" "REPLAYED=1" "$OUT"
check_contains "S15a: the repeat keeps the RECORDED= line" "RECORDED=outline" "$OUT"
# Asserted before the equality check so "unchanged" cannot mean "never settled".
check "S15a: outline is still skipped after the repeat" '"skipped"' "$(step_status s15a outline)"
check "S15a: the projection is unchanged" "$S15A_ENTRY" "$(step_entry s15a outline)"

make_state s15b ""
run_cli node "$SWT" --session s15b --type wf-meta --advance --step workflow_init --status complete
check "S15b: the first set-workflow-type --advance exits 0" 0 "$RC"
S15B_ENTRY="$(step_entry s15b workflow_init)"
run_cli node "$SWT" --session s15b --type wf-meta --advance --step workflow_init --status complete
check "S15b: the repeat exits 0" 0 "$RC"
check_contains "S15b: the repeat reports already=true" "already=true" "$OUT"
check "S15b: workflow_init is still complete after the repeat" '"complete"' "$(step_status s15b workflow_init)"
check "S15b: the projection is unchanged" "$S15B_ENTRY" "$(step_entry s15b workflow_init)"
check "S15b: deliverable_type survives the repeat" '"wf-meta"' "$(top_field s15b)"

echo ""
echo "=== S16: --ticket must be a finalized ticket of this session, target and answer ==="
# #2460: the command line is not evidence of a judgment. S1/S2 are the accepting control.
# refused <label> <sid> <diagnostic> [argv override...] — exit 2, nothing written or settled.
refused() {
  local label="$1" sid="$2" want="$3"
  shift 3
  [ "$#" -gt 0 ] || set -- "${RSJ_OK[@]}"
  run_cli node "$RSJ" --session "$sid" --target outline "$@" --advance
  check "S16 [$label]: exits 2" 2 "$RC"
  check_contains "S16 [$label]: the diagnostic" "$want" "$ERR"
  check "S16 [$label]: stdout stays empty" "" "$OUT"
  check "S16 [$label]: no judgment is written" "null" "$(judgment "$sid")"
  check "S16 [$label]: outline stays pending" '"pending"' "$(step_status "$sid" outline)"
}
NOT_FINALIZED="--ticket is not a finalized ticket of this session and target"
at_outline s16a
refused "no ticket in the store" s16a "$NOT_FINALIZED"
at_outline s16b
plant_finalized_ticket "$SCRIPT_CHECKOUT_ROOT_N" s16b outline fedcba9876543210 "$CONDS_OK" subagent
refused "a ticket id the store does not hold" s16b "$NOT_FINALIZED"
at_outline s16c; at_outline s16other; ticketed s16other
refused "a ticket of another session's store" s16c "$NOT_FINALIZED"
at_outline s16d; ticketed s16d "$CONDS_OK" 'session_id="s16other"'
refused "a claim naming another session" s16d "$NOT_FINALIZED"
at_outline s16e; ticketed s16e "$CONDS_OK" 'target="detail"'
refused "a ticket of the other target" s16e "$NOT_FINALIZED"
at_outline s16f; ticketed s16f "$CONDS_OK" 'finalized=false'
refused "a claim that is not finalized yet" s16f "$NOT_FINALIZED"
at_outline s16g; ticketed s16g "$CONDS_OK" 'result=null'
refused "a finalized claim with no answer" s16g "$NOT_FINALIZED"
at_outline s16h
plant_finalized_ticket "$SCRIPT_CHECKOUT_ROOT_N" s16h outline "$RSJ_TID" "$CONDS_OK" jev
refused "a --source the ticket did not finalize" s16h "$NOT_FINALIZED"
at_outline s16i; ticketed s16i "$CONDS_C2F"
refused "conditions the ticket did not finalize" s16i "--cond differs from the ticket's finalized answer"
at_outline s16j; ticketed s16j
refused "a true answer downgraded on the command line" s16j \
  "--cond differs from the ticket's finalized answer" "${RSJ_C2F[@]}"
at_outline s16k; ticketed s16k "$CONDS_OK" 'version=1'
refused "a claim of a retired store version" s16k "$NOT_FINALIZED"

echo ""
echo "=== S17: a skip is refused once the ticket's sources changed ==="
# #2460: the judgment is about the sources as queried. The claim fingerprints them at plant time.
INTENT_OF() { printf '%s' "$PLANS_DIR/$1-intent.md"; }
at_outline s17a; printf 'intent v1\n' > "$(INTENT_OF s17a)"; ticketed s17a
run_cli node "$RSJ" --session s17a --target outline "${RSJ_OK[@]}" --advance
check "S17a: unchanged sources still record and settle: exit 0" 0 "$RC"
check "S17a: outline is skipped" '"skipped"' "$(step_status s17a outline)"
# stale <label> <sid> — the all-true answer is refused and leaves nothing behind.
stale() {
  run_cli node "$RSJ" --session "$2" --target outline "${RSJ_OK[@]}" --advance
  check "S17 [$1]: exits 2" 2 "$RC"
  check_contains "S17 [$1]: the diagnostic" "the ticket's sources changed since its query" "$ERR"
  check "S17 [$1]: no judgment is written" "null" "$(judgment "$2")"
  check "S17 [$1]: outline stays pending" '"pending"' "$(step_status "$2" outline)"
}
at_outline s17b; printf 'intent v1\n' > "$(INTENT_OF s17b)"; ticketed s17b
printf 'intent v2\n' > "$(INTENT_OF s17b)"
stale "an edited source" s17b
at_outline s17c; ticketed s17c; printf 'intent v1\n' > "$(INTENT_OF s17c)"
stale "a source that appeared" s17c
at_outline s17d; printf 'intent v1\n' > "$(INTENT_OF s17d)"; ticketed s17d; rm -f "$(INTENT_OF s17d)"
stale "a source that vanished" s17d
at_outline s17e; ticketed s17e "$CONDS_OK" 'artifacts_sha256=null'
stale "a ticket with no source fingerprint" s17e
# A false answer skips nothing, so it is recorded whatever happened to the sources.
at_outline s17f; printf 'intent v1\n' > "$(INTENT_OF s17f)"; ticketed s17f "$CONDS_C2F"
printf 'intent v2\n' > "$(INTENT_OF s17f)"
run_cli node "$RSJ" --session s17f --target outline "${RSJ_C2F[@]}" --advance
check "S17f: a false answer on changed sources exits 0" 0 "$RC"
check_contains "S17f: and is recorded" "RECORDED=outline all_conditions_met=false" "$OUT"
check "S17f: outline stays pending" '"pending"' "$(step_status s17f outline)"
# A repeat of an already settled skip is a replay: it writes nothing, so it is not re-checked.
printf 'intent v2\n' > "$(INTENT_OF s17a)"
run_cli node "$RSJ" --session s17a --target outline "${RSJ_OK[@]}" --advance
check "S17g: the repeat after an edit exits 0" 0 "$RC"
check_contains "S17g: the repeat reports REPLAYED=1" "REPLAYED=1" "$OUT"
check "S17g: outline is still skipped" '"skipped"' "$(step_status s17a outline)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
