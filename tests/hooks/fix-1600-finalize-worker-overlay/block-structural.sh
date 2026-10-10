# ============================================================================
# BLOCK cases — structural (mirror fix-1484 pins)
# ============================================================================

# step-g5-loop.sh is a SANCTIONED registry entry marked matchable:false — no
# live command shape should ever match it. Any invocation attempt (even one
# shaped like a valid overlay entry) must BLOCK (#1600 review gap).
test_block_g5_loop_live_shape() {
    local repo; repo="$(setup_main_worktree "b-g5live")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-g5live")"
    local plans; plans="$(setup_plans_dir "b-g5live")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/step-g5-loop.sh" "1234" "1234" "")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK matchable:false: step-g5-loop.sh live-shaped invocation → BLOCK" "$rc"
}

test_block_dangerous_tail() {
    local repo; repo="$(setup_main_worktree "b-tail")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-tail")"
    local plans; plans="$(setup_plans_dir "b-tail")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_initial "$script_checkout_root" "$scripts" "$repo" "$scripts") || rm -rf /"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK structural: overlay shape + || rm -rf / tail → BLOCK" "$rc"
}

test_block_cmd_subst_arg() {
    local repo; repo="$(setup_main_worktree "b-subst")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-subst")"
    local plans; plans="$(setup_plans_dir "b-subst")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # $(id) command substitution injected into an argument.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "$(id)" "")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK structural: \$(...) command substitution in argument → BLOCK" "$rc"
}

test_block_interp_mismatch_node_on_bash() {
    local repo; repo="$(setup_main_worktree "b-nodebash")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-nodebash")"
    local plans; plans="$(setup_plans_dir "b-nodebash")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # node interpreter on run-initial.sh (a bash script).
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" node "%s/run-initial.sh" "1234" "1234" "")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK structural: node on run-initial.sh (bash script) → BLOCK" "$rc"
}

test_block_interp_mismatch_bash_on_node() {
    local repo; repo="$(setup_main_worktree "b-bashnode")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-bashnode")"
    local plans; plans="$(setup_plans_dir "b-bashnode")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    # bash interpreter on run-loop-step.js (a node script).
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" bash "%s/run-loop-step.js" "%s" "accept")"' \
        "$script_checkout_root" "$scripts" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK structural: bash on run-loop-step.js (node script) → BLOCK" "$rc"
}

test_block_multiline() {
    local repo; repo="$(setup_main_worktree "b-multiline")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-multiline")"
    local plans; plans="$(setup_plans_dir "b-multiline")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # Backslash-continuation multi-line form (single-line-only contract).
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" \\\n  FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK structural: multi-line backslash-continuation initial → BLOCK" "$rc"
}
