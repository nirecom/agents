#!/usr/bin/env bash
# Tests: bin/workflow/lib/next-step/advance-shared.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# advance entry: next-step --advance --step write_code --complete [--next].
# Covers: reopen + notice with/without --next, C2 trust boundary (cwd wins over
# CLAUDE_PROJECT_DIR; a main-worktree cwd falls back to the session worktree),
# no reopen when the staged set still matches the record.

echo "=== P4: advance entry (--advance --step write_code --complete) ==="

# MAIN's index matches the record; STALE (linked) adds hooks/new.js; SAME (linked)
# matches the record. FRESH is an unrelated repo that also matches the record.
ADV_MAIN="$TMPDIR_BASE/adv-main"
ADV_STALE="$TMPDIR_BASE/adv-stale"
ADV_SAME="$TMPDIR_BASE/adv-same"
ADV_FRESH="$TMPDIR_BASE/adv-fresh"
rr_repo "$ADV_MAIN"
rr_linked "$ADV_MAIN" "$ADV_STALE" featadvstale
rr_linked "$ADV_MAIN" "$ADV_SAME" featadvsame
rr_repo "$ADV_FRESH"
for d in "$ADV_MAIN" "$ADV_STALE" "$ADV_SAME" "$ADV_FRESH"; do rr_stage "$d" tests/x.sh "echo x"; done
rr_stage "$ADV_STALE" hooks/new.js "impl"
ADV_OID="$(rr_oid "$ADV_MAIN" tests/x.sh)"
ADV_MAIN_N="$(np "$ADV_MAIN")"
ADV_STALE_N="$(np "$ADV_STALE")"
ADV_SAME_N="$(np "$ADV_SAME")"
ADV_FRESH_N="$(np "$ADV_FRESH")"
ADV_RT="{\"status\":\"complete\",\"review_scope_manifest\":{\"v\":1,\"files\":{\"tests/x.sh\":\"$ADV_OID\"}}}"
ADV_NOTICE="$(rr_notice review-tests-reopened write-code-stale)"

# adv_run <sid> <cwd> <project-dir> <errfile> [--next]: prints stdout
adv_run() {
  (cd "$2" && CLAUDE_PROJECT_DIR="$3" run_with_timeout node "$NEXT_STEP_N" --session "$1" --advance --step write_code --complete ${5:-} 2>"$4") || true
}

# A1: stale linked worktree → write_code complete, review_tests reopened, notice on stderr
rr_state adv1 "$ADV_RT"
adv_run adv1 "$ADV_STALE_N" "$ADV_STALE_N" "$TMPDIR_BASE/adv1.err" >/dev/null
ADV1_VIEW="$(rr_view adv1)"
check_contains "A1a: write_code complete" '"wc_status":"complete"' "$ADV1_VIEW"
check_contains "A1b: review_tests reopened as write-code-stale" '"rt_status":"pending","rt_reopen":"write-code-stale"' "$ADV1_VIEW"
check_contains "A1c: review_scope_manifest kept, run_tests untouched" '"rt_manifest":"kept","run_tests":"pending"' "$ADV1_VIEW"
check_contains "A1d: write_code_scope_manifest = staged set at completion" "\"hooks/new.js\"" "$ADV1_VIEW"
check_contains "A1e: stderr notice = formatReviewTestsReopenNotice" "$ADV_NOTICE" "$(cat "$TMPDIR_BASE/adv1.err" 2>/dev/null)"

# A2: --next still emits the notice and routes to review-tests
rr_state adv2 "$ADV_RT"
ADV2_OUT="$(adv_run adv2 "$ADV_STALE_N" "$ADV_STALE_N" "$TMPDIR_BASE/adv2.err" --next)"
check_contains "A2a: --next does not suppress the notice" "$ADV_NOTICE" "$(cat "$TMPDIR_BASE/adv2.err" 2>/dev/null)"
check_contains "A2b: --next ACTION=invoke" "ACTION=invoke" "$ADV2_OUT"
check_contains "A2c: --next NEXT_SKILL=review-tests" "NEXT_SKILL=review-tests" "$ADV2_OUT"

# A3: C2 — CLAUDE_PROJECT_DIR points at a repo matching the record; cwd is stale.
# The trusted repo is the real cwd, so review_tests still reopens as stale.
rr_state adv3 "$ADV_RT"
adv_run adv3 "$ADV_STALE_N" "$ADV_FRESH_N" "$TMPDIR_BASE/adv3.err" >/dev/null
check_contains "A3: forged CLAUDE_PROJECT_DIR ignored; cwd stale → reopened" '"rt_status":"pending","rt_reopen":"write-code-stale"' "$(rr_view adv3)"

# A3b: cwd = main worktree (matches the record) → falls back to the recorded
# session worktree (stale), so review_tests still reopens as stale.
rr_state adv3b "$ADV_RT" "" "$ADV_STALE_N"
adv_run adv3b "$ADV_MAIN_N" "$ADV_MAIN_N" "$TMPDIR_BASE/adv3b.err" >/dev/null
check_contains "A3b: main-worktree cwd → session worktree → reopened" '"rt_status":"pending","rt_reopen":"write-code-stale"' "$(rr_view adv3b)"

# A4: staged set equals the record → no reopen, write_code still records its manifest
rr_state adv4 "$ADV_RT"
adv_run adv4 "$ADV_SAME_N" "$ADV_SAME_N" "$TMPDIR_BASE/adv4.err" >/dev/null
ADV4_VIEW="$(rr_view adv4)"
check_contains "A4a: no diff → review_tests stays complete, no reopen_reason" '"rt_status":"complete","rt_reopen":null' "$ADV4_VIEW"
check_contains "A4b: no diff → write_code complete with its manifest" "\"wc_status\":\"complete\",\"wc_manifest\":{\"v\":1,\"files\":{\"tests/x.sh\":\"$ADV_OID\"}}" "$ADV4_VIEW"

echo ""
