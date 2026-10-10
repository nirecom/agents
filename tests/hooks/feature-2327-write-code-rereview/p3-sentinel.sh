#!/usr/bin/env bash
# Tests: hooks/workflow-mark/mark-step-handler.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# Sentinel entry point: WORKFLOW_MARK_STEP_write_code_complete
# Checks: notice pushed, review_tests reopened, write_code stays complete,
# write_code_scope_manifest written, notice text = formatReviewTestsReopenNotice output.

REOPEN_MOD="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state/review-tests-reopen.js"

echo "=== P3: sentinel entry (WORKFLOW_MARK_STEP_write_code_complete) ==="

# Build a fixture: all steps up through review_tests complete, write_code
# pending. tests/x.sh is recorded; hooks/impl.js staged afterwards makes it stale.
SE_REPO="$TMPDIR_BASE/se-repo"
rr_repo "$SE_REPO"
rr_stage "$SE_REPO" tests/x.sh "echo x"
SE_OID="$(rr_oid "$SE_REPO" tests/x.sh)"
rr_stage "$SE_REPO" hooks/impl.js "impl"
SE_IMPL_OID="$(rr_oid "$SE_REPO" hooks/impl.js)"
SE_REPO_N="$(np "$SE_REPO")"

SE_SID="serere"
rr_state "$SE_SID" "{\"status\":\"complete\",\"review_scope_manifest\":{\"v\":1,\"files\":{\"tests/x.sh\":\"$SE_OID\"}}}"

SENTINEL_CMD='echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"'
# Neutral process cwd + no CLAUDE_PROJECT_DIR: the fixture repo is reachable
# only through the payload's top-level cwd, never through the runner's checkout.
SE_NEUTRAL_N="$(np "$TMPDIR_BASE")"
SE_OUT="$(SE_SID="$SE_SID" SE_REPO_N="$SE_REPO_N" SE_NEUTRAL_N="$SE_NEUTRAL_N" run_with_timeout node - <<'JS' 2>&1
const { execSync } = require("child_process");
const path = require("path");
const payload = JSON.stringify({
  session_id: process.env.SE_SID,
  tool_name: "Bash",
  tool_input: { command: 'echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"' },
  cwd: process.env.SE_REPO_N
});
const env = Object.assign({}, process.env);
delete env.CLAUDE_PROJECT_DIR;
try {
  const out = execSync(
    'node "' + path.join(process.env.SCRIPT_CHECKOUT_ROOT_N, "hooks/workflow-mark.js") + '"',
    { input: payload, encoding:"utf8", timeout:15000, env, cwd: process.env.SE_NEUTRAL_N }
  );
  process.stdout.write("STDOUT:" + out);
} catch(e) {
  process.stdout.write("STDOUT:" + (e.stdout||""));
  process.stderr.write("STDERR:" + (e.stderr||""));
}
JS
)"
check_not_contains "SE1: sentinel completes without crash" "Error:" "$SE_OUT"

SE_STATE="$(rr_view "$SE_SID")"
check_contains "SE2: write_code is complete after sentinel" '"wc_status":"complete"' "$SE_STATE"
check_contains "SE3: review_tests reopened as write-code-stale" '"rt_status":"pending","rt_reopen":"write-code-stale"' "$SE_STATE"
check_contains "SE4: review_scope_manifest kept, run_tests untouched" '"rt_manifest":"kept","run_tests":"pending"' "$SE_STATE"
check_contains "SE5: write_code_scope_manifest = staged set at completion" "\"hooks/impl.js\":\"$SE_IMPL_OID\"" "$SE_STATE"

# SE6: notice text in mark hook output equals formatReviewTestsReopenNotice output
check_contains "SE6: mark hook message contains formatReviewTestsReopenNotice output" "$(rr_notice review-tests-reopened write-code-stale)" "$SE_OUT"

# SE7: idempotent — write_code already complete and the staged set differs from
# the record (would be stale), yet the sentinel does not re-fire the reopen.
SE7_SID="se7rere"
rr_state "$SE7_SID" '{"status":"complete","review_scope_manifest":{"v":1,"files":{"hooks/thing.js":"oid1"}}}' \
  '{"status":"complete","write_code_scope_manifest":{"v":1,"files":{"hooks/thing.js":"oid1"}}}'

SE7_PAYLOAD="$(printf '{"session_id":"se7rere","tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_write_code_complete>>\""},"cwd":"%s"}' "$SE_REPO_N")"
( cd "$TMPDIR_BASE" && echo "$SE7_PAYLOAD" | run_with_timeout env -u CLAUDE_PROJECT_DIR node "$WORKFLOW_MARK_N" >/dev/null 2>&1 ) || true
check_contains "SE7: idempotent — already-complete write_code does not re-fire reopen" '"rt_status":"complete","rt_reopen":null' "$(rr_view "$SE7_SID")"

echo ""
