#!/usr/bin/env bash
# Tests: hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# next-step verdict behavior after reopen: ACTION=invoke review-tests;
# REVIEW_TESTS_REOPEN_HINT constant; after review-tests complete run_tests
# advances; negative control (pending review_tests without reopen_reason +
# run_tests complete → abort); reopen write failure diagnostic.

STEPS_MOD="$AGENTS_DIR_N/bin/workflow/lib/next-step/steps.js"

echo "=== P6: verdict / record-step-verdict behavior ==="

# V1: REVIEW_TESTS_REOPEN_HINT exists in steps.js
V1_OUT="$(STEPS_MOD="$STEPS_MOD" run_with_timeout node - <<'JS' 2>/dev/null
try {
  const m = require(process.env.STEPS_MOD);
  if (typeof m.REVIEW_TESTS_REOPEN_HINT !== 'string' || m.REVIEW_TESTS_REOPEN_HINT.length === 0) {
    process.stdout.write("MISSING_OR_EMPTY");
  } else {
    process.stdout.write("OK:" + m.REVIEW_TESTS_REOPEN_HINT.slice(0,80));
  }
} catch(e) { process.stdout.write("ERROR:" + e.message); }
JS
)"
check_contains "V1: REVIEW_TESTS_REOPEN_HINT exported from steps.js" "OK:" "$V1_OUT"

# V1a-V1c: content invariants on REVIEW_TESTS_REOPEN_HINT
V1_HINT_FULL="$(STEPS_MOD="$STEPS_MOD" run_with_timeout node - <<'JS' 2>/dev/null
try {
  const m = require(process.env.STEPS_MOD);
  process.stdout.write(typeof m.REVIEW_TESTS_REOPEN_HINT === 'string' ? m.REVIEW_TESTS_REOPEN_HINT : "NOT_IMPLEMENTED");
} catch(e) { process.stdout.write("NOT_IMPLEMENTED"); }
JS
)"
check_contains "V1a: REVIEW_TESTS_REOPEN_HINT mentions /review-tests" "/review-tests" "$V1_HINT_FULL"
check_contains "V1b: REVIEW_TESTS_REOPEN_HINT says not to re-run /write-code" "do not re-run /write-code" "$V1_HINT_FULL"
# V1c: no single quote — the hint is injected into shell command strings in some paths
if [ -z "$V1_HINT_FULL" ] || [ "$V1_HINT_FULL" = "NOT_IMPLEMENTED" ]; then
  fail "V1c: REVIEW_TESTS_REOPEN_HINT not implemented — cannot verify single-quote invariant"
elif echo "$V1_HINT_FULL" | grep -qF "'"; then
  fail "V1c: REVIEW_TESTS_REOPEN_HINT must not contain single quotes (checkNoQuote invariant)"
else
  pass "V1c: REVIEW_TESTS_REOPEN_HINT has no single quotes"
fi

# V2: after reopen, next-step reports ACTION=invoke and skill=review-tests
# State: write_code complete, review_tests pending with reopen_reason=write-code-stale
V2_REPO="$TMPDIR_BASE/v2-repo"
mkdir -p "$V2_REPO"
(cd "$V2_REPO" && git init -q && git config user.email t@test.com && git config user.name T && git config core.hooksPath /dev/null && printf 'seed\n' > README.md && git add README.md && git commit -qm init) >/dev/null 2>&1
V2_REPO_N="$(np "$V2_REPO")"

node - <<JS 2>/dev/null
const fs = require("fs"), path = require("path");
const steps = {
  workflow_init:{status:"complete"}, clarify_intent:{status:"complete"},
  research:{status:"complete"}, outline:{status:"complete"}, detail:{status:"complete"},
  branching_complete:{status:"complete"}, write_tests:{status:"complete"},
  review_tests:{status:"pending", reopen_reason:"write-code-stale"},
  write_code:{status:"complete",
    write_code_scope_manifest:JSON.stringify({v:1,files:{"hooks/impl.js":"newoid"}})},
  run_tests:{status:"pending"}, review_security:{status:"pending"},
  docs:{status:"pending"}, review_docs:{status:"pending"},
  user_verification:{status:"pending"}, cleanup:{status:"pending"},
  pre_final_report_gate:{status:"pending"}, final_report:{status:"pending"}
};
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "v2rere.json"),
  JSON.stringify({steps,closes_issues:[2327]}));
JS

V2_OUT="$(cd "$V2_REPO_N" && CLAUDE_PROJECT_DIR="$V2_REPO_N" run_with_timeout node "$NEXT_STEP_N" --session v2rere 2>/dev/null)" || true
check_contains "V2a: after reopen ACTION=invoke" "ACTION=invoke" "$V2_OUT"
check_contains "V2b: after reopen NEXT_SKILL=review-tests" "review-tests" "$V2_OUT"

# V2c: NEXT_HINT contains REVIEW_TESTS_REOPEN_HINT value (only once implemented)
V2C_HINT="$(STEPS_MOD="$STEPS_MOD" run_with_timeout node - <<'JS' 2>/dev/null
try {
  const m = require(process.env.STEPS_MOD);
  process.stdout.write(typeof m.REVIEW_TESTS_REOPEN_HINT === 'string' ? m.REVIEW_TESTS_REOPEN_HINT : "NOT_IMPLEMENTED");
} catch(e) { process.stdout.write("NOT_IMPLEMENTED"); }
JS
)"
if [ "$V2C_HINT" != "NOT_IMPLEMENTED" ] && [ -n "$V2C_HINT" ]; then
  check_contains "V2c: NEXT_HINT contains REVIEW_TESTS_REOPEN_HINT" "$V2C_HINT" "$V2_OUT"
else
  fail "V2c: REVIEW_TESTS_REOPEN_HINT not yet implemented"
fi

# V3: after review_tests complete following a reopen, run_tests advances
# (reopen_reason is tombstoned — no longer blocks)
node - <<JS 2>/dev/null
const fs = require("fs"), path = require("path");
const steps = {
  workflow_init:{status:"complete"}, clarify_intent:{status:"complete"},
  research:{status:"complete"}, outline:{status:"complete"}, detail:{status:"complete"},
  branching_complete:{status:"complete"}, write_tests:{status:"complete"},
  review_tests:{status:"complete"},  // complete again after rereview — no reopen_reason
  write_code:{status:"complete",
    write_code_scope_manifest:JSON.stringify({v:1,files:{"hooks/impl.js":"newoid"}})},
  run_tests:{status:"pending"}, review_security:{status:"pending"},
  docs:{status:"pending"}, review_docs:{status:"pending"},
  user_verification:{status:"pending"}, cleanup:{status:"pending"},
  pre_final_report_gate:{status:"pending"}, final_report:{status:"pending"}
};
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "v3rere.json"),
  JSON.stringify({steps,closes_issues:[2327]}));
JS

V3_OUT="$(cd "$V2_REPO_N" && CLAUDE_PROJECT_DIR="$V2_REPO_N" run_with_timeout node "$NEXT_STEP_N" --session v3rere 2>/dev/null)" || true
check_contains "V3: after rereview complete, run_tests advances (ACTION=invoke)" "ACTION=invoke" "$V3_OUT"
check_contains "V3b: skill is run-tests" "run-tests" "$V3_OUT"

# V4: negative control — pending review_tests WITHOUT reopen_reason + run_tests complete
# This should NOT advance run_tests; workflow is blocked (review_tests must be completed first)
node - <<JS 2>/dev/null
const fs = require("fs"), path = require("path");
const steps = {
  workflow_init:{status:"complete"}, clarify_intent:{status:"complete"},
  research:{status:"complete"}, outline:{status:"complete"}, detail:{status:"complete"},
  branching_complete:{status:"complete"}, write_tests:{status:"complete"},
  // review_tests is pending but has no reopen_reason (never reopened — normal pending)
  review_tests:{status:"pending"},
  write_code:{status:"complete"},
  run_tests:{status:"complete"}, // anomalous: run_tests already complete but review_tests pending
  review_security:{status:"pending"},
  docs:{status:"pending"}, review_docs:{status:"pending"},
  user_verification:{status:"pending"}, cleanup:{status:"pending"},
  pre_final_report_gate:{status:"pending"}, final_report:{status:"pending"}
};
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "v4rere.json"),
  JSON.stringify({steps,closes_issues:[2327]}));
JS

V4_OUT="$(cd "$V2_REPO_N" && CLAUDE_PROJECT_DIR="$V2_REPO_N" run_with_timeout node "$NEXT_STEP_N" --session v4rere 2>/dev/null)" || true
# Without reopen_reason, a pending review_tests in this position is an inconsistency
# ACTION should be blocked/abort or invoke review-tests, NOT invoke run-tests
check_not_contains "V4: negative control — run_tests NOT advanced when review_tests pending sans reopen" "run-tests" "$V4_OUT"

# V5: verdict.js exception — review_tests pending + reopen_reason in REVIEW_TESTS_REOPEN_REASONS
#     → is treated as current step (ACTION=invoke review-tests), not inconsistency
node - <<JS 2>/dev/null
const fs = require("fs"), path = require("path");
const steps = {
  workflow_init:{status:"complete"}, clarify_intent:{status:"complete"},
  research:{status:"complete"}, outline:{status:"complete"}, detail:{status:"complete"},
  branching_complete:{status:"complete"}, write_tests:{status:"complete"},
  review_tests:{status:"pending", reopen_reason:"write-code-missing"},
  write_code:{status:"complete"},
  run_tests:{status:"pending"}, review_security:{status:"pending"},
  docs:{status:"pending"}, review_docs:{status:"pending"},
  user_verification:{status:"pending"}, cleanup:{status:"pending"},
  pre_final_report_gate:{status:"pending"}, final_report:{status:"pending"}
};
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "v5rere.json"),
  JSON.stringify({steps,closes_issues:[2327]}));
JS

V5_OUT="$(cd "$V2_REPO_N" && CLAUDE_PROJECT_DIR="$V2_REPO_N" run_with_timeout node "$NEXT_STEP_N" --session v5rere 2>/dev/null)" || true
check_not_contains "V5: write-code-missing reopen_reason is not an inconsistency (no abort)" "abort" "$V5_OUT"
check_contains "V5b: write-code-missing reopen treated as ACTION=invoke" "ACTION=invoke" "$V5_OUT"

# V6: reopen_reason tombstoned — after review_tests completes the second time,
#     run_tests can see it as complete and verdict is correct
node - <<JS 2>/dev/null
const fs = require("fs"), path = require("path");
const steps = {
  workflow_init:{status:"complete"}, clarify_intent:{status:"complete"},
  research:{status:"complete"}, outline:{status:"complete"}, detail:{status:"complete"},
  branching_complete:{status:"complete"}, write_tests:{status:"complete"},
  // reopen_reason still on the step but review_tests is now complete again
  review_tests:{status:"complete", reopen_reason:"write-code-stale"},
  write_code:{status:"complete"},
  run_tests:{status:"pending"}, review_security:{status:"pending"},
  docs:{status:"pending"}, review_docs:{status:"pending"},
  user_verification:{status:"pending"}, cleanup:{status:"pending"},
  pre_final_report_gate:{status:"pending"}, final_report:{status:"pending"}
};
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "v6rere.json"),
  JSON.stringify({steps,closes_issues:[2327]}));
JS

V6_OUT="$(cd "$V2_REPO_N" && CLAUDE_PROJECT_DIR="$V2_REPO_N" run_with_timeout node "$NEXT_STEP_N" --session v6rere 2>/dev/null)" || true
# review_tests is complete so run_tests should be the current step
check_contains "V6: reopen_reason on complete review_tests does not block run_tests" "run-tests" "$V6_OUT"

echo ""
