#!/bin/bash
# tests/bin/feature-commit-gate-redesign/section-b.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Section B: merge gate (error / fail-safe). Reuses REPO_A from section-a.sh.

echo ""
echo "=== Section B: Merge gate (error / fail-safe) ==="

# 7. gh pr merge + uv:missing entry → block
SID_7="b7-$$"
write_state "$SID_7" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_7", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":        {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":         {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":     {"status": "complete", "updated_at": "$NOW_ISO"},
    "review_security": {"status": "complete", "updated_at": "$NOW_ISO"},
    "run_tests":       {"status": "complete", "updated_at": "$NOW_ISO"},
    "docs":            {"status": "complete", "updated_at": "$NOW_ISO"}
  }
}
EOF
)"
RES_7="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_7" "$REPO_A")")"
if is_block "$RES_7"; then pass "B7. gh pr merge + uv missing → block (fail-safe)"
else fail "B7. expected block, got: $RES_7"; fi

# 8. gh pr merge + no session state at all → block
SID_8="b8-$$"
RES_8="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_8" "$REPO_A")")"
if is_block "$RES_8"; then pass "B8. gh pr merge + no state → block (fail-safe)"
else fail "B8. expected block, got: $RES_8"; fi

# 9. git push origin main + uv:skipped → block
SID_9="b9-$$"
write_state "$SID_9" "$(state_json "$SID_9" "main" "skipped" "complete")"
RES_9="$(run_gate "$REPO_A" "$(build_gate_json 'git push origin main' "$SID_9" "$REPO_A")")"
if is_block "$RES_9"; then pass "B9. git push origin main + uv:skipped → block"
else fail "B9. expected block (skipped != complete), got: $RES_9"; fi

# 10. git push --all origin + uv:pending → block
SID_10="b10-$$"
write_state "$SID_10" "$(state_json "$SID_10" "main" "pending" "complete")"
RES_10="$(run_gate "$REPO_A" "$(build_gate_json 'git push --all origin' "$SID_10" "$REPO_A")")"
if is_block "$RES_10"; then pass "B10. git push --all + uv:pending → block"
else fail "B10. expected block, got: $RES_10"; fi

# 11. git --no-pager push origin main + uv:pending → block
SID_11="b11-$$"
write_state "$SID_11" "$(state_json "$SID_11" "main" "pending" "complete")"
RES_11="$(run_gate "$REPO_A" "$(build_gate_json 'git --no-pager push origin main' "$SID_11" "$REPO_A")")"
if is_block "$RES_11"; then pass "B11. git --no-pager push origin main + uv:pending → block"
else fail "B11. expected block, got: $RES_11"; fi

# 12. git push --mirror origin + uv:pending → block
SID_12="b12-$$"
write_state "$SID_12" "$(state_json "$SID_12" "main" "pending" "complete")"
RES_12="$(run_gate "$REPO_A" "$(build_gate_json 'git push --mirror origin' "$SID_12" "$REPO_A")")"
if is_block "$RES_12"; then pass "B12. git push --mirror + uv:pending → block"
else fail "B12. expected block, got: $RES_12"; fi

# 13. ENFORCE_WORKTREE=off + gh pr merge + uv:pending → block (merge gate is unconditional)
SID_13="b13-$$"
write_state "$SID_13" "$(state_json "$SID_13" "main" "pending" "complete")"
RES_13="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_13" "$REPO_A")" ENFORCE_WORKTREE=off)"
if is_block "$RES_13"; then pass "B13. ENFORCE_WORKTREE=off + gh pr merge + uv:pending → block (unconditional)"
else fail "B13. expected block (merge gate unconditional), got: $RES_13"; fi
