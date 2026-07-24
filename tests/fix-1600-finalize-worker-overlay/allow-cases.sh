# ============================================================================
# ALLOW cases — live command shapes (RED before overlay exists)
# ============================================================================

test_allow_initial() {
    local repo; repo="$(setup_main_worktree "a-initial")"
    local acd; acd="$(setup_fake_acd "a-initial")"
    local plans; plans="$(setup_plans_dir "a-initial")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_initial "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "ALLOW initial: literal-path eval run-initial.sh → ALLOW (RED before fix)" "$rc"
}

# loop_step ALLOW — one case per valid G5 decision value (pins the full enum).
test_allow_loop_step_enum() {
    local decision="$1"
    local repo; repo="$(setup_main_worktree "a-loop-$decision")"
    local acd; acd="$(setup_fake_acd "a-loop-$decision")"
    local plans; plans="$(setup_plans_dir "a-loop-$decision")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_loop_step "$acd" "$scripts" "$scripts" "$statefile" "$decision")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "ALLOW loop_step: decision=$decision → ALLOW (RED before fix)" "$rc"
}

test_allow_finalize_terminal() {
    # #1590 regression pin — resolved by this overlay.
    local repo; repo="$(setup_main_worktree "a-term")"
    local acd; acd="$(setup_fake_acd "a-term")"
    local plans; plans="$(setup_plans_dir "a-term")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local outcome="$plans/sid-issue-close-outcome.json"
    local cmd; cmd="$(build_finalize_terminal "$acd" "$scripts" "$statefile" "sid" "$outcome")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "ALLOW finalize_terminal: literal-path eval → ALLOW (#1590 regression pin)" "$rc"
}

# ============================================================================
# ALLOW case — env-var prefix order must not be semantically significant.
# ============================================================================

test_allow_initial_env_order_swapped() {
    local repo; repo="$(setup_main_worktree "a-envorder")"
    local acd; acd="$(setup_fake_acd "a-envorder")"
    local plans; plans="$(setup_plans_dir "a-envorder")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # Same KEY=VALUE set as build_initial but reordered (MWT/FSD/ACD instead of
    # ACD/FSD/MWT) — a KEY=VALUE env prefix's order is not semantically significant.
    local cmd
    cmd="$(printf 'eval "$(MAIN_WORKTREE_PATH="%s" FINALIZE_SCRIPTS_DIR="%s" AGENTS_CONFIG_DIR="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$repo" "$scripts" "$acd" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "ALLOW initial: env-var prefix order swapped (MWT/FSD/ACD) → ALLOW (RED before fix)" "$rc"
}
