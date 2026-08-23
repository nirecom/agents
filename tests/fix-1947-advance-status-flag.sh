#!/usr/bin/env bash
# Tests: bin/workflow/lib/next-step/advance-args.js, bin/workflow/lib/next-step/cli.js, bin/workflow/set-workflow-type, bin/workflow/lib/next-step/state-ops.js
# Tags: tl2, workflow, next-step, advance, argv, scope:issue-specific

# #1947 — the value-less settling flags (--complete / --skipped / --pending). Why
# the argv shape changed: docs/architecture/claude-code/workflow.md (a bare `complete`
# token trips the worktree-isolation command classifier). Old forms stay accepted,
# with a stderr deprecation line.

# Why TL2: acceptance/refusal plus the PERSISTED result of real argv handed to a real
# CLI. A unit parser call loses the exit-code contract and usedFlagForm interaction.

# TL3 gap (what this test does NOT catch):
# - Whether the external EnterWorktree validator admits the new argv shape (it
#   lives in the Claude Code extension host, not reproducible locally).
# - Whether a live session's settings.json permissions.allow admits it without
#   an approval dialog.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NS="$AGENTS_DIR_N/bin/workflow/next-step"
SWT="$AGENTS_DIR_N/bin/workflow/set-workflow-type"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"

# Pinned as a PAIR (#1799) so supervisor-emit never appends to the real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
# The parent session exports these; leaving them set resolves the LIVE session.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Empty fixture config dir: no CONFIRM_* leaks in from the repo .env, so the F11 gate is ARMED.
CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_nonzero() { if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1 -- expected nonzero exit, got 0"; fi; }
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
  printf '%s' "$json},\"closes_issues\":[1947]}" > "$WORKFLOW_DIR/${sid}.json"
}
# research pending and outline pending — the shape F1-F11e need.
at_research() { make_state "$1" "workflow_init clarify_intent"; }
at_outline()  { make_state "$1" "workflow_init clarify_intent research"; }

# Byte snapshot of the WHOLE state file: a refusal must half-apply nothing anywhere.
state_snapshot() { cat "$WORKFLOW_DIR/${1}.json" 2>/dev/null || echo "SNAPSHOT_FAIL"; }

# What a user CONFIRM sentinel leaves behind (mirrors seed_approval in
# tests/fix-1133-next-step-mark-outline-detail.sh:304) — needed for the APPROVED verdict.
seed_approval() {
  local sid="$1" step="$2"
  local artifact="$PLANS_DIR/${sid}-${step}.md"
  [ -f "$artifact" ] || printf 'plan\n' > "$artifact"
  run_with_timeout node -e "
    const fs = require('fs'), crypto = require('crypto');
    const [stateFile, artifact, step] = process.argv.slice(1);
    const s = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    s.plan_approvals = s.plan_approvals || {};
    s.plan_approvals[step] = {
      source: 'confirm-sentinel',
      reason: 'seeded by test fixture',
      artifact_sha256: crypto.createHash('sha256').update(fs.readFileSync(artifact)).digest('hex'),
      artifact_hash_status: 'verified',
      recorded_at: '2026-06-20T10:00:00.000Z'
    };
    fs.writeFileSync(stateFile, JSON.stringify(s, null, 2));
  " "$WORKFLOW_DIR/${sid}.json" "$artifact" "$step" </dev/null
}

OUT=""; ERR=""; RC=0
action_line_count() { printf '%s\n' "$OUT" | grep -c '^ACTION=' || true; }
run_cli() {
  local errf="$TMPDIR_BASE/cli.err"
  RC=0
  # </dev/null so a CLI can never eat the matrix table this loop is reading.
  OUT="$(run_with_timeout "$@" 2>"$errf" </dev/null)" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
probe() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="${4:-}" \
    run_with_timeout node "$PROBE" "$3" 2>/dev/null </dev/null || echo "PROBE_FAIL"
}
step_status() { probe "$1" "$2" field status; }
step_sub()    { probe "$1" "$2" sub "$3"; }
step_entry()  { probe "$1" "$2" entry; }
# Raw stream: a duplicate append is invisible in the folded projection.
step_events() { probe "$1" "$2" eventcount step_status; }

# --- table-driven matrix -----------------------------------------------------
# Both CLIs share one argv vocabulary (advance-args.js), so the acceptance boundary
# is a class property, best stated as a table. Bespoke blocks below carry only the
# cases needing extra probes (--next, approvals, event streams).
MATRIX_N=0
# Columns: name|cli|seed|argv|rc|stdout|stderr|state
#   cli    ns=next-step, swt=set-workflow-type (--session/--type prefilled)
#   seed   research | outline | wi_done (workflow_init complete) | empty
#   rc     0 | nz
#   stdout/stderr substring; "!"=must NOT contain; empty=unchecked; EMPTY=exactly empty
#   state  <step>:<status> | SNAP (whole state file byte-identical) | empty
matrix_text() {
  case "$2" in
    "")    return ;;
    EMPTY) check "$1 is exactly empty" "" "$3" ;;
    '!'*)  check_not_contains "$1 excludes [${2#!}]" "${2#!}" "$3" ;;
    *)     check_contains "$1 carries [$2]" "$2" "$3" ;;
  esac
}
run_matrix() {
  local tag="$1" name cli seed argv rc wout werr wstate sid before
  while IFS='|' read -r name cli seed argv rc wout werr wstate; do
    case "$name" in ''|'#'*) continue ;; esac
    MATRIX_N=$((MATRIX_N + 1)); sid="m$MATRIX_N"
    case "$seed" in
      research) at_research "$sid" ;;
      outline)  at_outline "$sid" ;;
      wi_done)  make_state "$sid" "workflow_init" ;;
      *)        make_state "$sid" "" ;;
    esac
    before="$(state_snapshot "$sid")"
    [ "$seed" = "wi_done" ] && check "$tag/$name: -pre workflow_init starts complete"       '"complete"' "$(step_status "$sid" workflow_init)"
    if [ "$cli" = "swt" ]; then
      run_cli node "$SWT" --session "$sid" --type wf-code $argv
    else
      run_cli node "$NS" --session "$sid" $argv
    fi
    case "$rc" in
      0)  check "$tag/$name: exit 0" 0 "$RC" ;;
      nz) check_nonzero "$tag/$name: nonzero exit" "$RC" ;;
      *)  fail "$tag/$name: unknown rc column [$rc]" ;;
    esac
    matrix_text "$tag/$name: stdout" "$wout" "$OUT"
    matrix_text "$tag/$name: stderr" "$werr" "$ERR"
    case "$wstate" in
      "")   ;;
      SNAP) check "$tag/$name: the state file is byte-identical (nothing half-applied)" \
              "$before" "$(state_snapshot "$sid")" ;;
      *)    check "$tag/$name: ${wstate%%:*} is ${wstate##*:}" \
              "\"${wstate##*:}\"" "$(step_status "$sid" "${wstate%%:*}")" ;;
    esac
  done
}

echo "=== F1: --advance --step research --complete ==="
at_research f1
run_cli node "$NS" --session f1 --advance --step research --complete
check "F1: --complete exits 0" 0 "$RC"
check "F1: stdout carries the advance line" "ADVANCED=research status=complete" "$OUT"
# The flag maps onto the UNCHANGED persisted string — #1947 does not rename VALID_STATUSES.
check "F1: research is persisted as complete" '"complete"' "$(step_status f1 research)"
F1_OUT="$OUT"

echo ""
echo "=== F1b: --complete composes with --next (settle + read in one call) ==="
# `research` is the CURRENT step here, which is what makes --next emit an ACTION
# block at all — on a non-current step the ACTION asserts would be vacuously absent.
at_research f1b
run_cli node "$NS" --session f1b --advance --step research --complete --next
check "F1b: --complete --next exits 0" 0 "$RC"
check_contains "F1b: the advance line is still emitted" "ADVANCED=research status=complete" "$OUT"
check "F1b: exactly one ACTION line accompanies it" 1 "$(action_line_count)"
check_contains "F1b: the ACTION block reports current-step scope" "ADVANCE_SCOPE=current-step" "$OUT"
check_contains "F1b: the ACTION block names the next skill" "NEXT_SKILL=" "$OUT"
check_contains "F1b: the ACTION block carries the recovery hint" "NEXT_HINT=" "$OUT"
check "F1b: the persisted state matches the reported one" '"complete"' "$(step_status f1b research)"

echo ""
echo "=== F1s: --skipped --skip-reason --next gets the SAME depth as --complete ==="
# CPR-ORTH: --next composition belongs to the settling CLASS, not to `complete`.
# Full-depth for one member only would let a --skipped-specific regression
# (suppressed ACTION, wrong scope, a lost reason) ship green.
at_research f1s
run_cli node "$NS" --session f1s --advance --step research --skipped \
  --skip-reason upstream-survey --next
check "F1s: --skipped --skip-reason --next exits 0" 0 "$RC"
check_contains "F1s: the advance line reports skipped" "ADVANCED=research status=skipped" "$OUT"
check "F1s: exactly one ACTION line accompanies it" 1 "$(action_line_count)"
check_contains "F1s: the ACTION block reports current-step scope" "ADVANCE_SCOPE=current-step" "$OUT"
check_contains "F1s: the ACTION block names the next skill" "NEXT_SKILL=" "$OUT"
check_contains "F1s: the ACTION block carries the recovery hint" "NEXT_HINT=" "$OUT"
check "F1s: research is persisted as skipped" '"skipped"' "$(step_status f1s research)"
check "F1s: the reason survives the --next composition verbatim" '"upstream-survey"' "$(step_sub f1s research skip_reason)"
# A SKIPPED research must yield the same next skill a COMPLETED one does.
F1S_SKILL="$(printf '%s\n' "$OUT" | grep '^NEXT_SKILL=' || true)"
at_research f1s2
run_cli node "$NS" --session f1s2 --advance --step research --complete --next
check "F1s: skipped and complete hand back the same NEXT_SKILL" "$(printf '%s\n' "$OUT" | grep '^NEXT_SKILL=' || true)" "$F1S_SKILL"

echo ""
echo "=== F1c: repeating a canonical settle is idempotent, for EVERY status ==="
# Mirrors A5 in feature-1644-advance-transaction/basic.sh (legacy spelling). Both
# views are asserted: the folded projection AND the raw event count.
at_research f1c
run_cli node "$NS" --session f1c --advance --step research --complete
F1C_FIRST="$(step_entry f1c research)"; F1C_EV="$(step_events f1c research)"
run_cli node "$NS" --session f1c --advance --step research --complete
check "F1c: the second --complete exits 0" 0 "$RC"
check_contains "F1c: the repeat reports already=true" "already=true" "$OUT"
check "F1c: the repeat leaves the projected entry unchanged" "$F1C_FIRST" "$(step_entry f1c research)"
check "F1c: the repeat appends no step_status event" "$F1C_EV" "$(step_events f1c research)"

at_research f1c2
run_cli node "$NS" --session f1c2 --advance --step research --skipped --skip-reason upstream
F1C2_FIRST="$(step_entry f1c2 research)"; F1C2_EV="$(step_events f1c2 research)"
run_cli node "$NS" --session f1c2 --advance --step research --skipped --skip-reason upstream
check "F1c: the second --skipped exits 0" 0 "$RC"
check_contains "F1c: the repeated --skipped reports already=true" "already=true" "$OUT"
check "F1c: the repeated --skipped leaves the projected entry unchanged" "$F1C2_FIRST" "$(step_entry f1c2 research)"
check "F1c: the repeated --skipped appends no step_status event" "$F1C2_EV" "$(step_events f1c2 research)"

# --pending routes through the reset gate (GATE_FOR_STATUS in advance-shared.js),
# which keeps its pre-#1644 always-rewrite behaviour on purpose (see the "gates
# deliberately keep their pre-#1644 re-write behaviour" note in
# record-step-verdict.js) — unlike --complete/--skipped it is NOT idempotent.
at_research f1c3
run_cli node "$NS" --session f1c3 --advance --step research --complete
run_cli node "$NS" --session f1c3 --advance --step research --pending
check "F1c: --pending after --complete exits 0" 0 "$RC"
run_cli node "$NS" --session f1c3 --advance --step research --pending
check "F1c: the second --pending exits 0" 0 "$RC"
check_not_contains "F1c: the repeated --pending does not claim already=true (reset gate always rewrites)" "already=true" "$OUT"
check "F1c: the repeated --pending still projects as pending" '"pending"' "$(step_status f1c3 research)"

echo ""
echo "=== F2: --skipped, with and without --skip-reason ==="
at_research f2a
run_cli node "$NS" --session f2a --advance --step research --skipped \
  --skip-reason "covered by the parent session survey"
check "F2a: --skipped with a reason exits 0" 0 "$RC"
check "F2a: stdout carries the advance line" "ADVANCED=research status=skipped" "$OUT"
check "F2a: research is persisted as skipped" '"skipped"' "$(step_status f2a research)"
# EXACT, not substring: a truncating reason path still carries the opening words.
check "F2a: the reason reaches the state verbatim and whole" '"covered by the parent session survey"' "$(step_sub f2a research skip_reason)"
at_research f2b
F2B_BEFORE="$(state_snapshot f2b)"
run_cli node "$NS" --session f2b --advance --step research --skipped
check_nonzero "F2b: --skipped without --skip-reason is refused" "$RC"
check "F2b: the refused skip half-applies nothing" "$F2B_BEFORE" "$(state_snapshot f2b)"

# F2c characterises an EMPTY reason: cli.js treats "" as absent, so both spellings
# must refuse — the flag form must not become the reasonless-skip loophole.
at_research f2c1
run_cli node "$NS" --session f2c1 --advance --step research --status skipped --skip-reason ""
check_nonzero "F2c: the legacy form refuses an empty --skip-reason (characterisation)" "$RC"
check "F2c: the legacy empty-reason refusal leaves research pending" '"pending"' "$(step_status f2c1 research)"
at_research f2c2
F2C2_BEFORE="$(state_snapshot f2c2)"
run_cli node "$NS" --session f2c2 --advance --step research --skipped --skip-reason ""
check_nonzero "F2c: --skipped with an empty --skip-reason is refused too" "$RC"
check_contains "F2c: the refusal still names the skip-reason requirement" "requires --skip-reason" "$ERR"
check "F2c: the refused empty-reason skip half-applies nothing" "$F2C2_BEFORE" "$(state_snapshot f2c2)"

echo ""
echo "=== F3/F4/F5: canonical and legacy observe identically; legacy warns ==="
at_outline f3a
at_outline f3b
run_cli node "$NS" --session f3a --advance --step research --pending
check "F3: --pending exits 0" 0 "$RC"
check "F3: stdout carries the advance line" "ADVANCED=research status=pending" "$OUT"
F3_NEW="$OUT"
run_cli node "$NS" --session f3b --advance --step research --status pending
check "F3: the legacy form produces byte-identical stdout" "$F3_NEW" "$OUT"
check "F3: --pending persists pending" '"pending"' "$(step_status f3a research)"

at_research f4
run_cli node "$NS" --session f4 --advance --step research --status complete
check "F4: legacy --status complete exits 0" 0 "$RC"
check "F4: legacy stdout is byte-identical to the new form" "$F1_OUT" "$OUT"
check "F4: legacy form persists complete" '"complete"' "$(step_status f4 research)"
check_contains "F5: the legacy form emits a deprecation line on stderr" "deprecated" "$ERR"
# stdout is the machine contract (parse-next-step-output.js) — no leakage.
check_not_contains "F5: the deprecation notice never reaches stdout" "deprecated" "$OUT"

echo ""
echo "=== M1: double supply, repeated flags and argument order (next-step) ==="
# The guard has to be order-blind: a rule spelled "reject a --status that FOLLOWS
# a flag" passes every canonical-first row and lets the reverse through, so both
# directions are here. Refusal rows assert SNAP — a fail-closed parse must abort
# before ANY write, not merely leave the targeted step alone.
run_matrix M1 <<'MATRIX'
canonical + legacy same status|ns|research|--advance --step research --complete --status complete|nz||more than once|SNAP
canonical + legacy other status|ns|research|--advance --step research --complete --skipped --skip-reason x|nz||more than once|SNAP
legacy + canonical reverse order|ns|research|--advance --step research --status complete --complete|nz||more than once|SNAP
canonical + legacy skipped|ns|research|--advance --step research --skipped --status skipped --skip-reason x|nz|||SNAP
legacy + canonical skipped reverse order|ns|research|--advance --step research --status skipped --skipped --skip-reason x|nz|||SNAP
repeated --complete|ns|research|--advance --step research --complete --complete|nz|||SNAP
repeated --skipped|ns|research|--advance --step research --skipped --skipped --skip-reason x|nz|||SNAP
repeated --pending|ns|research|--advance --step research --pending --pending|nz|||SNAP
--complete before --step|ns|research|--advance --complete --step research|0|ADVANCED=research status=complete|EMPTY|research:complete
--complete before --advance|ns|research|--complete --advance --step research|0|ADVANCED=research status=complete|EMPTY|research:complete
--skip-reason before --skipped|ns|research|--advance --step research --skip-reason upstream --skipped|0|ADVANCED=research status=skipped|EMPTY|research:skipped
legacy --status skipped still warns|ns|research|--advance --step research --status skipped --skip-reason upstream|0|ADVANCED=research status=skipped|deprecated|research:skipped
legacy --status pending still warns|ns|research|--advance --step research --status pending|0|ADVANCED=research status=pending|deprecated|research:pending
legacy --status skipped keeps stdout clean|ns|research|--advance --step research --status skipped --skip-reason upstream|0|!deprecated||research:skipped
legacy --status in_progress is still refused|ns|research|--advance --step research --status in_progress|nz|||SNAP
legacy x legacy keeps last-wins exit 0|ns|research|--advance --step research --status pending --status complete|0|ADVANCED=research status=complete||research:complete
MATRIX

echo ""
echo "=== M2: the diagnostics — a status flag out of place names itself ==="
# "only meaningful with --advance" and "--mark means complete" are CLASS rules:
# via --complete alone the siblings could fall through to the unknown-option
# branch (different exit path, unhelpful message). Each refusal must also hand
# back the form that WOULD work, or the model is stranded mid-recovery.
run_matrix M2 <<'MATRIX'
bare --complete|ns|research|--complete|nz||--complete|SNAP
bare --skipped|ns|research|--skipped --skip-reason x|nz||--skipped|SNAP
bare --pending|ns|research|--pending|nz||--pending|SNAP
--mark with --skipped|ns|research|--mark research --skipped|nz||--advance --step research --skipped|SNAP
--mark with --pending|ns|research|--mark research --pending|nz||--advance --step research --pending|SNAP
--mark with a bogus trailing token|ns|research|--mark research bogus|nz||--mark status must be 'complete'|SNAP
--mark with --complete is redundant but accepted|ns|research|--mark research --complete|0|MARK=research status=complete|EMPTY|research:complete
--complete before --mark reverse order|ns|research|--complete --mark research|0|MARK=research status=complete|EMPTY|research:complete
MATRIX

echo ""
echo "=== F8/F9: --mark with and without the legacy trailing token ==="
at_research f8
run_cli node "$NS" --session f8 --mark research
check "F8: --mark research exits 0" 0 "$RC"
check "F8: stdout carries the mark line" "MARK=research status=complete" "$OUT"
check "F8: research is complete" '"complete"' "$(step_status f8 research)"
F8_OUT="$OUT"
run_cli node "$NS" --session f8 --mark research
check "F8: re-running the same --mark is idempotent (exit 0)" 0 "$RC"
check "F8: the repeat prints the same line" "$F8_OUT" "$OUT"
check "F8: the repeat leaves research complete" '"complete"' "$(step_status f8 research)"
at_research f7b
run_cli node "$NS" --session f7b --mark research --complete
check "F8: --mark --complete prints the SAME stdout as the bare --mark" "$F8_OUT" "$OUT"
at_research f9
run_cli node "$NS" --session f9 --mark research complete
check "F9: --mark research complete exits 0" 0 "$RC"
check "F9: legacy stdout is byte-identical to the new form" "$F8_OUT" "$OUT"
check_contains "F9: the legacy trailing token warns on stderr" "deprecated" "$ERR"

echo ""
echo "=== F11: the approval gate survives the new argv shape (both verdicts) ==="
# PRECONDITION (load-bearing): completion-approval.js skips the invariant when
# `before === "complete"`, so an already-complete outline makes every case here
# vacuously green. The -pre asserts pin outline=pending.
at_outline f11
check "F11-pre: outline is pending before --mark" '"pending"' "$(step_status f11 outline)"
F11_BEFORE="$(state_snapshot f11)"
run_cli node "$NS" --session f11 --mark outline
check_nonzero "F11: --mark outline without an approval fails closed" "$RC"
check "F11: the refusal half-applies nothing" "$F11_BEFORE" "$(state_snapshot f11)"
# The refusal is itself a string the model re-types: it must teach the NEW form.
check_contains "F11: the refusal echoes the canonical --mark form" "next-step: --mark outline refused" "$ERR"
check_not_contains "F11: the refusal no longer echoes the bare complete token" "--mark outline complete refused" "$ERR"

at_outline f11b
check "F11b-pre: outline is pending before --mark --complete" '"pending"' "$(step_status f11b outline)"
F11B_BEFORE="$(state_snapshot f11b)"
run_cli node "$NS" --session f11b --mark outline --complete
check_nonzero "F11b: --mark outline --complete without an approval fails closed" "$RC"
check "F11b: the new --complete route is no back door — nothing is written" "$F11B_BEFORE" "$(state_snapshot f11b)"

# F11c-F11e: the other verdict of the same gate. Refusals alone would also pass
# if the new forms could NEVER satisfy the gate (over-blocking reads as "secure"
# to a refusal-only suite), so each accepted spelling is driven to success too.
at_outline f11c
check "F11c-pre: outline is pending before the approved --mark" '"pending"' "$(step_status f11c outline)"
seed_approval f11c outline
run_cli node "$NS" --session f11c --mark outline
check "F11c: --mark outline WITH a recorded approval exits 0" 0 "$RC"
check "F11c: stdout carries the ordinary mark line" "MARK=outline status=complete" "$OUT"
check "F11c: the approved outline becomes complete" '"complete"' "$(step_status f11c outline)"
F11C_OUT="$OUT"
# Control for F11c: the SAME seed through the legacy spelling, which works today.
# Without it a silently-failing seed_approval reads as an argv-shape bug forever.
at_outline f11d
seed_approval f11d outline
run_cli node "$NS" --session f11d --mark outline complete
check "F11d: the legacy form with the same seeded approval exits 0 (seed control)" 0 "$RC"
check "F11d: the legacy approved path completes outline" '"complete"' "$(step_status f11d outline)"
# F11e: the redundant spelling on the APPROVED path. F11b proves it cannot pass
# the gate; without F11e a `--mark <step> --complete` that ALWAYS refused passes.
at_outline f11e
check "F11e-pre: outline is pending before the approved --mark --complete" '"pending"' "$(step_status f11e outline)"
seed_approval f11e outline
run_cli node "$NS" --session f11e --mark outline --complete
check "F11e: --mark outline --complete WITH a recorded approval exits 0" 0 "$RC"
check "F11e: its stdout is byte-identical to the bare approved --mark" "$F11C_OUT" "$OUT"
check "F11e: the approved outline becomes complete" '"complete"' "$(step_status f11e outline)"
check "F11e: the redundant flag raises no stderr noise" "" "$ERR"

echo ""
echo "=== F12: set-workflow-type shares the vocabulary ==="
make_state f12 ""
run_cli node "$SWT" --session f12 --type wf-code --advance --step workflow_init --complete
check "F12: set-workflow-type --complete exits 0" 0 "$RC"
check_contains "F12: the workflow type prefix is emitted" "WORKFLOW_TYPE=wf-code" "$OUT"
check_contains "F12: the advance line is emitted" "ADVANCED=workflow_init status=complete" "$OUT"
check "F12: workflow_init is complete" '"complete"' "$(step_status f12 workflow_init)"

echo ""
echo "=== M3: set-workflow-type parity — the same table, the sibling CLI ==="
# CPR-ORTH: this CLI derives its vocabulary from the same ADVANCE_STATUSES, so
# every M1 row must hold here too. A hand-written --complete-only branch passes
# F12 and drops the rest; a private copy of the deprecation logic surfaces as a
# canonical row whose stderr is not EMPTY.
# This CLI has no --skip-reason, so a skip can only ever be refused downstream —
# the skipped rows pin that the flag still reached the verdict layer as a status.
run_matrix M3 <<'MATRIX'
canonical --complete is silent on stderr|swt|empty|--advance --step workflow_init --complete|0|ADVANCED=workflow_init status=complete|EMPTY|workflow_init:complete
canonical --skipped reaches the verdict layer|swt|empty|--advance --step research --skipped|nz||reason too short|research:pending
canonical --pending is silent on stderr|swt|wi_done|--advance --step workflow_init --pending|0|ADVANCED=workflow_init status=pending|EMPTY|workflow_init:pending
canonical --complete keeps the type prefix|swt|empty|--advance --step workflow_init --complete|0|WORKFLOW_TYPE=wf-code||workflow_init:complete
legacy --status complete warns|swt|empty|--advance --step workflow_init --status complete|0|ADVANCED=workflow_init status=complete|deprecated|workflow_init:complete
legacy --status skipped still warns|swt|empty|--advance --step research --status skipped|nz||deprecated|research:pending
legacy --status pending warns|swt|wi_done|--advance --step workflow_init --status pending|0|ADVANCED=workflow_init status=pending|deprecated|workflow_init:pending
legacy warning stays out of stdout|swt|empty|--advance --step workflow_init --status complete|0|!deprecated||workflow_init:complete
canonical + legacy is refused|swt|empty|--advance --step workflow_init --complete --status complete|nz|||SNAP
legacy + canonical reverse order is refused|swt|empty|--advance --step workflow_init --status complete --complete|nz|||SNAP
repeated --complete is refused|swt|empty|--advance --step workflow_init --complete --complete|nz|||SNAP
repeated --skipped is refused|swt|empty|--advance --step research --skipped --skipped|nz|||SNAP
repeated --pending is refused|swt|wi_done|--advance --step workflow_init --pending --pending|nz|||SNAP
legacy x legacy keeps last-wins exit 0|swt|empty|--advance --step workflow_init --status pending --status complete|0|ADVANCED=workflow_init status=complete||workflow_init:complete
--complete before --step|swt|empty|--advance --complete --step workflow_init|0|ADVANCED=workflow_init status=complete|EMPTY|workflow_init:complete
a status flag without --advance is refused|swt|empty|--complete|nz||--complete|SNAP
MATRIX

echo ""
echo "=== F13: usedFlagForm recognises the new flag (positional mix) ==="
make_state f13 ""
F13_BEFORE="$(state_snapshot f13)"
run_cli node "$SWT" f13 wf-code --advance --step workflow_init --complete
check_nonzero "F13: mixing the positional form with --complete is refused" "$RC"
check_contains "F13: usedFlagForm recognises the new flag" "do not mix" "$ERR"
# The risk is `workflow_type` written before the advance validates — invisible to a step probe.
check "F13: the refused mix leaves the state file byte-identical" "$F13_BEFORE" "$(state_snapshot f13)"

echo ""
echo "=== F14: --help presents canonical as primary, legacy as deprecated ==="
# Mere presence of the four strings is satisfied by a help text that lists
# --complete UNDER a "Deprecated" heading — the exact inversion of the migration
# this PR asks readers to make. So the marker is pinned PER LINE: the canonical
# offer line must carry none, and each legacy form must appear ON a line that
# does. Needle `eprecat` matches Deprecated and deprecated without -i.
run_cli node "$NS" --help
check "F14: --help exits 0" 0 "$RC"
for t in --complete --skipped --pending; do
  check_contains "F14: usage teaches [$t]" "$t" "$OUT"
done
F14_CANON="$(printf '%s\n' "$OUT" | grep -F -- '--complete | --skipped | --pending' || true)"
if [ -n "$F14_CANON" ]; then pass "F14: the canonical flags are offered together as the required choice"
else fail "F14: no usage line offers [--complete | --skipped | --pending] as the canonical choice"; fi
[ -n "$F14_CANON" ] && check_not_contains "F14: the canonical offer carries no deprecation marker" "eprecat" "$F14_CANON"
F14_DEPR="$(printf '%s\n' "$OUT" | grep -F -- 'eprecat' || true)"
if [ -n "$F14_DEPR" ]; then pass "F14: the usage carries a deprecation notice"
else fail "F14: the usage carries no deprecation notice at all"; fi
for legacy in "--status <status>" "--mark <step> complete"; do
  if printf '%s\n' "$F14_DEPR" | grep -qF -- "$legacy"; then
    pass "F14: a deprecation line marks the legacy [$legacy] form"
  else fail "F14: no deprecation line marks the legacy [$legacy] form"; fi
done

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
