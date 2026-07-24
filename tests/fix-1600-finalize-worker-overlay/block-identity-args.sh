# ============================================================================
# BLOCK cases — identity / env attacks (C1)
# ============================================================================

test_block_acd_env_mismatch() {
    local repo; repo="$(setup_main_worktree "b-acd")"
    local acd; acd="$(setup_fake_acd "b-acd")"
    local plans; plans="$(setup_plans_dir "b-acd")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # Inline env VALUE /evil differs from process.env AGENTS_CONFIG_DIR.
    local cmd; cmd="$(build_initial "/evil" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: AGENTS_CONFIG_DIR env VALUE mismatch (/evil) → BLOCK" "$rc"
}

test_block_variable_script_path() {
    local repo; repo="$(setup_main_worktree "b-varpath")"
    local acd; acd="$(setup_fake_acd "b-varpath")"
    local plans; plans="$(setup_plans_dir "b-varpath")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # Script path uses the literal $AGENTS_CONFIG_DIR variable, not a resolved literal.
    local cmd; cmd="$(build_initial "$acd" "$scripts" "$repo" "\$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: variable \$AGENTS_CONFIG_DIR script path (not literal) → BLOCK" "$rc"
}

test_block_fsd_env_mismatch() {
    local repo; repo="$(setup_main_worktree "b-fsd")"
    local acd; acd="$(setup_fake_acd "b-fsd")"
    local plans; plans="$(setup_plans_dir "b-fsd")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_loop_step "$acd" "/evil" "$scripts" "$statefile" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: FINALIZE_SCRIPTS_DIR env VALUE mismatch (/evil) on loop_step → BLOCK" "$rc"
}

test_block_mwt_env_mismatch() {
    local repo; repo="$(setup_main_worktree "b-mwt")"
    local acd; acd="$(setup_fake_acd "b-mwt")"
    local plans; plans="$(setup_plans_dir "b-mwt")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_initial "$acd" "$scripts" "/evil" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: MAIN_WORKTREE_PATH env VALUE mismatch (/evil) → BLOCK" "$rc"
}

test_block_extra_env_key() {
    local repo; repo="$(setup_main_worktree "b-extraenv")"
    local acd; acd="$(setup_fake_acd "b-extraenv")"
    local plans; plans="$(setup_plans_dir "b-extraenv")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # Otherwise-valid initial shape with an extra unexpected env key EVIL="x".
    local cmd
    cmd="$(printf 'eval "$(EVIL="x" AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: extra unexpected env key EVIL=x → BLOCK" "$rc"
}

test_block_missing_fsd_env() {
    local repo; repo="$(setup_main_worktree "b-nofsd")"
    local acd; acd="$(setup_fake_acd "b-nofsd")"
    local plans; plans="$(setup_plans_dir "b-nofsd")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # initial shape with FINALIZE_SCRIPTS_DIR omitted entirely.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$acd" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: initial with FINALIZE_SCRIPTS_DIR env omitted → BLOCK" "$rc"
}

# ============================================================================
# BLOCK cases — argument attacks (C3)
# ============================================================================

test_block_loop_extra_arg() {
    local repo; repo="$(setup_main_worktree "b-3arg")"
    local acd; acd="$(setup_fake_acd "b-3arg")"
    local plans; plans="$(setup_plans_dir "b-3arg")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    # 3 args: state + decision + extra trailing arg.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "accept" "extra")"' \
        "$acd" "$scripts" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step with 3 args (extra trailing) → BLOCK" "$rc"
}

test_block_loop_missing_decision() {
    local repo; repo="$(setup_main_worktree "b-1arg")"
    local acd; acd="$(setup_fake_acd "b-1arg")"
    local plans; plans="$(setup_plans_dir "b-1arg")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    # 1 arg: decision missing.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s")"' \
        "$acd" "$scripts" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step with only 1 arg (decision missing) → BLOCK" "$rc"
}

test_block_loop_state_outside_plans() {
    local repo; repo="$(setup_main_worktree "b-statepath")"
    local acd; acd="$(setup_fake_acd "b-statepath")"
    local plans; plans="$(setup_plans_dir "b-statepath")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_loop_step "$acd" "$scripts" "$scripts" "/evil/state.json" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step state path outside plans dir → BLOCK" "$rc"
}

test_block_terminal_outcome_outside_plans() {
    local repo; repo="$(setup_main_worktree "b-outcome")"
    local acd; acd="$(setup_fake_acd "b-outcome")"
    local plans; plans="$(setup_plans_dir "b-outcome")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_finalize_terminal "$acd" "$scripts" "$statefile" "sid" "/evil/outcome.json")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: finalize_terminal outcome path outside plans dir → BLOCK" "$rc"
}

# Path-prefix-bypass and traversal BLOCK cases — catches a naive string-prefix
# containment check instead of proper path containment (#1600 review gap).
test_block_loop_state_sibling_prefix_bypass() {
    local repo; repo="$(setup_main_worktree "b-statepfx")"
    local acd; acd="$(setup_fake_acd "b-statepfx")"
    local plans; plans="$(setup_plans_dir "b-statepfx")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # Sibling directory whose name starts with the plans-dir string but is a
    # different directory — catches naive string-prefix containment checks.
    local cmd; cmd="$(build_loop_step "$acd" "$scripts" "$scripts" "${plans}-evil/state.json" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step state path sibling-prefix bypass (\$plans-evil) → BLOCK" "$rc"
}

test_block_loop_state_path_traversal() {
    local repo; repo="$(setup_main_worktree "b-statetrav")"
    local acd; acd="$(setup_fake_acd "b-statetrav")"
    local plans; plans="$(setup_plans_dir "b-statetrav")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_loop_step "$acd" "$scripts" "$scripts" "$plans/../evil/state.json" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step state path traversal (\$plans/../evil) → BLOCK" "$rc"
}

test_block_terminal_outcome_sibling_prefix_bypass() {
    local repo; repo="$(setup_main_worktree "b-outpfx")"
    local acd; acd="$(setup_fake_acd "b-outpfx")"
    local plans; plans="$(setup_plans_dir "b-outpfx")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_finalize_terminal "$acd" "$scripts" "$statefile" "sid" "${plans}-evil/outcome.json")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: finalize_terminal outcome path sibling-prefix bypass (\$plans-evil) → BLOCK" "$rc"
}

test_block_terminal_outcome_path_traversal() {
    local repo; repo="$(setup_main_worktree "b-outtrav")"
    local acd; acd="$(setup_fake_acd "b-outtrav")"
    local plans; plans="$(setup_plans_dir "b-outtrav")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_finalize_terminal "$acd" "$scripts" "$statefile" "sid" "$plans/../evil/outcome.json")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: finalize_terminal outcome path traversal (\$plans/../evil) → BLOCK" "$rc"
}

# loop_step decision-value attacks (each near-miss must be rejected).
test_block_loop_bad_decision() {
    local decision="$1" label="$2"
    local repo; repo="$(setup_main_worktree "b-dec-$label")"
    local acd; acd="$(setup_fake_acd "b-dec-$label")"
    local plans; plans="$(setup_plans_dir "b-dec-$label")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_loop_step "$acd" "$scripts" "$scripts" "$statefile" "$decision")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step decision '$decision' (not in allow-list) → BLOCK" "$rc"
}

# Arg-count violations for the other two live shapes (symmetric to loop_step's
# extra-arg/missing-arg pair above — #1600 review gap).
test_block_initial_extra_arg() {
    local repo; repo="$(setup_main_worktree "b-init4arg")"
    local acd; acd="$(setup_fake_acd "b-init4arg")"
    local plans; plans="$(setup_plans_dir "b-init4arg")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "" "extra")"' \
        "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-initial.sh with 4 args (extra trailing) → BLOCK" "$rc"
}

test_block_initial_missing_arg() {
    local repo; repo="$(setup_main_worktree "b-init2arg")"
    local acd; acd="$(setup_fake_acd "b-init2arg")"
    local plans; plans="$(setup_plans_dir "b-init2arg")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234")"' \
        "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-initial.sh with 2 args (missing 3rd) → BLOCK" "$rc"
}

test_block_finalize_terminal_extra_arg() {
    local repo; repo="$(setup_main_worktree "b-term4arg")"
    local acd; acd="$(setup_fake_acd "b-term4arg")"
    local plans; plans="$(setup_plans_dir "b-term4arg")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local outcome="$plans/sid-issue-close-outcome.json"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-finalize-terminal.sh" "%s" "sid" "%s" "extra")"' \
        "$acd" "$scripts" "$statefile" "$outcome")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-finalize-terminal.sh with 4 args (extra trailing) → BLOCK" "$rc"
}

test_block_finalize_terminal_missing_arg() {
    local repo; repo="$(setup_main_worktree "b-term2arg")"
    local acd; acd="$(setup_fake_acd "b-term2arg")"
    local plans; plans="$(setup_plans_dir "b-term2arg")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-finalize-terminal.sh" "%s" "sid")"' \
        "$acd" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-finalize-terminal.sh with 2 args (missing outcome) → BLOCK" "$rc"
}
