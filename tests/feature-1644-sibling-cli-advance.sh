#!/usr/bin/env bash
# Tests: bin/workflow/record-skip-judgment, bin/workflow/set-workflow-type, bin/workflow/record-complexity-and-skip, bin/workflow/next-step, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, advance, sibling-cli, class-completeness, scope:issue-specific, pwsh-not-required
#
# #1644 stage 1 — the `--advance` forward operation on the SIBLING workflow CLIs,
# plus the class-completeness guard that keeps bin/workflow/ partitioned into
# advance members / named exceptions / non-members.
# Written BEFORE the implementation: RED until each CLI learns --advance.
#
# TL3 gap (what this test does NOT catch):
# - Whether the migrated SKILL.md steps actually issue the single --advance call
#   shape instead of the legacy CLI-then-next-step pair.
# - Whether settings.json permissions.allow admits the new argv forms without an
#   approval dialog in a live session.
# Closest-to-action mitigation: surfaced at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
RSJ="$AGENTS_DIR_N/bin/workflow/record-skip-judgment"
SWT="$AGENTS_DIR_N/bin/workflow/set-workflow-type"
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

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
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
# Projected step entry with updated_at, skip_verdict and skip_judgment.recorded_at
# removed — the stable shape an idempotent repeat must not disturb. The three
# excluded names are all wall-clock/per-path fields rewritten on every call; the
# substantive halves (status, skip_reason, skip_judgment.conditions, ...) stay in.
step_entry()  { probe "$1" "$2" entry; }
action_lines() { printf '%s\n' "$OUT" | grep -c '^ACTION=' || true; }
# top_field <sid> [field] — a top-level state field (default: workflow_type).
top_field() {
  PROBE_SID="$1" TF="${2:-workflow_type}" run_with_timeout node -e '
    const wf = require(process.env.WFSTATE_MODULE);
    const s = wf.readState(process.env.PROBE_SID) || {};
    const v = (s.current && s.current[process.env.TF]) !== undefined
      ? s.current[process.env.TF] : s[process.env.TF];
    process.stdout.write(JSON.stringify(v === undefined ? null : v));
  ' 2>/dev/null || echo PROBE_FAIL
}

echo "=== S1: record-skip-judgment WITHOUT --advance keeps its exact stdout ==="
at_outline s1
run_cli node "$RSJ" --session s1 --target outline --c1 true --c2 true
check "S1: exit 0" 0 "$RC"
check "S1: stdout is byte-identical to the pre-#1644 form" \
  "RECORDED=outline all_conditions_met=true" "$OUT"
check "S1: the step itself is NOT settled without --advance" '"pending"' "$(step_status s1 outline)"

echo ""
echo "=== S2: record-skip-judgment --advance settles the target step ==="
at_outline s2
run_cli node "$RSJ" --session s2 --target outline --c1 true --c2 true --advance
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
at_outline s3
run_cli node "$RSJ" --session s3 --target outline --c1 true --c2 false --advance
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
at_outline s4
run_cli node "$RSJ" --session s4 --target outline --c1 true --c2 true --advance --next
check "S4: exit 0" 0 "$RC"
check_contains "S4: ADVANCED=outline" "ADVANCED=outline" "$OUT"
check "S4: exactly one ACTION line" 1 "$(action_lines)"

echo ""
echo "=== S5: a failed record emits no ACTION line and exits 2 ==="
BLOCK="$TMPDIR_BASE/blockfile"; : > "$BLOCK"
at_outline s5
RC=0
OUT="$(CLAUDE_WORKFLOW_DIR="$(nrm "$BLOCK")" run_with_timeout node "$RSJ" \
  --session s5 --target outline --c1 true --c2 true --advance --next 2>/dev/null)" || RC=$?
check "S5: unwritable state exits 2" 2 "$RC"
check "S5: no ACTION line on failure" 0 "$(action_lines)"

echo ""
echo "=== S6: set-workflow-type positional form is unchanged ==="
# wf-meta, not wf-code: readState() projects workflow_type with a "wf-code"
# DEFAULT, so asserting "wf-code" would pass on a session that was never written.
at_outline s6
run_cli node "$SWT" s6 wf-meta
check "S6: exit 0" 0 "$RC"
check "S6: stdout stays empty" "" "$OUT"
check "S6: workflow_type is recorded" '"wf-meta"' "$(top_field s6)"

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
check "S7c: the mixed form does not set workflow_type either" '"wf-code"' "$(top_field s7c)"

echo ""
echo "=== S8: set-workflow-type --advance records the step and the type together ==="
make_state s8 ""
run_cli node "$SWT" --session s8 --type wf-meta --advance --step workflow_init --status complete
check "S8: exit 0" 0 "$RC"
check_contains "S8: the advance line reports the settled step" "ADVANCED=workflow_init status=complete" "$OUT"
check_contains "S8: the type line precedes it" "WORKFLOW_TYPE=wf-meta" "$OUT"
check "S8: workflow_init is complete" '"complete"' "$(step_status s8 workflow_init)"
check "S8: workflow_type is still recorded" '"wf-meta"' "$(top_field s8)"

echo ""
echo "=== S9: record-complexity-and-skip WITHOUT --advance keeps its bare token ==="
# This script resolves its siblings through AGENTS_CONFIG_DIR, so the real repo
# is the only meaningful value for the pass-through cases. No CONFIRM_* branch is
# reachable from this path, so the repo .env cannot influence the result.
make_state s9a ""
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session s9a --verdict low --signals "" --target outline
check "S9a: exit 0" 0 "$RC"
check "S9a: stdout is exactly the bare token" "auto" "$OUT"
check "S9a: no step is settled without --advance" '"pending"' "$(step_status s9a outline)"

make_state s9b ""
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" --session s9b --verdict high --signals "S2-architecture" --target outline
check "S9b: high verdict yields the judgment token" "judgment" "$OUT"

echo ""
echo "=== S10: record-complexity-and-skip --advance normalizes child failures to exit 3 ==="
# Fixture config dir: step 1 is a no-op, the resolver forces the auto branch, and
# record-skip-judgment fails with exit 2. SKIP_MODE is therefore already known
# when the failure happens, which is the unambiguous half of the contract.
FAKE="$TMPDIR_BASE/fakecfg"
mkdir -p "$FAKE/bin/workflow" "$FAKE/hooks/workflow-state"
printf '#!/usr/bin/env node\nprocess.exit(0);\n' > "$FAKE/bin/workflow/record-complexity-evaluation"
printf 'module.exports={resolveSkipConditionsFromComplexity:()=>({so_c1:true,so_c2:true})};\n' \
  > "$FAKE/hooks/workflow-state/skip-signal-resolver.js"
printf '#!/usr/bin/env node\nprocess.stderr.write("stub: forced failure\\n");\nprocess.exit(2);\n' \
  > "$FAKE/bin/workflow/record-skip-judgment"
FAKE_N="$(nrm "$FAKE")"

make_state s10a ""
run_cli env AGENTS_CONFIG_DIR="$FAKE_N" bash "$RCAS" --session s10a --verdict low --signals "" --target outline --advance
check "S10a: the child's exit 2 is NOT propagated" 3 "$RC"
check "S10a: no ACTION line is emitted on the failure path" 0 "$(action_lines)"
check_contains "S10a: stdout still carries the resolved skip mode" "auto" "$OUT"

# Symmetric control: without --advance the current exit-2 propagation is untouched.
make_state s10b ""
run_cli env AGENTS_CONFIG_DIR="$FAKE_N" bash "$RCAS" --session s10b --verdict low --signals "" --target outline
check "S10b: without --advance the child exit code still propagates" 2 "$RC"

echo ""
echo "=== S11: class-completeness guard over bin/workflow/ ==="
# Three-way partition. A new CLI under bin/workflow/ must be classified here
# before it can land, which is what makes the advance class enumerable at all.
ADVANCE_MEMBERS="next-step record-skip-judgment record-complexity-and-skip set-workflow-type"
# record-skip-verdict is subagent-only: the skip-verifier subagent records a
# verdict about a skip someone else declared, so it never advances the workflow
# on its own behalf. That is why it is an exception and not a member.
NAMED_EXCEPTIONS="record-skip-verdict"
NON_MEMBERS="read-complexity-evaluation read-merge-base-baseline reconcile-state record-complexity-evaluation record-merge-base-baseline workflow-init-driver"

ACTUAL="$(ls "$AGENTS_DIR/bin/workflow" | grep -v '^lib$' | sort | tr '\n' ' ')"
EXPECTED="$(printf '%s %s %s' "$ADVANCE_MEMBERS" "$NAMED_EXCEPTIONS" "$NON_MEMBERS" \
  | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
check "S11a: bin/workflow/ minus lib is exactly the direct sum of the 3 registries" \
  "$EXPECTED" "$ACTUAL"

# (2) every advance member accepts the flag. next-step delegates its parsing to
# bin/workflow/lib/next-step/, so its search scope includes that directory.
for m in $ADVANCE_MEMBERS; do
  if [ "$m" = "next-step" ]; then
    scope="$AGENTS_DIR/bin/workflow/next-step $AGENTS_DIR/bin/workflow/lib"
  else
    scope="$AGENTS_DIR/bin/workflow/$m"
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
  if grep -qF -- '--advance' "$AGENTS_DIR/bin/workflow/$m"; then
    fail "S11c: $m must NOT accept --advance -- found an --advance token"
  else
    pass "S11c: $m does not accept --advance"
  fi
done

echo ""
echo "=== S12: record-complexity-and-skip --advance settles the target step ==="
# The RCAS analogue of S2. S9/S10 only cover pass-through and the forced-failure
# normalization, so without this case the whole delegation chain
# (RCAS --advance -> record-skip-judgment --advance -> recordStepVerdict) could be
# missing and every existing RCAS case would still pass.
#
# The real config dir is required: RCAS resolves its siblings through
# AGENTS_CONFIG_DIR and a stub would defeat the purpose of a happy path. The repo's
# own .env cannot decide this case either way — the CLI door's only config-file
# branch is CONFIRM_TESTS for write_tests (plan line 183), and the target here is
# outline, which the plan admits unconditionally (line 182).
make_state s12 "workflow_init clarify_intent research"
printf '# intent\n' > "$PLANS_DIR/s12-intent.md"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session s12 --verdict low --signals "" --target outline --advance
check "S12a: exit 0" 0 "$RC"
check "S12a: outline is settled as skipped" '"skipped"' "$(step_status s12 outline)"
check_contains "S12a: the advance form leads with a newline-terminated SKIP_MODE line" \
  "SKIP_MODE=auto" "$OUT"
# The delegated writer, not RCAS, owns the reason literal and the A-4 co-write.
check_contains "S12a: skip_reason carries the recorded-verdict: prefix" \
  "recorded-verdict:" "$(step_sub s12 outline skip_reason)"
check "S12a: skip_verdict.verdict is pending" '"pending"' "$(step_sub s12 outline skip_verdict.verdict)"
# The dispatch line is part of the --advance contract (plan line 307). Its VALUE is
# left unpinned: the plan does not say which token RCAS reports once it has already
# advanced the step itself, so only its presence is asserted here.
check "S12a: exactly one SKIP_DISPATCH line" 1 "$(printf '%s\n' "$OUT" | grep -c '^SKIP_DISPATCH=' || true)"

# Symmetric control: the judgment branch must NOT settle the step, so S12a cannot
# be passing because --advance settles unconditionally.
make_state s12b "workflow_init clarify_intent research"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session s12b --verdict high --signals "S2-architecture" --target outline --advance
check "S12b: the judgment branch still exits 0" 0 "$RC"
check "S12b: the judgment branch leaves outline pending" '"pending"' "$(step_status s12b outline)"
check_contains "S12b: SKIP_MODE reports judgment" "SKIP_MODE=judgment" "$OUT"

echo ""
echo "=== S13: --advance argument validation on the two remaining siblings ==="
# next-step has A12 and set-workflow-type has S7a/b/c; without these the class's
# exit-1 contract (plan line 254) is unproven for half its members.
make_state s13a "workflow_init clarify_intent research"
run_cli node "$RSJ" --session s13a --c1 true --c2 true --advance
check "S13a: record-skip-judgment --advance without --target exits 1" 1 "$RC"
check "S13a: nothing is settled" '"pending"' "$(step_status s13a outline)"
check "S13a: no ACTION line" 0 "$(action_lines)"

# --next is defined as meaningful only alongside --advance (plan line 148), so the
# lone form is an argument error rather than a silently ignored flag.
make_state s13b "workflow_init clarify_intent research"
run_cli node "$RSJ" --session s13b --target outline --c1 true --c2 true --next
check "S13b: record-skip-judgment --next without --advance exits 1" 1 "$RC"
check "S13b: the judgment is not recorded either" '"pending"' "$(step_status s13b outline)"

# RCAS keeps two distinct failure codes: 1 for a missing required argument and 2
# for an unknown flag. --target is NOT tested for absence here: it defaults to
# outline in the current CLI and the plan does not make it mandatory under
# --advance, so requiring it would be inventing a contract.
make_state s13c "workflow_init clarify_intent research"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session s13c --signals "" --target outline --advance
check "S13c: record-complexity-and-skip --advance without --verdict exits 1" 1 "$RC"
check "S13c: nothing is settled" '"pending"' "$(step_status s13c outline)"

make_state s13d "workflow_init clarify_intent research"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session s13d --verdict low --signals "" --target outline --advance --bogus
check "S13d: an unknown flag still exits 2, not the advance-path 3" 2 "$RC"

echo ""
echo "=== S14: set-workflow-type --advance write failure exits 2 with no ACTION ==="
# The exit-2 half of the class contract (A2 for next-step, S5 for
# record-skip-judgment, S10a for record-complexity-and-skip). A regular file at
# the workflow-dir path makes every write fail with ENOTDIR.
make_state s14 ""
RC=0
OUT="$(CLAUDE_WORKFLOW_DIR="$(nrm "$BLOCK")" run_with_timeout node "$SWT" \
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
# skip-verifier has since resolved.
at_outline s15a
run_cli node "$RSJ" --session s15a --target outline --c1 true --c2 true --advance
check "S15a: the first record-skip-judgment --advance exits 0" 0 "$RC"
S15A_ENTRY="$(step_entry s15a outline)"
run_cli node "$RSJ" --session s15a --target outline --c1 true --c2 true --advance
check "S15a: the repeat exits 0" 0 "$RC"
check_contains "S15a: the repeat reports already=true" "already=true" "$OUT"
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
check "S15b: workflow_type survives the repeat" '"wf-meta"' "$(top_field s15b)"

make_state s15c "workflow_init clarify_intent research"
printf '# intent\n' > "$PLANS_DIR/s15c-intent.md"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session s15c --verdict low --signals "" --target outline --advance
check "S15c: the first record-complexity-and-skip --advance exits 0" 0 "$RC"
S15C_ENTRY="$(step_entry s15c outline)"
run_cli env AGENTS_CONFIG_DIR="$AGENTS_DIR_N" bash "$RCAS" \
  --session s15c --verdict low --signals "" --target outline --advance
check "S15c: the repeat exits 0" 0 "$RC"
check "S15c: outline is still skipped after the repeat" '"skipped"' "$(step_status s15c outline)"
check "S15c: the projection is unchanged" "$S15C_ENTRY" "$(step_entry s15c outline)"
# RCAS redirects its delegate's stdout to stderr today and the plan does not say
# whether --advance changes that, so the already-marker is accepted on either stream.
check_contains "S15c: the delegated record reports already=true" "already=true" "$OUT$ERR"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
