# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/g-rewind-and-docs-skip.sh
# Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-run-tests.js
# Tags: workflow, run-tests, worker-dispatch, rewind, docs-only, skip-sentinel, hook, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# Paths this change must leave alone: a rewind is never refused because a dispatch is
# unsettled, and the docs-only skip is not a claim of success, so the hook never
# demotes it. Rows marked "control" hold before and after this change.

F2544_G_DOCS_REPO="$F2544_TMP_ROOT/repo-docs"
harness_git_init "$F2544_G_DOCS_REPO"
git -C "$F2544_G_DOCS_REPO" config user.email "test@example.com"
git -C "$F2544_G_DOCS_REPO" config user.name "test"
mkdir -p "$F2544_G_DOCS_REPO/docs"
printf 'doc\n' > "$F2544_G_DOCS_REPO/docs/note.md"
git -C "$F2544_G_DOCS_REPO" add docs/note.md >/dev/null 2>&1

F2544_G_REWIND_WRITE_TESTS='echo "<<WORKFLOW_RESET_FROM_write_tests: redo the tests>>"'
F2544_G_REWIND_SECURITY='echo "<<WORKFLOW_RESET_FROM_review_security: redo the security review>>"'
F2544_G_DOCS_SKIP='echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: staged set is human-facing docs only>>"'

# f2544_g_rewind_row <label> <sid> <unsettled:yes|no>
f2544_g_rewind_row() {
  local label="$1" sid="$2"
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete
  [[ "$3" == "yes" ]] && f2544_dispatched "$sid" "$F2544_T-1"
  f2544_mark "$sid" "$F2544_G_REWIND_WRITE_TESTS"
  f2544_eq "G/rewind $label: control — the target step is pending" "$(f2544_probe field "$sid" write_tests status)" "pending"
  f2544_eq "G/rewind $label: control — a later step is pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "G/rewind $label: control — an earlier step stays complete" "$(f2544_probe field "$sid" detail status)" "complete"
}

f2544_g_rewind_not_refused() {
  f2544_g_rewind_row "without an unsettled dispatch" "f2544-g-rw-plain" no
  f2544_g_rewind_row "with an unsettled dispatch" "f2544-g-rw-unsettled" yes
}

f2544_g_publish_rule_after_rewind() {
  local sid="f2544-g-rw-decision4"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$F2544_T-1"
  f2544_mark "$sid" "$F2544_G_REWIND_SECURITY"
  f2544_eq "G/decision 4: control — the rewind itself completes run_tests, unsettled or not" "$(f2544_status "$sid")" "complete"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "G/decision 4: the unsettled-returns-to-pending rule then applies on the next hook call" "$(f2544_status "$sid")" "pending"

  sid="f2544-g-rw-decision4-settled"
  f2544_ready "$sid"
  f2544_mark "$sid" "$F2544_G_REWIND_SECURITY"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "G/decision 4: control — with nothing dispatched the rewind's complete is kept" "$(f2544_status "$sid")" "complete"
}

f2544_g_docs_skip_while_unsettled() {
  local sid="f2544-g-docs" events
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$F2544_T-1"
  CLAUDE_PROJECT_DIR="$(np "$F2544_G_DOCS_REPO")" f2544_mark "$sid" "$F2544_G_DOCS_SKIP" "$F2544_G_DOCS_REPO"
  f2544_eq "G/docs skip: control — the sentinel is accepted while a dispatch is unsettled" "$(f2544_status "$sid")" "skipped"
  events="$(f2544_events "$sid")"
  f2544_hook_times 2 "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "G/docs skip: the hook never demotes a skipped run_tests" "$(f2544_status "$sid")" "skipped"
  f2544_eq "G/docs skip: and writes nothing for it" "$(f2544_events "$sid")" "$events"
  f2544_eq "G/docs skip: the dispatch is still reported unsettled, not hidden" "$(f2544_probe unsettled "$sid")" "$F2544_T-1"
}

case_begin "rewind-is-not-refused-by-an-unsettled-dispatch" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_g_rewind_not_refused
case_end

case_begin "unsettled-returns-to-pending-rule-applies-after-rewind-decision-4" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_g_publish_rule_after_rewind
case_end

case_begin "docs-only-skip-accepted-and-never-demoted-while-unsettled" "hooks/workflow-run-tests.js"
f2544_g_docs_skip_while_unsettled
case_end
