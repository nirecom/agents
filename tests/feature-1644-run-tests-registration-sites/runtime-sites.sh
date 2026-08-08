# shellcheck shell=bash
# Tests: hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-gate.js, hooks/workflow-state/state-io/core.js
# Tags: tl2, workflow, run-tests, docs-only, registration-sites, scope:issue-specific
# Runtime (TL2) registration sites 5, 6 and 7. Sourced by the dispatcher.

# Site 5 — not-needed-handlers.js must HANDLE the sentinel and reject it when
# isDocsOnlyStaged() is false. Asserting the rejection message (not only the
# unchanged state) is what separates "handler rejects" from "no handler at all":
# an unregistered sentinel also leaves the state unchanged.
site5_not_needed_handler() {
  local out
  export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
  at_run_tests r5reject
  out="$(run_mark_hook r5reject "$SENTINEL_ECHO")"
  check_contains "R5a site5 non-docs-only: handler answers with a rejection naming the sentinel" \
    "$SENTINEL_LITERAL" "$out"
  check "R5b site5 non-docs-only: run_tests stays pending" \
    '"pending"' "$(step_status r5reject run_tests)"

  export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
  at_run_tests r5accept
  run_mark_hook r5accept "$SENTINEL_ECHO" >/dev/null
  check "R5c site5 docs-only: handler records run_tests as skipped" \
    '"skipped"' "$(step_status r5accept run_tests)"
}

# Site 6 — THE CRITICAL ASYMMETRY.
# MARK_STEP_* is unconditionally allowed by settings.json, so it is a door the
# model may open without any approval. Once SKIPPABLE_STEPS contains "run_tests"
# that door accepts `MARK_STEP_run_tests_skipped` unless mark-step-handler.js
# mirrors the write_tests evidence gate with a docs-only check. R6c pins that
# conjunction directly so a half-landed implementation cannot ship.
site6_mark_step_guard() {
  export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
  at_run_tests r6deny
  run_mark_hook r6deny 'echo "<<WORKFLOW_MARK_STEP_run_tests_skipped>>"' >/dev/null
  local got
  got="$(step_status r6deny run_tests)"
  if [ "$got" = '"skipped"' ]; then
    fail "R6a site6 non-docs-only MARK_STEP_run_tests_skipped MUST NOT record a skip -- got [$got]: an unapproved, docs-only-unverified skip is open"
  else
    pass "R6a site6 non-docs-only MARK_STEP_run_tests_skipped does not record a skip"
  fi

  export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
  at_run_tests r6allow
  run_mark_hook r6allow 'echo "<<WORKFLOW_MARK_STEP_run_tests_skipped>>"' >/dev/null
  check "R6b site6 docs-only MARK_STEP_run_tests_skipped records the skip" \
    '"skipped"' "$(step_status r6allow run_tests)"

  # R6c: the defect being prevented is the CONJUNCTION "SKIPPABLE_STEPS has
  # run_tests" AND "mark-step-handler.js has no docs-only branch for it". The
  # guard is required unconditionally; when the conjunction actually holds the
  # message says so, because that is the shipping hazard.
  local probe
  probe="$(WFSTATE_MODULE="$WFSTATE_MODULE" HANDLER="$AGENTS_DIR_N/hooks/workflow-mark/mark-step-handler.js" \
    run_with_timeout node -e '
const fs = require("fs");
const src = fs.readFileSync(process.env.HANDLER, "utf8");
const skippable = require(process.env.WFSTATE_MODULE).SKIPPABLE_STEPS.indexOf("run_tests") !== -1;
// The guard must both name the step and consult the docs-only predicate; either
// half alone is not a guard.
const guard = /run_tests/.test(src) && /isDocsOnlyStaged/.test(src);
process.stdout.write("guard=" + (guard ? "yes" : "no") + " skippable=" + (skippable ? "yes" : "no") + "\n");
' 2>&1)"
  case "$probe" in
    "guard=yes"*) pass "R6c site6 mark-step-handler.js carries a run_tests docs-only guard" ;;
    "guard=no skippable=yes"*)
      fail "R6c site6 CONJUNCTION OPEN -- SKIPPABLE_STEPS contains run_tests but mark-step-handler.js has no docs-only guard: unapproved unverified skip" ;;
    *)
      fail "R6c site6 mark-step-handler.js has no run_tests docs-only guard ($probe)" ;;
  esac
}

# Site 7 — the commit gate must not block on run_tests for a docs-only staged
# set. Direct pin of the #926-shaped defect. R7b is the non-vacuity counterpart:
# without it R7a would pass even if the gate stopped enforcing run_tests at all.
site7_commit_gate() {
  local out
  export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
  at_run_tests r7docs
  out="$(run_gate_hook r7docs 'git commit -m "docs: note"')"
  check_not_contains "R7a site7 docs-only commit is not blocked on run_tests" "run_tests" "$out"

  export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
  at_run_tests r7code
  out="$(run_gate_hook r7code 'git commit -m "feat: thing"')"
  check_contains "R7b site7 non-docs-only commit still blocks on run_tests" "run_tests" "$out"
}

run_runtime_site_cases() {
  site5_not_needed_handler
  site6_mark_step_guard
  site7_commit_gate
}
