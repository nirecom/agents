#!/bin/bash
# tests/bin/feature-commit-gate-redesign/section-c.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Section C: merge gate (edge). Reuses REPO_A from section-a.sh.

echo ""
echo "=== Section C: Merge gate (edge) ==="

# 14. Detached HEAD in worktree + git commit + uv:pending → block
PAIR_14="$(setup_linked_worktree "secC-wt14")"
WT_14="${PAIR_14#*|}"
SHA_14="$(git -C "$WT_14" rev-parse HEAD)"
git -C "$WT_14" checkout -q "$SHA_14"
SID_14="c14-$$"
write_state "$SID_14" "$(state_json "$SID_14" "null" "pending" "complete")"
RES_14="$(run_gate "$WT_14" "$(build_gate_json 'git commit -m x' "$SID_14" "$WT_14")")"
if is_block "$RES_14"; then pass "C14. detached HEAD in worktree + uv:pending → block"
else fail "C14. expected block (detached HEAD is not feature-branch worktree context), got: $RES_14"; fi

# 15. Linked worktree on protected branch (e.g. main) + git commit + uv:pending → block
# git prevents two worktrees sharing the same branch. Switch the primary to 'develop'
# first so 'main' is free to be checked out in the linked worktree.
MAIN_15="$(setup_main_checkout "secC-15-main")"
git -C "$MAIN_15" checkout -q -b develop
WT_15="$TMPDIR_BASE/secC-15-wt"
git -C "$MAIN_15" worktree add -q "$WT_15" main
SID_15="c15-$$"
write_state "$SID_15" "$(state_json "$SID_15" "main" "pending" "complete")"
RES_15="$(run_gate "$WT_15" "$(build_gate_json 'git commit -m x' "$SID_15" "$WT_15")")"
if is_block "$RES_15"; then pass "C15. worktree on protected branch + uv:pending → block (only feature branches skip)"
else fail "C15. expected block (worktree on protected), got: $RES_15"; fi

# 16. git commit in worktree + uv:pending, docs:pending → block on docs (uv-skip independent)
PAIR_16="$(setup_linked_worktree "secC-wt16")"
WT_16="${PAIR_16#*|}"
SID_16="c16-$$"
write_state "$SID_16" "$(state_json_custom "$SID_16" "feature/secC-wt16" \
    docs pending user_verification pending)"
RES_16="$(run_gate "$WT_16" "$(build_gate_json 'git commit -m x' "$SID_16" "$WT_16")")"
if is_block "$RES_16" && echo "$RES_16" | grep -qi "docs"; then
    pass "C16. worktree commit + docs:pending → block on docs (uv-skip independent)"
else
    fail "C16. expected block-on-docs, got: $RES_16"
fi

# 17. Idempotency: gh pr merge + uv:pending twice → both block, state unchanged
SID_17="c17-$$"
write_state "$SID_17" "$(state_json "$SID_17" "main" "pending" "complete")"
SNAPSHOT_17_BEFORE="$(cat "$WORKFLOW_DIR/${SID_17}.json")"
RES_17A="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_17" "$REPO_A")")"
RES_17B="$(run_gate "$REPO_A" "$(build_gate_json 'gh pr merge --squash' "$SID_17" "$REPO_A")")"
SNAPSHOT_17_AFTER="$(cat "$WORKFLOW_DIR/${SID_17}.json")"
if is_block "$RES_17A" && is_block "$RES_17B" && [ "$SNAPSHOT_17_BEFORE" = "$SNAPSHOT_17_AFTER" ]; then
    pass "C17. gh pr merge x2 → both block; state unchanged (idempotent)"
else
    fail "C17. idempotency: a=$RES_17A b=$RES_17B state-equal=$([ "$SNAPSHOT_17_BEFORE" = "$SNAPSHOT_17_AFTER" ] && echo yes || echo no)"
fi

# 17b. Positive: payload cwd = linked worktree, CLAUDE_PROJECT_DIR = main → Tier 3 wins
PAIR_17B="$(setup_linked_worktree "secC-wt17b")"
MAIN_17B="${PAIR_17B%|*}"
WT_17B="${PAIR_17B#*|}"
echo "x" > "$WT_17B/file.txt"
git -C "$WT_17B" add file.txt
SID_17B="c17b-$$"
write_state "$SID_17B" "$(state_json "$SID_17B" "feature/secC-wt17b-main" "pending" "complete")"
glossary_check_record "$SID_17B" "$WT_17B"
RES_17B="$(run_gate "$MAIN_17B" "$(build_gate_json 'git commit -m x' "$SID_17B" "$WT_17B")")"
if is_approve "$RES_17B"; then pass "C17b. payload cwd = linked worktree → resolves to worktree, uv skipped"
else fail "C17b. expected approve (worktree gate), got: $RES_17B"; fi

# 17c. Negative: payload cwd = main checkout → Tier 3 falls through, Tier 4 wins
PRIMARY_17C="$(setup_main_checkout "secC-17c-primary")"
PAYLOAD_17C="$(setup_main_checkout "secC-17c-payload")"
echo "src" > "$PRIMARY_17C/src.txt"
mkdir -p "$PRIMARY_17C/tests"
echo "t" > "$PRIMARY_17C/tests/t.sh"
git -C "$PRIMARY_17C" add src.txt tests/t.sh
SID_17C="c17c-$$"
write_state "$SID_17C" "$(state_json_custom "$SID_17C" "main" \
    write_tests pending user_verification complete)"
glossary_check_record "$SID_17C" "$PRIMARY_17C"
RES_17C="$(run_gate "$PRIMARY_17C" "$(build_gate_json 'git commit -m x' "$SID_17C" "$PAYLOAD_17C")")"
if is_approve "$RES_17C"; then
    pass "C17c. payload cwd = main checkout → falls through, primary staged-change search wins"
else
    fail "C17c. expected approve (payload cwd should NOT override primary), got: $RES_17C"
fi

# 17d. (#2529 T6-8) C17b without glossary_check_record: the same staged code file and
# complete review_security block on the missing glossary record.
PAIR_17D="$(setup_linked_worktree "secC-wt17d")"
MAIN_17D="${PAIR_17D%|*}"
WT_17D="${PAIR_17D#*|}"
echo "x" > "$WT_17D/file.txt"
git -C "$WT_17D" add file.txt
SID_17D="c17d-$$"
write_state "$SID_17D" "$(state_json "$SID_17D" "feature/secC-wt17d-main" "pending" "complete")"
RES_17D="$(run_gate "$MAIN_17D" "$(build_gate_json 'git commit -m x' "$SID_17D" "$WT_17D")")"
if is_block "$RES_17D" && echo "$RES_17D" | grep -q 'glossary-check-missing'; then
    pass "C17d. C17b without the glossary record → block glossary-check-missing"
else
    fail "C17d. expected block naming glossary-check-missing, got: $RES_17D"
fi
