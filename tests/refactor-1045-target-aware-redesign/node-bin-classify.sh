#!/bin/bash
# R-18: node bin/supervisor-report classify=read fast-allow
# Pre-refactor: handled by KNOWN_PLANS_DIR_WRITERS allowlist in plans-dir.js.
# Post-refactor: classify() returns "read" (no write patterns) → fast-allow
# before main-worktree-allows is even consulted. KNOWN_PLANS_DIR_WRITERS is dead.

# ============================================================================
# R-18: node bin/supervisor-report from main → allow
# ============================================================================
test_r18_supervisor_report_allow() {
    require_impl "R-18" || return
    local repo; repo="$(setup_main_checkout "r18")"
    local out
    out="$(run_bash_guard "node bin/supervisor-report --session-id abc --categories code --severity warning --detail x --reporter test" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "R-18: node bin/supervisor-report from main → allow (classify=read fast-allow)"
    else
        fail "R-18: node bin/supervisor-report from main: should allow ($out)"
    fi
}

test_r18_supervisor_report_allow
