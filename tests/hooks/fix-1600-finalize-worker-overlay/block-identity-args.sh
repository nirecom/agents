# tests/hooks/fix-1600-finalize-worker-overlay/block-identity-args.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, overlay, security, scope:issue-specific
#
# Sourced by tests/hooks/fix-1600-finalize-worker-overlay.sh.
#
# ============================================================================
# BLOCK cases — identity / env attacks (C1)
# ============================================================================

test_block_script_checkout_root_env_mismatch() {
    local repo; repo="$(setup_main_worktree "b-script-checkout-root")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-script-checkout-root")"
    local plans; plans="$(setup_plans_dir "b-script-checkout-root")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # Inline env VALUE /evil differs from process.env AGENTS_MAIN_ROOT.
    local cmd; cmd="$(build_initial "/evil" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: AGENTS_MAIN_ROOT env VALUE mismatch (/evil) → BLOCK" "$rc"
}

test_block_variable_script_path() {
    local repo; repo="$(setup_main_worktree "b-varpath")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-varpath")"
    local plans; plans="$(setup_plans_dir "b-varpath")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # Script path uses the literal $AGENTS_MAIN_ROOT variable, not a resolved literal.
    local cmd; cmd="$(build_initial "$script_checkout_root" "$scripts" "$repo" "\$AGENTS_MAIN_ROOT/skills/issue-close-finalize/scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    # #1679 (S-7/G1): FLIPPED from BLOCK to ALLOW. PreToolUse sees the command
    # BEFORE shell expansion, so $AGENTS_MAIN_ROOT legitimately arrives as a
    # literal prefix — worker-script.js's legacy eval path already normalizes
    # exactly this prefix (#1484), and the overlay's blanket [$`~] reject made the
    # two paths disagree. Only the AGENTS_MAIN_ROOT-PREFIX form is admitted, and
    # only when it resolves to the marker-validated script checkout root; every other variable form
    # stays blocked, pinned in tests/hooks/fix-1679-finalize-overlay-arg-contract.sh by
    # BK1679-7a (different variable), BK1679-7b (mid-path, not prefix),
    # BK1679-7c (env unset / pointing elsewhere) and BK1679-7e (~ expansion).
    # The function name is left as-is because its caller (run_all in
    # tests/hooks/fix-1600-finalize-worker-overlay.sh) is out of scope for this change.
    assert_block "BLOCK C1 (#1679): \$AGENTS_MAIN_ROOT literal prefix script path — eval path retired (#1673)" "$rc"
}

test_block_fsd_env_mismatch() {
    local repo; repo="$(setup_main_worktree "b-fsd")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-fsd")"
    local plans; plans="$(setup_plans_dir "b-fsd")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_loop_step "$script_checkout_root" "/evil" "$scripts" "$statefile" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: FINALIZE_SCRIPTS_DIR env VALUE mismatch (/evil) on loop_step → BLOCK" "$rc"
}

test_block_mwt_env_mismatch() {
    local repo; repo="$(setup_main_worktree "b-mwt")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-mwt")"
    local plans; plans="$(setup_plans_dir "b-mwt")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_initial "$script_checkout_root" "$scripts" "/evil" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: TARGET_MAIN_ROOT env VALUE mismatch (/evil) → BLOCK" "$rc"
}

test_block_extra_env_key() {
    local repo; repo="$(setup_main_worktree "b-extraenv")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-extraenv")"
    local plans; plans="$(setup_plans_dir "b-extraenv")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # Otherwise-valid initial shape with an extra unexpected env key EVIL="x".
    local cmd
    cmd="$(printf 'eval "$(EVIL="x" AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: extra unexpected env key EVIL=x → BLOCK" "$rc"
}

test_block_missing_fsd_env() {
    local repo; repo="$(setup_main_worktree "b-nofsd")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-nofsd")"
    local plans; plans="$(setup_plans_dir "b-nofsd")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # initial shape with FINALIZE_SCRIPTS_DIR omitted entirely.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$script_checkout_root" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C1: initial with FINALIZE_SCRIPTS_DIR env omitted → BLOCK" "$rc"
}

# ============================================================================
# BLOCK cases — argument attacks (C3)
# ============================================================================

test_block_loop_extra_arg() {
    local repo; repo="$(setup_main_worktree "b-3arg")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-3arg")"
    local plans; plans="$(setup_plans_dir "b-3arg")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    # 3 args: state + decision + extra trailing arg.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "accept" "extra")"' \
        "$script_checkout_root" "$scripts" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step with 3 args (extra trailing) → BLOCK" "$rc"
}

test_block_loop_missing_decision() {
    local repo; repo="$(setup_main_worktree "b-1arg")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-1arg")"
    local plans; plans="$(setup_plans_dir "b-1arg")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    # 1 arg: decision missing.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s")"' \
        "$script_checkout_root" "$scripts" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step with only 1 arg (decision missing) → BLOCK" "$rc"
}

test_block_loop_state_outside_plans() {
    local repo; repo="$(setup_main_worktree "b-statepath")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-statepath")"
    local plans; plans="$(setup_plans_dir "b-statepath")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_loop_step "$script_checkout_root" "$scripts" "$scripts" "/evil/state.json" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step state path outside plans dir → BLOCK" "$rc"
}

test_block_terminal_outcome_outside_plans() {
    local repo; repo="$(setup_main_worktree "b-outcome")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-outcome")"
    local plans; plans="$(setup_plans_dir "b-outcome")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_finalize_terminal "$script_checkout_root" "$scripts" "$statefile" "sid" "/evil/outcome.json")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: finalize_terminal outcome path outside plans dir → BLOCK" "$rc"
}

# Path-prefix-bypass and traversal BLOCK cases — catches a naive string-prefix
# containment check instead of proper path containment (#1600 review gap).
test_block_loop_state_sibling_prefix_bypass() {
    local repo; repo="$(setup_main_worktree "b-statepfx")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-statepfx")"
    local plans; plans="$(setup_plans_dir "b-statepfx")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    # Sibling directory whose name starts with the plans-dir string but is a
    # different directory — catches naive string-prefix containment checks.
    local cmd; cmd="$(build_loop_step "$script_checkout_root" "$scripts" "$scripts" "${plans}-evil/state.json" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step state path sibling-prefix bypass (\$plans-evil) → BLOCK" "$rc"
}

test_block_loop_state_path_traversal() {
    local repo; repo="$(setup_main_worktree "b-statetrav")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-statetrav")"
    local plans; plans="$(setup_plans_dir "b-statetrav")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_loop_step "$script_checkout_root" "$scripts" "$scripts" "$plans/../evil/state.json" "accept")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step state path traversal (\$plans/../evil) → BLOCK" "$rc"
}

test_block_terminal_outcome_sibling_prefix_bypass() {
    local repo; repo="$(setup_main_worktree "b-outpfx")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-outpfx")"
    local plans; plans="$(setup_plans_dir "b-outpfx")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_finalize_terminal "$script_checkout_root" "$scripts" "$statefile" "sid" "${plans}-evil/outcome.json")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: finalize_terminal outcome path sibling-prefix bypass (\$plans-evil) → BLOCK" "$rc"
}

test_block_terminal_outcome_path_traversal() {
    local repo; repo="$(setup_main_worktree "b-outtrav")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-outtrav")"
    local plans; plans="$(setup_plans_dir "b-outtrav")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_finalize_terminal "$script_checkout_root" "$scripts" "$statefile" "sid" "$plans/../evil/outcome.json")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: finalize_terminal outcome path traversal (\$plans/../evil) → BLOCK" "$rc"
}

# loop_step decision-value attacks (each near-miss must be rejected).
test_block_loop_bad_decision() {
    local decision="$1" label="$2"
    local repo; repo="$(setup_main_worktree "b-dec-$label")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-dec-$label")"
    local plans; plans="$(setup_plans_dir "b-dec-$label")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd; cmd="$(build_loop_step "$script_checkout_root" "$scripts" "$scripts" "$statefile" "$decision")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: loop_step decision '$decision' (not in allow-list) → BLOCK" "$rc"
}

# Arg-count violations for the other two live shapes (symmetric to loop_step's
# extra-arg/missing-arg pair above — #1600 review gap).
test_block_initial_extra_arg() {
    local repo; repo="$(setup_main_worktree "b-init4arg")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-init4arg")"
    local plans; plans="$(setup_plans_dir "b-init4arg")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234" "" "extra")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-initial.sh with 4 args (extra trailing) → BLOCK" "$rc"
}

test_block_initial_missing_arg() {
    local repo; repo="$(setup_main_worktree "b-init2arg")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-init2arg")"
    local plans; plans="$(setup_plans_dir "b-init2arg")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234")"' \
        "$script_checkout_root" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    # #1679 (S-6/G2): FLIPPED from BLOCK to ALLOW. The 2-argument form is the
    # documented shape for a current-repo issue (arg3 owner/repo omitted), so
    # `argCountMin: 3` was wrong — it false-blocked a real invocation. The arg-count
    # boundary is now pinned from both sides in
    # tests/hooks/fix-1679-finalize-overlay-arg-contract.sh: BK1679-1 (1 arg → BLOCK) and
    # BK1679-2 (4 args → BLOCK), with AC1679-2 pinning this 2-arg ALLOW.
    # The function name is left as-is because its caller (run_all in
    # tests/hooks/fix-1600-finalize-worker-overlay.sh) is out of scope for this change.
    assert_block "BLOCK C3 (#1679): run-initial.sh with 2 args (arg3 omitted) — eval path retired (#1673)" "$rc"
}

test_block_finalize_terminal_extra_arg() {
    local repo; repo="$(setup_main_worktree "b-term4arg")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-term4arg")"
    local plans; plans="$(setup_plans_dir "b-term4arg")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local outcome="$plans/sid-issue-close-outcome.json"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" bash "%s/run-finalize-terminal.sh" "%s" "sid" "%s" "extra")"' \
        "$script_checkout_root" "$scripts" "$statefile" "$outcome")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-finalize-terminal.sh with 4 args (extra trailing) → BLOCK" "$rc"
}

test_block_finalize_terminal_missing_arg() {
    local repo; repo="$(setup_main_worktree "b-term2arg")"
    local script_checkout_root; script_checkout_root="$(setup_fake_script_checkout_root "b-term2arg")"
    local plans; plans="$(setup_plans_dir "b-term2arg")"
    local scripts="$script_checkout_root/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" bash "%s/run-finalize-terminal.sh" "%s" "sid")"' \
        "$script_checkout_root" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_MAIN_ROOT=$script_checkout_root" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK C3: run-finalize-terminal.sh with 2 args (missing outcome) → BLOCK" "$rc"
}
