#!/bin/bash
# tests/feature-1701-workflow-gate-code-size/gate-behavior.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/code-size-gate.js, bin/review-code-size
# Tags: workflow-gate, hook, gate2, code-size, file-split, scope:issue-specific
#
# Fragment of tests/feature-1701-workflow-gate-code-size.sh — sourced by the
# parent, not run directly. Owns cases 1-7: the Gate 2 decision itself against a
# real staged tree (hard-limit block, under-limit approve, untracked-only,
# WORKFLOW_OFF bypass, WIP non-bypass, cross-repo bypass, post-split approve).
#
# Depends on the parent for: TMPDIR_BASE, fresh_workflow_dir, setup_repo,
# make_plain_config_dir, make_foreign_git_config_dir, write_complete_state,
# write_workflow_off_marker, make_lines, build_commit_payload, run_hook,
# assert_approve, assert_block, HOOK_OUT, pass, fail, skip.

# 1. staged 501-line .js + all steps complete -> block, reason names the file.
test_1_hard_limit_block() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2001"
    local repo; repo="$(setup_repo "r1")"
    local cfg; cfg="$(make_plain_config_dir "c1")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "1: staged 501-line .js -> block" "big.js" || return
    if echo "$HOOK_OUT" | grep -qi "hard"; then
        pass "1: block reason mentions the HARD limit"
    else
        fail "1: block reason does not mention HARD" "$HOOK_OUT"
    fi
}

# 2. staged 300-line .js -> approve.
test_2_ok_300_lines() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2002"
    local repo; repo="$(setup_repo "r2")"
    local cfg; cfg="$(make_plain_config_dir "c2")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 300 > "$repo/bin/ok.js"
    git -C "$repo" add bin/ok.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "2: staged 300-line .js -> approve"
}

# 3. 501-line .js untracked only, docs staged -> approve.
#    Regression guard: calling review-code-size without --staged would over-block.
test_3_untracked_only_approves() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2003"
    local repo; repo="$(setup_repo "r3")"
    local cfg; cfg="$(make_plain_config_dir "c3")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/untracked-big.js"   # never staged
    echo "more docs" >> "$repo/docs/notes.md"
    git -C "$repo" add docs/notes.md
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "3: untracked 501-line .js + docs staged -> approve"
}

# 4. WORKFLOW_OFF marker bypasses Gate 2.
test_4_workflow_off_bypass() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2004"
    local repo; repo="$(setup_repo "r4")"
    local cfg; cfg="$(make_plain_config_dir "c4")"
    write_workflow_off_marker "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "4: WORKFLOW_OFF marker -> approve (Gate 2 bypassed)"
}

# 5. WIP commit does NOT bypass Gate 2.
test_5_wip_does_not_bypass() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2005"
    local repo; repo="$(setup_repo "r5")"
    local cfg; cfg="$(make_plain_config_dir "c5")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    # NOTE: -c MUST come before the `commit` subcommand verb.
    run_hook "$(build_commit_payload "$sid" "$repo" \
        "git -C $repo -c workflow.wip=1 commit -m \"wip\"")" "$wfdir" "$cfg"
    assert_block "5: WIP commit + staged 501-line .js -> still blocked" "big.js"
}

# 6. Commit targeting a different repo -> approve (isAgentsSessionRepo fires first).
test_6_cross_repo_bypass() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2006"
    local repo; repo="$(setup_repo "r6")"
    local cfg; cfg="$(make_foreign_git_config_dir "c6")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "6: cross-repo commit -> approve (Gate 2 not reached)"
}

# 7. Split file: big.js reduced to 120 lines + new big/part.js 200 lines -> approve.
test_7_split_passes() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2007"
    local repo; repo="$(setup_repo "r7")"
    local cfg; cfg="$(make_plain_config_dir "c7")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    git -C "$repo" commit -q -m "pre-split 501-line file"
    # Now perform the split and stage BOTH halves.
    make_lines 120 > "$repo/bin/big.js"
    mkdir -p "$repo/bin/big"
    make_lines 200 > "$repo/bin/big/part.js"
    git -C "$repo" add bin/big.js bin/big/part.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "7: split into 120 + 200 lines -> approve"
}
