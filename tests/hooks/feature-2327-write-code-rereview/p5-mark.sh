#!/usr/bin/env bash
# Tests: bin/workflow/lib/next-step/state-ops.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# --mark entry point: next-step --session <sid> --mark write_code.
# The mark entry carries no repoDir, so the worktree comes from the recorded
# session_worktree. Checks: reopen + notice on stderr when stale; no reopen when
# the staged set still matches the record.

echo "=== P5: --mark entry (state-ops.js) ==="

# STALE (linked) adds hooks/impl.js after the review; SAME (linked) matches the record.
MARK_MAIN="$TMPDIR_BASE/mark-main"
MARK_STALE="$TMPDIR_BASE/mark-stale"
MARK_SAME="$TMPDIR_BASE/mark-same"
rr_repo "$MARK_MAIN"
rr_linked "$MARK_MAIN" "$MARK_STALE" featmarkstale
rr_linked "$MARK_MAIN" "$MARK_SAME" featmarksame
rr_stage "$MARK_STALE" tests/x.sh "echo x"
rr_stage "$MARK_SAME" tests/x.sh "echo x"
rr_stage "$MARK_STALE" hooks/impl.js "impl"
MARK_OID="$(rr_oid "$MARK_SAME" tests/x.sh)"
MARK_STALE_N="$(np "$MARK_STALE")"
MARK_SAME_N="$(np "$MARK_SAME")"
MARK_RT="{\"status\":\"complete\",\"review_scope_manifest\":{\"v\":1,\"files\":{\"tests/x.sh\":\"$MARK_OID\"}}}"

# mark_run <sid> <cwd> <errfile>
mark_run() {
  (cd "$2" && run_with_timeout node "$NEXT_STEP_N" --session "$1" --mark write_code 2>"$3" >/dev/null) || true
}

# M1: stale session worktree → reopened, notice on stderr
rr_state mk1rere "$MARK_RT" "" "$MARK_STALE_N"
mark_run mk1rere "$MARK_STALE_N" "$TMPDIR_BASE/mk1.err"
MK1_VIEW="$(rr_view mk1rere)"
check_contains "M1a: --mark sets write_code complete" '"wc_status":"complete"' "$MK1_VIEW"
check_contains "M1b: --mark reopens review_tests as write-code-stale" '"rt_status":"pending","rt_reopen":"write-code-stale"' "$MK1_VIEW"
check_contains "M1c: review_scope_manifest kept, run_tests untouched" '"rt_manifest":"kept","run_tests":"pending"' "$MK1_VIEW"
check_contains "M1d: stderr notice = formatReviewTestsReopenNotice" "$(rr_notice review-tests-reopened write-code-stale)" "$(cat "$TMPDIR_BASE/mk1.err" 2>/dev/null)"

# M2: session worktree matches the record → no reopen, no notice
rr_state mk2rere "$MARK_RT" "" "$MARK_SAME_N"
mark_run mk2rere "$MARK_SAME_N" "$TMPDIR_BASE/mk2.err"
MK2_VIEW="$(rr_view mk2rere)"
check_contains "M2a: no diff → write_code complete" '"wc_status":"complete"' "$MK2_VIEW"
check_contains "M2b: no diff → review_tests stays complete, no reopen_reason" '"rt_status":"complete","rt_reopen":null' "$MK2_VIEW"
check_not_contains "M2c: no diff → no reopen notice" "write-code-stale" "$(cat "$TMPDIR_BASE/mk2.err" 2>/dev/null)"

echo ""
