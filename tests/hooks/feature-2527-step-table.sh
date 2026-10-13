#!/usr/bin/env bash
# tests/hooks/feature-2527-step-table.sh
# Tests: hooks/workflow-state/step-table.js, hooks/workflow-state/session-profile.js, hooks/lib/delivery-path.js, hooks/workflow-state/state-io/migrations/v4-to-v5.js, hooks/workflow-state/state-io/core.js, bin/workflow/next-step
# Tags: scope:issue-specific, workflow-state, step-table, migration, schema-v5, next-step, issue-2527, TL2
# Dispatch + aggregate entrypoint for the #2527 stage-1 split suite. Each case
# below runs one group file in feature-2527-step-table/ (also runnable alone);
# _lib.sh, fixture.js and fake-gh.js there are shared scaffolding, not tests.
# TL3 gap: see each group's own TL3 gap note.
set -uo pipefail

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2527-step-table"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TOTAL_PASS=0
TOTAL_FAIL=0

# run_group <file> — runs one group, folds its "Results:" line into the totals. A non-zero
# exit whose Results line reports 0 failed still counts as 1 failure (no false green from a
# child that crashed after printing, or whose own exit check disagrees with its counters).
run_group() {
  local script="$SPLIT_DIR/$1" out_file rc results_line group_fail
  if [ ! -f "$script" ]; then
    echo "FAIL: split group missing: $script"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    return
  fi
  echo ""
  echo "=== $1 ==="
  out_file="$(mktemp)"
  run_with_timeout 300 bash "$script" 2>&1 | tee "$out_file"
  rc=${PIPESTATUS[0]}
  results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
  if [ -n "$results_line" ]; then
    group_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
    TOTAL_PASS=$((TOTAL_PASS + $(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')))
    TOTAL_FAIL=$((TOTAL_FAIL + group_fail))
    if [ "$rc" -ne 0 ] && [ "$group_fail" -eq 0 ]; then
      echo "FAIL: $1 exited with status $rc but its Results line reports 0 failed; counting as 1 failure"
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
  else
    echo "WARN: $1 emitted no Results line (exit=$rc); counting as 1 failure"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  rm -f "$out_file"
}

# Dispatcher self-check: run_group against throwaway children in a temp SPLIT_DIR, with the
# real totals saved and restored, so only this case's own verdict reaches the aggregate.
case_begin "dispatcher: a non-zero child exit is never green" "tests/hooks/feature-2527-step-table.sh"
_st_saved_dir="$SPLIT_DIR"
SPLIT_DIR="$(make_tmp)"
printf 'echo "Results: 3 passed, 0 failed"\nexit 1\n' > "$SPLIT_DIR/lying-child.sh"
printf 'echo "Results: 2 passed, 0 failed"\nexit 0\n' > "$SPLIT_DIR/green-child.sh"
printf 'echo "Results: 1 passed, 2 failed"\nexit 2\n' > "$SPLIT_DIR/red-child.sh"
# selfcheck <file> <want "pass|fail"> — run one child through run_group from zeroed totals.
_st_selfcheck() {
  local saved_p="$TOTAL_PASS" saved_f="$TOTAL_FAIL" got
  TOTAL_PASS=0; TOTAL_FAIL=0
  run_group "$1" > /dev/null 2>&1
  got="$TOTAL_PASS|$TOTAL_FAIL"
  TOTAL_PASS="$saved_p"; TOTAL_FAIL="$saved_f"
  if [ "$got" = "$2" ]; then
    echo "PASS: $3 ($got)"; TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    echo "FAIL: $3 — want=[$2] got=[$got]"; TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
}
_st_selfcheck lying-child.sh "3|1" "Results '0 failed' + exit 1 -> aggregate counts 1 failure"
_st_selfcheck green-child.sh "2|0" "Results '0 failed' + exit 0 -> no extra failure"
_st_selfcheck red-child.sh "1|2" "Results '2 failed' + exit 2 -> the reported failures only, no double count"
rm -rf "$SPLIT_DIR"
SPLIT_DIR="$_st_saved_dir"
case_end

case_begin "group-table-query" "hooks/workflow-state/step-table.js"
run_group table-query.sh
case_end

case_begin "group-migration-v4-v5" "hooks/workflow-state/state-io/migrations/v4-to-v5.js"
run_group migration-v4-v5.sh
case_end

case_begin "group-resume-from-v4" "bin/workflow/next-step"
run_group resume-from-v4.sh
case_end

case_begin "group-profile-persistence" "hooks/workflow-state/session-profile.js"
run_group profile-persistence.sh
case_end

echo ""
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ]
