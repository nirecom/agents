# tests/fix-1600-finalize-worker-overlay/allow-cases.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, overlay, security, scope:issue-specific
#
# Sourced by tests/fix-1600-finalize-worker-overlay.sh and, verbatim, by
# tests/fix-1630-overlay-cross-validation.sh.
#
# ============================================================================
# Retired-capability cases — the exact command shapes finalize-worker-overlay.js
# once ALLOWED. #1673 deleted that overlay together with the Bash-tool `eval`
# path, so each of these must now BLOCK. Function names are unchanged on purpose:
# they are the provenance of what used to be allowed here.
# ============================================================================

test_allow_initial() {
    local repo; repo="$(setup_main_worktree "a-initial")"
    local acd; acd="$(setup_fake_acd "a-initial")"
    local plans; plans="$(setup_plans_dir "a-initial")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd; cmd="$(build_initial "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "BLOCK initial: literal-path eval run-initial.sh — eval path retired (#1673)" "$rc"
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
    assert_block "BLOCK loop_step: decision=$decision — eval path retired (#1673)" "$rc"
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
    assert_block "BLOCK finalize_terminal: literal-path eval — eval path retired (#1673)" "$rc"
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
    assert_block "BLOCK initial: env-var prefix order swapped (MWT/FSD/ACD) — eval path retired (#1673)" "$rc"
}
