#!/usr/bin/env bash
# tests/bin/feat-2490-next-step-gate/gate-mode.sh
# Tests: bin/workflow/lib/next-step/gate-mode.js, bin/workflow/lib/next-step/cli.js, bin/workflow/next-step, bin/detect-scope-change.sh
# Tags: tl2, workflow, confirm-gate, next-step, gate-mode, scope:issue-specific, pwsh-not-required
# #2490 (b): next-step --gate turns the recorded step + gate value (+ detail scope change) into one GATE_ACTION.

# TL3 gap (what this test does NOT catch): whether a live model follows GATE_ACTION
# inside the seven skills instead of re-deriving ON/OFF itself. Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh
# category: skill-orchestration.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2490-next-step-gate/common.sh"

ALL_GATE=""; NCALL=0
gate() {
  RC=0; OUT="$(run_next_step --gate "$@" 2>/dev/null)" || RC=$?
  ALL_GATE="$ALL_GATE"$'\n'"$OUT"; NCALL=$((NCALL + 1))
}
hint() { unq "$(val GATE_HINT)"; }
reason() { unq "$(val REASON)"; }
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# Detail fixtures: approach changed (gm-sc), unchanged (gm-same), detail.md absent (gm-nodet).
CHANGE_LINE="approach changed between outline and detail"
for s in gm-sc gm-same gm-nodet; do
  write_state "$s" "$(json_at detail)"
  put_plan "$s" intent "$INTENT_FULL"
  put_plan "$s" outline "$(printf '## Adopted approach: A\nKeep the helper.')"
done
put_plan gm-sc detail "$(printf "## Adopted approach: B, don't reuse A\nReplace the helper.")"
put_plan gm-same detail "$(printf '## Adopted approach: A\nKeep the helper.')"
# Stub detectors: one prints a line carrying an apostrophe (exit 0), one fails (exit 2).
CFG_APOS="$GT_BASE/cfg-apos"; mk_tree "$CFG_APOS"
printf "#!/usr/bin/env bash\necho \"approach changed: don't reuse A\"\nexit 0\n" > "$CFG_APOS/bin/detect-scope-change.sh"
CFG_S2="$GT_BASE/cfg-s2"; mk_tree "$CFG_S2"
printf '#!/usr/bin/env bash\nexit 2\n' > "$CFG_S2/bin/detect-scope-change.sh"
CFG_E4="$GT_BASE/cfg-e4"; mk_tree "$CFG_E4"; printf '#!/usr/bin/env bash\nexit 4\n' > "$CFG_E4/bin/get-config-var"

case_begin "relocated-detector-exists" "bin/detect-scope-change.sh"
check "bin/detect-scope-change.sh exists" "yes" "$([ -f "$SCRIPT_CHECKOUT_ROOT/bin/detect-scope-change.sh" ] && echo yes || echo no)"
check "the skill-local copy is gone" "no" "$([ -f "$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/scripts/detect-scope-change.sh" ] && echo yes || echo no)"
case_end

echo "=== detail scope change ==="
case_begin "detail-off-scope-change-present-and-stop" "bin/workflow/lib/next-step/gate-mode.js"
export CONFIRM_DETAIL=off
gate --session gm-sc
check "exit 0" 0 "$RC"
check "GATE_ACTION=present-and-stop" "present-and-stop" "$(val GATE_ACTION)"
check "value line GATE_CONFIRM_DETAIL=OFF" "OFF" "$(val GATE_CONFIRM_DETAIL)"
check "HINT carries the change line" yes "$(has "$CHANGE_LINE" "$(hint)")"
check "HINT names --scope-change-approved" yes "$(has "--scope-change-approved" "$(hint)")"
case_end

case_begin "scope-change-approved-resume-stateless" "bin/workflow/lib/next-step/gate-mode.js"
gate --session gm-sc --scope-change-approved
check "approved: GATE_ACTION=proceed" "proceed" "$(val GATE_ACTION)"
check "approved: REASON=scope-change-approved" "scope-change-approved" "$(reason)"
gate --session gm-sc
check "plain rerun: present-and-stop again (flag leaves no state)" "present-and-stop" "$(val GATE_ACTION)"
case_end

case_begin "detail-on-change-ask" "bin/workflow/lib/next-step/gate-mode.js"
export CONFIRM_DETAIL=on
gate --session gm-sc
check "ON + change: ask" "ask" "$(val GATE_ACTION)"
check "ON + change: HINT carries the change line" yes "$(has "$CHANGE_LINE" "$(hint)")"
gate --session gm-sc --scope-change-approved
check "ON + change + flag: still ask" "ask" "$(val GATE_ACTION)"
gate --session gm-same
check "ON, no change: ask" "ask" "$(val GATE_ACTION)"
OUT="$(run_next_step_in "$CFG_E4" --gate --session gm-same 2>/dev/null || true)"
ALL_GATE="$ALL_GATE"$'\n'"$OUT"; NCALL=$((NCALL + 1))
check "ERROR: ask" "ask" "$(val GATE_ACTION)"
check "ERROR: value line" "ERROR" "$(val GATE_CONFIRM_DETAIL)"
case_end

case_begin "detail-off-no-change-proceed" "bin/workflow/lib/next-step/gate-mode.js"
export CONFIRM_DETAIL=off
gate --session gm-same
check "OFF, no change: proceed" "proceed" "$(val GATE_ACTION)"
gate --session gm-nodet
check "OFF, detail.md absent: proceed" "proceed" "$(val GATE_ACTION)"
check "detail.md absent is not a check failure" no "$(has scope-change-check-failed "$(reason)")"
OUT="$(run_next_step_in "$CFG_S2" --gate --session gm-sc 2>/dev/null || true)"
ALL_GATE="$ALL_GATE"$'\n'"$OUT"; NCALL=$((NCALL + 1))
check "detector status 2: proceed" "proceed" "$(val GATE_ACTION)"
check "detector status 2: REASON flags the failure" yes "$(has scope-change-check-failed "$(reason)")"
case_end

case_begin "apostrophe-stripped-from-change-line" "bin/workflow/lib/next-step/gate-mode.js"
OUT="$(run_next_step_in "$CFG_APOS" --gate --session gm-sc 2>/dev/null || true)"
ALL_GATE="$ALL_GATE"$'\n'"$OUT"; NCALL=$((NCALL + 1))
check "apostrophe line: present-and-stop" "present-and-stop" "$(val GATE_ACTION)"
check "apostrophe line: embedded with the quote removed" yes "$(has "approach changed: dont reuse A" "$(hint)")"
case_end

echo "=== step comes from the recorded state ==="
case_begin "gate-from-recorded-step" "bin/workflow/lib/next-step/gate-mode.js"
write_state gm-ci "$(json_at clarify_intent)"; put_plan gm-ci intent "$INTENT_FULL"
gate --session gm-ci
check "recorded clarify_intent + intent.md: CONFIRM_INTENT" "ON" "$(val GATE_CONFIRM_INTENT)"
printf 'CONFIRM_OUTLINE=off\n' > "$CFG/.env"; export CONFIRM_OUTLINE=off
write_state gm-ol "$(json_at outline)"; put_plan gm-ol intent "$INTENT_FULL"; put_plan gm-ol outline "## Adopted approach: A"
gate --session gm-ol
check "recorded outline (snapshot would advance): CONFIRM_OUTLINE" "OFF" "$(val GATE_CONFIRM_OUTLINE)"
check "recorded outline: proceed" "proceed" "$(val GATE_ACTION)"
: > "$CFG/.env"; export CONFIRM_OUTLINE=on
gate --session gm-same
check "recorded detail: CONFIRM_DETAIL" "OFF" "$(val GATE_CONFIRM_DETAIL)"
case_end

echo "=== none ==="
case_begin "none-without-a-gate" "bin/workflow/lib/next-step/gate-mode.js"
for step in research review_tests; do
  write_state "gm-ng-$step" "$(json_at "$step")"
  for flag in "" "--scope-change-approved"; do
    gate --session "gm-ng-$step" $flag
    check "$step $flag: GATE_ACTION=none" "none" "$(val GATE_ACTION)"
    check "$step $flag: REASON" "no-confirm-gate-for-step:$step" "$(reason)"
    check "$step $flag: no value line" 0 "$(count_re "$OUT" '^GATE_CONFIRM_')"
  done
done
for flag in "" "--scope-change-approved"; do
  gate $flag
  check "no session $flag: GATE_ACTION=none" "none" "$(val GATE_ACTION)"
  check "no session $flag: REASON" "session-unresolved" "$(reason)"
  check "no session $flag: no value line" 0 "$(count_re "$OUT" '^GATE_CONFIRM_')"
done
case_end

echo "=== seven gates, OFF -> proceed, ON -> ask ==="
case_begin "seven-gate-table" "bin/workflow/lib/next-step/gate-mode.js"
for step in $GATE_STEPS; do
  key="$(gate_key_of "$step")"; sid="gm-t-$step"
  [ "$step" = "detail" ] && sid="gm-same"
  [ "$step" = "detail" ] || write_state "$sid" "$(json_at "$step")"
  for row in off:proceed on:ask; do
    export "$key=${row%%:*}"
    gate --session "$sid"
    check "$step ${row%%:*}: ${row#*:}" "${row#*:}" "$(val GATE_ACTION)"
  done
  export "$key=on"
done
export CONFIRM_TESTS=off
gate --session gm-t-write_tests --scope-change-approved
check "write_tests OFF + flag: proceed" "proceed" "$(val GATE_ACTION)"
check "write_tests OFF + flag: REASON says ignored" yes "$(has scope-change-approved-ignored "$(reason)")"
export CONFIRM_TESTS=on
case_end

echo "=== CLI contract ==="
case_begin "cli-usage-errors" "bin/workflow/lib/next-step/cli.js"
for args in "--session gm-sc --scope-change-approved" "--gate --list --session gm-sc" \
  "--gate --reset write_tests --session gm-sc" "--gate --mark write_tests --session gm-sc" \
  "--gate --advance --step detail --complete --session gm-sc"; do
  RC=0; run_next_step $args >/dev/null 2>&1 || RC=$?
  check "exit 64 for: $args" 64 "$RC"
done
case_end

case_begin "read-only-state" "bin/workflow/next-step"
for s in gm-sc gm-t-write_tests; do
  cp "$GT_BASE/workflow-state/$s.json" "$GT_BASE/before.json"
  for flag in "" "--scope-change-approved"; do
    gate --session "$s" $flag
    check "$s $flag: exit 0" 0 "$RC"
    check "$s $flag: state bytes unchanged" yes "$(cmp -s "$GT_BASE/before.json" "$GT_BASE/workflow-state/$s.json" && echo yes || echo no)"
  done
done
case_end

echo "=== .env freshness: each --gate call re-reads .env ==="
case_begin "dotenv-switch-flips-gate-action" "bin/workflow/lib/next-step/gate-mode.js"
write_state gm-env "$(json_at write_tests)"
unset CONFIRM_TESTS
printf 'CONFIRM_TESTS=off\n' > "$CFG/.env"
gate --session gm-env
check ".env off, env unset: proceed" "proceed" "$(val GATE_ACTION)"
check ".env off, env unset: value line OFF" "OFF" "$(val GATE_CONFIRM_TESTS)"
printf 'CONFIRM_TESTS=on\n' > "$CFG/.env"
gate --session gm-env
check ".env switched on, env unset: ask" "ask" "$(val GATE_ACTION)"
check ".env switched on, env unset: value line ON" "ON" "$(val GATE_CONFIRM_TESTS)"
: > "$CFG/.env"; export CONFIRM_TESTS=on
case_end

echo "=== detector failure warning reaches GATE_HINT ==="
case_begin "detector-failure-warns-in-hint" "bin/workflow/lib/next-step/gate-mode.js"
for row in off:proceed on:ask; do
  export CONFIRM_DETAIL="${row%%:*}"
  OUT="$(run_next_step_in "$CFG_S2" --gate --session gm-same 2>/dev/null || true)"
  ALL_GATE="$ALL_GATE"$'\n'"$OUT"; NCALL=$((NCALL + 1))
  check "detector exit 2, ${row%%:*}: ${row#*:}" "${row#*:}" "$(val GATE_ACTION)"
  check "detector exit 2, ${row%%:*}: HINT says the check failed" yes "$(has "scope-change check failed" "$(hint)")"
  check "detector exit 2, ${row%%:*}: HINT says it could not run" yes "$(has "could not run" "$(hint)")"
  check "detector exit 2, ${row%%:*}: REASON scope-change-check-failed" yes "$(has scope-change-check-failed "$(reason)")"
  gate --session gm-same
  check "working detector, ${row%%:*}: HINT carries no failure warning" no "$(has "check failed" "$(hint)")"
done
export CONFIRM_DETAIL=on
case_end

case_begin "closed-vocabulary-and-no-single-quote" "bin/workflow/lib/next-step/gate-mode.js"
check "every --gate call printed one GATE_ACTION line" "$NCALL" "$(count_re "$ALL_GATE" '^GATE_ACTION=')"
check "GATE_ACTION is always one of the 4 values" "$NCALL" \
  "$(count_re "$ALL_GATE" '^GATE_ACTION=(proceed|ask|present-and-stop|none)$')"
check "every --gate call printed GATE_HINT and REASON" "$((NCALL * 2))" "$(count_re "$ALL_GATE" '^(GATE_HINT|REASON)=')"
check "no single quote on GATE_HINT= / REASON= lines" 0 "$(count_re "$ALL_GATE" "^(GATE_HINT|REASON)=.*'")"
case_end

gt_finish
