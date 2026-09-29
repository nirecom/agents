#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io/review-tests.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# state-io/review-tests.js: new exports recordWriteCodeCompletionScope and
# REVIEW_TESTS_REOPEN_REASONS. Exercises direct module API; decide is stubbed,
# so no fixture repo is needed.

REVIEW_TESTS_IO="$AGENTS_DIR_N/hooks/workflow-state/state-io/review-tests.js"
export REVIEW_TESTS_IO

echo "=== P1: state-io review-tests new exports ==="

# S1: REVIEW_TESTS_REOPEN_REASONS exported and non-empty
S1_OUT="$(run_with_timeout node -e '
try {
  const m = require(process.argv[1]);
  if (!Array.isArray(m.REVIEW_TESTS_REOPEN_REASONS) || m.REVIEW_TESTS_REOPEN_REASONS.length === 0) {
    process.stdout.write("MISSING_OR_EMPTY");
  } else {
    process.stdout.write("OK:" + m.REVIEW_TESTS_REOPEN_REASONS.join(","));
  }
} catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$REVIEW_TESTS_IO" 2>/dev/null)"
check_contains "S1a: REVIEW_TESTS_REOPEN_REASONS exported and non-empty" "OK:" "$S1_OUT"
check_contains "S1b: includes write-code-stale" "write-code-stale" "$S1_OUT"
check_contains "S1c: includes write-code-missing" "write-code-missing" "$S1_OUT"
check_contains "S1d: includes write-code-unavailable" "write-code-unavailable" "$S1_OUT"

# rio_record <sid> <snapshot-json>: calls recordWriteCodeCompletionScope with decide → "stale".
rio_record() {
  run_with_timeout node -e '
const [io, sid, snap] = process.argv.slice(1);
try {
  const m = require(io);
  if (typeof m.recordWriteCodeCompletionScope !== "function") { process.stdout.write("NOT_IMPLEMENTED"); process.exit(0); }
  m.recordWriteCodeCompletionScope(sid, JSON.parse(snap), () => "stale");
  process.stdout.write("CALLED");
} catch (e) { process.stdout.write("ERROR:" + e.message); }
' "$REVIEW_TESTS_IO" "$1" "$2" 2>/dev/null
}

# S2: review_tests complete + decide stale → manifest recorded, review_tests reopened
rr_state s2rere '{"status":"complete","review_scope_manifest":{"v":1,"files":{"tests/x.sh":"oid1"}}}'
check "S2a: recordWriteCodeCompletionScope exists and callable" "CALLED" "$(rio_record s2rere '{"v":1,"files":{"hooks/thing.js":"newoid"}}')"
S2_VIEW="$(rr_view s2rere)"
check_contains "S2b: write_code_scope_manifest = snapshot" '"wc_manifest":{"v":1,"files":{"hooks/thing.js":"newoid"}}' "$S2_VIEW"
check_contains "S2c: review_tests reopened as write-code-stale" '"rt_status":"pending","rt_reopen":"write-code-stale"' "$S2_VIEW"
check_contains "S2d: review_scope_manifest kept, run_tests untouched" '"rt_manifest":"kept","run_tests":"pending"' "$S2_VIEW"

# S3: review_tests already pending → no reopen_reason stamped
rr_state s3rere '{"status":"pending"}'
rio_record s3rere '{"v":1,"files":{}}' >/dev/null
check_contains "S3: review_tests stays pending without reopen_reason" '"rt_status":"pending","rt_reopen":null' "$(rr_view s3rere)"

# S4: review_tests skipped → stays skipped
rr_state s4rere '{"status":"skipped"}'
rio_record s4rere '{"v":1,"files":{}}' >/dev/null
check_contains "S4: review_tests stays skipped (no reopen)" '"rt_status":"skipped","rt_reopen":null' "$(rr_view s4rere)"

echo ""
