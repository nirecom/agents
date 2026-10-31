#!/bin/bash
# tests/bin/feature-commit-gate-redesign/section-f.sh — sourced by feature-commit-gate-redesign.sh; NOT a test file.
# Section F: WIP commit skips user_verification (12).

# True when the gate output is a block whose incomplete-steps list names STEP and
# the glossary-check-missing gate did not fire (so the case cannot pass through it).
is_block_on_step() {
    local res="$1" step="$2"
    is_block "$res" || return 1
    echo "$res" | grep -q "not complete: [a-z_, ]*$step" || return 1
    ! echo "$res" | grep -q 'glossary-check-missing'
}

# Adds workflow_init:complete to a fixture state JSON. Without it the gate reads the
# session as "workflow not begun" and approves before any step is judged (and the
# glossary record's state rewrite leaves workflow_init pending).
with_workflow_init() {
    echo "$1" | sed "s/\"clarify_intent\":/\"workflow_init\": {\"status\": \"complete\", \"updated_at\": \"$NOW_ISO\"}, \"clarify_intent\":/"
}

test_wip_commit_skips_user_verification() {
    echo ""
    echo "=== Section F: WIP commit skips user_verification ==="

    local REPO_F; REPO_F="$(setup_main_checkout "secF-repo")"
    # Seed a non-docs staged file so resolveRepoDir() short-circuits on the test
    # repo instead of falling through to the session's additionalDirectories
    # (which would otherwise pick up an unrelated worktree's staged tests/).
    echo seed > "$REPO_F/sentinel.txt"
    git -C "$REPO_F" add sentinel.txt

    # --- Positive (approve) — 4 cases ---

    # F1. git -c workflow.wip=1 commit + uv:pending, others complete → approve
    local SID_F1="f1-$$"
    write_state "$SID_F1" "$(state_json "$SID_F1" "main" "pending" "complete")"
    glossary_check_record "$SID_F1" "$REPO_F"
    local RES_F1
    RES_F1="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=1 commit -m "wip"' "$SID_F1" "$REPO_F")")"
    if is_approve "$RES_F1"; then
        pass "F1. git -c workflow.wip=1 commit + uv:pending → approve"
    else
        fail "F1. expected approve, got: $RES_F1"
    fi

    # F2. workflow.wip=true → approve
    local SID_F2="f2-$$"
    write_state "$SID_F2" "$(state_json "$SID_F2" "main" "pending" "complete")"
    glossary_check_record "$SID_F2" "$REPO_F"
    local RES_F2
    RES_F2="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=true commit -m "wip"' "$SID_F2" "$REPO_F")")"
    if is_approve "$RES_F2"; then
        pass "F2. workflow.wip=true → approve"
    else
        fail "F2. expected approve, got: $RES_F2"
    fi

    # F3. -c workflow.wip=1 + -C "/some/path" → approve (flag ordering)
    local SID_F3="f3-$$"
    write_state "$SID_F3" "$(state_json "$SID_F3" "main" "pending" "complete")"
    glossary_check_record "$SID_F3" "$REPO_F"
    local RES_F3
    RES_F3="$(run_gate "$REPO_F" "$(build_gate_json "git -c workflow.wip=1 -C \"$REPO_F\" commit -m \"wip\"" "$SID_F3" "$REPO_F")")"
    if is_approve "$RES_F3"; then
        pass "F3. flag ordering (-c then -C) → approve"
    else
        fail "F3. expected approve, got: $RES_F3"
    fi

    # F4. -c "workflow.wip=1" (quoted) → approve
    local SID_F4="f4-$$"
    write_state "$SID_F4" "$(state_json "$SID_F4" "main" "pending" "complete")"
    glossary_check_record "$SID_F4" "$REPO_F"
    local RES_F4
    RES_F4="$(run_gate "$REPO_F" "$(build_gate_json 'git -c "workflow.wip=1" commit -m "wip"' "$SID_F4" "$REPO_F")")"
    if is_approve "$RES_F4"; then
        pass "F4. quoted -c \"workflow.wip=1\" → approve"
    else
        fail "F4. expected approve, got: $RES_F4"
    fi

    # --- Negative (block) — 7 cases ---

    # F5. workflow.wip=0 → block (zero does not skip)
    local SID_F5="f5-$$"
    write_state "$SID_F5" "$(with_workflow_init "$(state_json "$SID_F5" "main" "pending" "complete")")"
    glossary_check_record "$SID_F5" "$REPO_F"
    local RES_F5
    RES_F5="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=0 commit -m "wip"' "$SID_F5" "$REPO_F")")"
    if is_block_on_step "$RES_F5" "user_verification"; then
        pass "F5. workflow.wip=0 → block (zero ≠ skip)"
    else
        fail "F5. expected block, got: $RES_F5"
    fi

    # F6. wip=1 + run_tests:pending, uv:complete, others complete → block on run_tests
    local SID_F6="f6-$$"
    write_state "$SID_F6" "$(with_workflow_init "$(state_json_custom "$SID_F6" "main" \
        run_tests pending user_verification complete)")"
    glossary_check_record "$SID_F6" "$REPO_F"
    local RES_F6
    RES_F6="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=1 commit -m "wip"' "$SID_F6" "$REPO_F")")"
    if is_block_on_step "$RES_F6" "run_tests"; then
        pass "F6. wip=1 + run_tests:pending → block (run_tests not skipped)"
    else
        fail "F6. expected block, got: $RES_F6"
    fi

    # F7. wip=1 + review_security:pending → block on review_security
    local SID_F7="f7-$$"
    write_state "$SID_F7" "$(with_workflow_init "$(state_json_custom "$SID_F7" "main" \
        review_security pending user_verification complete)")"
    glossary_check_record "$SID_F7" "$REPO_F"
    local RES_F7
    RES_F7="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=1 commit -m "wip"' "$SID_F7" "$REPO_F")")"
    if is_block_on_step "$RES_F7" "review_security"; then
        pass "F7. wip=1 + review_security:pending → block (review_security not skipped)"
    else
        fail "F7. expected block, got: $RES_F7"
    fi

    # F8. wip=1 + docs:pending → block on docs
    local SID_F8="f8-$$"
    write_state "$SID_F8" "$(with_workflow_init "$(state_json_custom "$SID_F8" "main" \
        docs pending user_verification complete)")"
    glossary_check_record "$SID_F8" "$REPO_F"
    local RES_F8
    RES_F8="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=1 commit -m "wip"' "$SID_F8" "$REPO_F")")"
    if is_block_on_step "$RES_F8" "docs"; then
        pass "F8. wip=1 + docs:pending → block (docs not skipped)"
    else
        fail "F8. expected block, got: $RES_F8"
    fi

    # F9. irrelevant -c key → block
    local SID_F9="f9-$$"
    write_state "$SID_F9" "$(with_workflow_init "$(state_json "$SID_F9" "main" "pending" "complete")")"
    glossary_check_record "$SID_F9" "$REPO_F"
    local RES_F9
    RES_F9="$(run_gate "$REPO_F" "$(build_gate_json 'git -c somethingelse=1 commit -m "wip"' "$SID_F9" "$REPO_F")")"
    if is_block_on_step "$RES_F9" "user_verification"; then
        pass "F9. irrelevant -c key → block"
    else
        fail "F9. expected block, got: $RES_F9"
    fi

    # F10. flag-string in commit message body, not a real flag → block
    local SID_F10="f10-$$"
    write_state "$SID_F10" "$(with_workflow_init "$(state_json "$SID_F10" "main" "pending" "complete")")"
    glossary_check_record "$SID_F10" "$REPO_F"
    local RES_F10
    RES_F10="$(run_gate "$REPO_F" "$(build_gate_json 'git commit -m "git -c workflow.wip=1"' "$SID_F10" "$REPO_F")")"
    if is_block_on_step "$RES_F10" "user_verification"; then
        pass "F10. flag-string in commit message → block (not a flag)"
    else
        fail "F10. expected block, got: $RES_F10"
    fi

    # F11. -c after `commit` subcommand → block (post-subcommand position not recognized by git)
    local SID_F11="f11-$$"
    write_state "$SID_F11" "$(with_workflow_init "$(state_json "$SID_F11" "main" "pending" "complete")")"
    glossary_check_record "$SID_F11" "$REPO_F"
    local RES_F11
    RES_F11="$(run_gate "$REPO_F" "$(build_gate_json 'git commit -c workflow.wip=1 -m "wip"' "$SID_F11" "$REPO_F")")"
    if is_block_on_step "$RES_F11" "user_verification"; then
        pass "F11. -c after commit subcommand → block (post-subcommand)"
    else
        fail "F11. expected block, got: $RES_F11"
    fi

    # --- Idempotency — 1 case ---

    # F12. After WIP approve, state file uv must still be pending (gate must not write state)
    local SID_F12="f12-$$"
    write_state "$SID_F12" "$(state_json "$SID_F12" "main" "pending" "complete")"
    glossary_check_record "$SID_F12" "$REPO_F"
    local RES_F12
    RES_F12="$(run_gate "$REPO_F" "$(build_gate_json 'git -c workflow.wip=1 commit -m "wip"' "$SID_F12" "$REPO_F")")"
    local UV_F12
    UV_F12="$(read_state_step "$SID_F12" "user_verification")"
    if is_approve "$RES_F12" && [ "$UV_F12" = "pending" ]; then
        pass "F12. WIP approve does not mutate state (uv stays pending)"
    else
        fail "F12. expected approve+uv=pending, got approve=$(is_approve "$RES_F12" && echo y || echo n) uv=$UV_F12 res=$RES_F12"
    fi
}

test_wip_commit_skips_user_verification
