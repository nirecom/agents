#!/bin/bash
# tests/bin/feature-commit-gate-redesign/section-d.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Section D: workflow-mark.js push reset.

echo ""
echo "=== Section D: workflow-mark push reset ==="

REPO_D="$(setup_main_checkout "secD-repo")"

# 18. Feature branch push success → uv stays at "complete"
SID_18="d18-$$"
write_state "$SID_18" "$(state_json "$SID_18" "feature/x" "complete" "complete")"
run_mark "$REPO_D" "$(build_mark_json 'git push origin feature/x' "$SID_18" 0 "$REPO_D")" >/dev/null
UV_18="$(read_state_step "$SID_18" "user_verification")"
if [ "$UV_18" = "complete" ]; then
    pass "D18. feature branch push → uv stays complete"
else
    fail "D18. expected uv=complete, got: $UV_18"
fi

# 19. Protected branch push success → uv reset to "pending"
SID_19="d19-$$"
write_state "$SID_19" "$(state_json "$SID_19" "main" "complete" "complete")"
run_mark "$REPO_D" "$(build_mark_json 'git push origin main' "$SID_19" 0 "$REPO_D")" >/dev/null
UV_19="$(read_state_step "$SID_19" "user_verification")"
if [ "$UV_19" = "pending" ]; then
    pass "D19. protected branch push → uv reset to pending"
else
    fail "D19. expected uv=pending, got: $UV_19"
fi

# 20. Feature branch push success → last_pushed_sha NOT set (setLastPushedSha not called)
SID_20="d20-$$"
write_state "$SID_20" "$(state_json "$SID_20" "feature/x" "complete" "complete")"
SHA_20_BEFORE="$(read_state_field "$SID_20" "last_pushed_sha")"
run_mark "$REPO_D" "$(build_mark_json 'git push origin feature/x' "$SID_20" 0 "$REPO_D")" >/dev/null
SHA_20_AFTER="$(read_state_field "$SID_20" "last_pushed_sha")"
if [ "$SHA_20_BEFORE" = "$SHA_20_AFTER" ]; then
    pass "D20. feature branch push → last_pushed_sha unchanged"
else
    fail "D20. last_pushed_sha changed: before=$SHA_20_BEFORE after=$SHA_20_AFTER"
fi

# 21. gh pr merge success → uv reset to "pending", last_pushed_sha NOT changed
SID_21="d21-$$"
write_state "$SID_21" "$(state_json "$SID_21" "main" "complete" "complete")"
SHA_21_BEFORE="$(read_state_field "$SID_21" "last_pushed_sha")"
run_mark "$REPO_D" "$(build_mark_json 'gh pr merge --squash' "$SID_21" 0 "$REPO_D")" >/dev/null
UV_21="$(read_state_step "$SID_21" "user_verification")"
SHA_21_AFTER="$(read_state_field "$SID_21" "last_pushed_sha")"
if [ "$UV_21" = "pending" ] && [ "$SHA_21_BEFORE" = "$SHA_21_AFTER" ]; then
    pass "D21. gh pr merge success → uv=pending; last_pushed_sha unchanged"
else
    fail "D21. uv=$UV_21 sha_before=$SHA_21_BEFORE sha_after=$SHA_21_AFTER"
fi
