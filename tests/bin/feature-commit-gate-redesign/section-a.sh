#!/bin/bash
# tests/bin/feature-commit-gate-redesign/section-a.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Section A: merge gate (normal). Creates REPO_A, which section-b.sh and section-c.sh reuse.

echo "=== Section A: Merge gate (normal) ==="

REPO_A="$(setup_main_checkout "secA-repo")"

# 1. gh pr merge --squash + uv:complete → approve
SID_1="a1-$$"
write_state "$SID_1" "$(state_json "$SID_1" "main" "complete" "complete")"
RES_1="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_1" "$REPO_A")")"
if is_approve "$RES_1"; then pass "A1. gh pr merge + uv:complete → approve"
else fail "A1. expected approve, got: $RES_1"; fi

# 2. git push origin main + uv:complete → approve
SID_2="a2-$$"
write_state "$SID_2" "$(state_json "$SID_2" "main" "complete" "complete")"
RES_2="$(run_gate "$REPO_A" "$(build_gate_json 'git push origin main' "$SID_2" "$REPO_A")")"
if is_approve "$RES_2"; then pass "A2. git push origin main + uv:complete → approve"
else fail "A2. expected approve, got: $RES_2"; fi

# 3. git push origin feature/foo + uv:pending → approve (not protected)
SID_3="a3-$$"
write_state "$SID_3" "$(state_json "$SID_3" "main" "pending" "complete")"
RES_3="$(run_gate "$REPO_A" "$(build_gate_json 'git push origin feature/foo' "$SID_3" "$REPO_A")")"
if is_approve "$RES_3"; then pass "A3. git push feature/foo + uv:pending → approve (not protected)"
else fail "A3. expected approve (feature push not protected), got: $RES_3"; fi

# 4. git commit in linked worktree + uv:pending, all others complete → approve (uv skipped in worktree)
PAIR_4="$(setup_linked_worktree "secA-wt4")"
WT_4="${PAIR_4#*|}"
SID_4="a4-$$"
write_state "$SID_4" "$(state_json "$SID_4" "feature/secA-wt4" "pending" "complete")"
RES_4="$(run_gate "$WT_4" "$(build_gate_json 'git commit -m x' "$SID_4" "$WT_4")")"
if is_approve "$RES_4"; then pass "A4. git commit in worktree + uv:pending → approve (uv skipped)"
else fail "A4. expected approve (worktree uv-skip), got: $RES_4"; fi

# 5. git commit in main worktree + uv:pending → block
SID_5="a5-$$"
write_state "$SID_5" "$(state_json "$SID_5" "main" "pending" "complete")"
RES_5="$(run_gate "$REPO_A" "$(build_gate_json 'git commit -m x' "$SID_5" "$REPO_A")")"
if is_block "$RES_5"; then pass "A5. git commit in main worktree + uv:pending → block"
else fail "A5. expected block, got: $RES_5"; fi

# 6. gh pr merge + uv:pending → block, output mentions WORKFLOW_USER_VERIFIED
SID_6="a6-$$"
write_state "$SID_6" "$(state_json "$SID_6" "main" "pending" "complete")"
RES_6="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_6" "$REPO_A")")"
if is_block "$RES_6" && echo "$RES_6" | grep -q "WORKFLOW_USER_VERIFIED"; then
    pass "A6. gh pr merge + uv:pending → block w/ USER_VERIFIED hint"
else
    fail "A6. expected block+USER_VERIFIED hint, got: $RES_6"
fi
