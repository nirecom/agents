# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/d-unsettled.sh
# Tests: hooks/workflow-state/dispatch-settlement.js, hooks/workflow-run-tests/dispatch-outcome.js
# Tags: workflow, run-tests, worker-dispatch, unsettled, classifier, tl1, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# "Unsettled" is decided from file existence alone: the latest .dispatched marker of a
# worker that records an outcome, with no .ingested beside it. Sequences are compared as
# decimal strings because a 16-digit sequence does not survive a Number() round trip.

# f2544_d_files <sid> <space-separated control file names> — "~" stands for the stem prefix.
f2544_d_files() {
  local sid="$1" name
  for name in $2; do
    f2544_probe touch "$sid" "${name//\~/$F2544_T}" '{}'
  done
}

f2544_d_predicate() {
  local name files want sid
  while IFS='|' read -r name files want; do
    sid="f2544-d-$name"
    f2544_d_files "$sid" "$files"
    f2544_eq "D/unsettled $name" "$(f2544_probe unsettled "$sid")" "${want//\~/$F2544_T}"
  done <<'TABLE'
no-payload|handoff.md|none
published-but-never-dispatched|~-1.json|none
dispatched-but-no-outcome|~-1.json ~-1.dispatched|~-1
outcome-present-not-ingested|~-1.json ~-1.dispatched ~-1.outcome.json|~-1
ingested|~-1.json ~-1.dispatched ~-1.outcome.json ~-1.ingested|none
newer-ingested-older-not|~-1.dispatched ~-2.dispatched ~-2.ingested|none
older-ingested-newer-not|~-1.dispatched ~-1.ingested ~-2.dispatched|~-2
newer-published-only|~-1.dispatched ~-1.ingested ~-2.json|none
ten-outranks-nine|~-9.dispatched ~-9.ingested ~-10.dispatched|~-10
only-unsequenced|~.dispatched|~
unsequenced-settled|~.dispatched ~.ingested|none
unsequenced-older-than-sequenced|~.dispatched ~-1.dispatched ~-1.ingested|none
sequenced-newer-than-settled-unsequenced|~.dispatched ~.ingested ~-1.dispatched|~-1
worker-that-records-no-outcome|worker-commit-push-1.json worker-commit-push-1.dispatched|none
legacy-stem-is-not-counted|~-1.legacy-1700000000000.dispatched|none
legacy-stem-beside-settled-latest|~-1.dispatched ~-1.ingested ~-2.legacy-1700000000000.dispatched|none
TABLE

  f2544_eq "D/unsettled missing control dir" "$(f2544_probe unsettled f2544-d-nodir)" "none"

  sid="f2544-d-legacy"
  printf '{}\n' > "$WORKFLOW_PLANS_DIR/$sid-$F2544_T-1.json"
  printf 'x\n' > "$WORKFLOW_PLANS_DIR/$sid-$F2544_T-1.dispatched"
  f2544_eq "D/unsettled legacy plans-dir files are out of scope" "$(f2544_probe unsettled "$sid")" "none"

  sid="f2544-d-scanfail"
  printf 'not a directory\n' > "$WORKFLOW_STATE_DIR/$sid.control"
  case "$(f2544_probe unsettled "$sid")" in
    *"|reason") pass "D/unsettled scan failure is unsettled and carries a reason" ;;
    *) fail "D/unsettled scan failure is unsettled and carries a reason" "got [$(f2544_probe unsettled "$sid")]" ;;
  esac
  rm -f "$WORKFLOW_STATE_DIR/$sid.control"
}

f2544_d_latest() {
  local name files want sid
  while IFS='|' read -r name files want; do
    sid="f2544-d-latest-$name"
    f2544_d_files "$sid" "$files"
    f2544_eq "D/latest $name" "$(f2544_probe latest "$sid" test-runner)" "${want//\~/$F2544_T}"
  done <<'TABLE'
none|handoff.md|none
payload-only|~-3.json|none
max-of-markers|~-3.dispatched ~-7.dispatched|~-7/7
nine-and-ten|~-9.dispatched ~-10.dispatched|~-10/10
unsequenced-is-seq-zero|~.dispatched|~/0
other-worker-ignored|~-2.dispatched worker-commit-push-9.dispatched|~-2/2
above-safe-integer|~-9007199254740992.dispatched ~-9007199254740993.dispatched|~-9007199254740993/9007199254740993
legacy-ignored|~-4.dispatched ~-5.legacy-1700000000000.dispatched|~-4/4
TABLE
}

f2544_d_ordering() {
  local name left right want
  while IFS='|' read -r name left right want; do
    f2544_eq "D/order $name" "$(f2544_probe cmp "$left" "$right")" "$want"
  done <<'TABLE'
nine-before-ten|9|10|lt
ten-after-nine|10|9|gt
equal|7|7|eq
fifteen-before-sixteen-digits|999999999999999|1000000000000000|lt
sixteen-after-fifteen-digits|1000000000000000|999999999999999|gt
above-safe-integer-ascending|9007199254740992|9007199254740993|lt
above-safe-integer-descending|9007199254740993|9007199254740992|gt
above-safe-integer-equal|9007199254740993|9007199254740993|eq
TABLE
}

# f2544_d_mtime_pair <sid> <older-seq> <newer-seq> — two .dispatched markers whose mtimes
# are pinned explicitly, so the order never depends on how fast the files were written.
f2544_d_mtime_pair() {
  local dir="$WORKFLOW_STATE_DIR/$1.control"
  f2544_d_files "$1" "~-$2.dispatched ~-$3.dispatched"
  touch -d '2026-01-01 00:00:00' "$dir/$F2544_T-$2.dispatched"
  touch -d '2026-01-01 00:00:10' "$dir/$F2544_T-$3.dispatched"
}

# Order is marker mtime first, sequence only as the tiebreaker: a lower sequence
# dispatched later is the latest one.
f2544_d_mtime_reversal() {
  local sid="f2544-d-mtime-lower-seq-newer"
  f2544_d_mtime_pair "$sid" 7 3
  f2544_eq "D/latest mtime: newer lower-seq marker beats older higher-seq marker" \
    "$(f2544_probe latest "$sid" test-runner)" "$F2544_T-3/3"
  f2544_eq "D/latest mtime: the unsettled stem follows the same order" \
    "$(f2544_probe unsettled "$sid")" "$F2544_T-3"

  sid="f2544-d-mtime-higher-seq-newer"
  f2544_d_mtime_pair "$sid" 3 7
  f2544_eq "D/latest mtime: newer higher-seq marker wins when both criteria agree" \
    "$(f2544_probe latest "$sid" test-runner)" "$F2544_T-7/7"
}

# A background dispatch: no earlier complete may survive until its own outcome arrives.
f2544_d_background_window() {
  local sid="f2544-d-bg" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete '{"run_outcome":"pass"}'
  f2544_dispatched "$sid" "$stem"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "D/background: the earlier complete is returned to pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "D/background: the unsettled stem is annotated" "$(f2544_field "$sid" "$F2544_KEY_UNSETTLED")" "$stem"
  f2544_eq "D/background: the earlier run_outcome is cleared" "$(f2544_field "$sid" run_outcome)" "absent"
  f2544_pass_outcome "$sid" "$stem"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "D/background: its own outcome completes it" "$(f2544_status "$sid")" "complete"
  f2544_eq "D/background: and the annotation is cleared" "$(f2544_field "$sid" "$F2544_KEY_UNSETTLED")" "absent"
}

f2544_d_published_only_keeps_complete() {
  local sid="f2544-d-published" events
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete
  f2544_probe payload "$sid" "$F2544_T-1" "$F2544_ROOT_N"
  events="$(f2544_events "$sid")"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "D/published only: a payload that was never dispatched leaves complete alone" "$(f2544_status "$sid")" "complete"
  f2544_eq "D/published only: and writes nothing" "$(f2544_events "$sid")" "$events"
}

case_begin "unsettled-predicate-table" "hooks/workflow-state/dispatch-settlement.js"
f2544_d_predicate
case_end

case_begin "latest-dispatch-is-the-max-dispatched-marker" "hooks/workflow-state/dispatch-settlement.js"
f2544_d_latest
case_end

case_begin "mtime-ordering-overrides-sequence" "hooks/workflow-state/dispatch-settlement.js"
f2544_d_mtime_reversal
case_end

case_begin "sequence-ordering-is-decimal-string-order" "hooks/workflow-state/dispatch-settlement.js"
f2544_d_ordering
case_end

case_begin "background-dispatch-leaves-no-stale-complete" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_d_background_window
case_end

case_begin "published-but-undispatched-payload-is-not-unsettled" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_d_published_only_keeps_complete
case_end
