#!/bin/bash
# tests/feature-1701-workflow-gate-code-size/infra-and-config.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/code-size-gate.js, bin/review-code-size
# Tags: workflow-gate, hook, gate2, code-size, file-split, scope:issue-specific
#
# Fragment of tests/feature-1701-workflow-gate-code-size.sh — sourced by the
# parent, not run directly. Owns cases 8-14: infrastructure failure handling
# (missing bash, missing script, unexpected exit, timeout = the only fail-open
# path) and CODE_FILE_EXTENSIONS resolution (.env authoritative, process.env
# ignored, no .env at all).
#
# Depends on the parent for: TMPDIR_BASE, fresh_workflow_dir, setup_repo,
# make_plain_config_dir, make_marker_config_dir, write_complete_state,
# make_lines, build_commit_payload, run_hook, assert_approve, assert_block,
# HOOK_OUT, pass, fail, skip.

# 8. bash not on PATH -> block (infrastructure error, NOT fail-open).
test_8_bash_missing_blocks() {
    local gitdir nodedir restricted probe
    gitdir="$(dirname "$(command -v git 2>/dev/null)")"
    nodedir="$(dirname "$(command -v node 2>/dev/null)")"
    if [ -z "$gitdir" ] || [ -z "$nodedir" ]; then
        skip "8: cannot locate git/node to build a restricted PATH"
        return
    fi
    if command -v cygpath >/dev/null 2>&1; then
        restricted="$(cygpath -w "$gitdir");$(cygpath -w "$nodedir")"
    else
        restricted="$gitdir:$nodedir"
    fi
    # Verify the restricted PATH really hides bash on this host; skip otherwise.
    probe="$(env "PATH=$restricted" node -e "
const {spawnSync}=require('child_process');
const r=spawnSync('bash',['-c','echo hi']);
process.stdout.write(r.error?String(r.error.code):'FOUND');
" 2>/dev/null)"
    if [ "$probe" != "ENOENT" ]; then
        skip "8: bash still reachable under restricted PATH on this host (probe=$probe)"
        return
    fi

    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2008"
    local repo; repo="$(setup_repo "r8")"
    local cfg; cfg="$(make_plain_config_dir "c8")"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 100 > "$repo/bin/small.js"
    git -C "$repo" add bin/small.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg" "PATH=$restricted"
    assert_block "8: bash missing -> block (infrastructure error)" "code-size" || return
    if echo "$HOOK_OUT" | grep -qiE "bash|PATH|install|recover|resolve"; then
        pass "8: block reason carries recovery guidance"
    else
        fail "8: block reason lacks recovery guidance" "$HOOK_OUT"
    fi
}

# 9. bin/review-code-size missing in the adopted config dir -> block.
test_9_script_missing_blocks() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2009"
    local repo; repo="$(setup_repo "r9")"
    local cfg; cfg="$(make_marker_config_dir "c9")"   # markers present, no bin/review-code-size
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 100 > "$repo/bin/small.js"
    git -C "$repo" add bin/small.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "9: bin/review-code-size missing -> block" "code-size" || return
    if echo "$HOOK_OUT" | grep -qiE "review-code-size|install|recover|resolve"; then
        pass "9: block reason carries recovery guidance"
    else
        fail "9: block reason lacks recovery guidance" "$HOOK_OUT"
    fi
}

# 10. bin/review-code-size exits with an unexpected status -> block.
test_10_unexpected_exit_blocks() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2010"
    local repo; repo="$(setup_repo "r10")"
    local cfg; cfg="$(make_marker_config_dir "c10")"
    printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 2\n' > "$TMPDIR_BASE/cfg-c10/bin/review-code-size"
    chmod +x "$TMPDIR_BASE/cfg-c10/bin/review-code-size"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 100 > "$repo/bin/small.js"
    git -C "$repo" add bin/small.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "10: unexpected exit code 2 -> block" "code-size"
}

# 11. Timeout is the ONLY fail-open path -> approve.
test_11_timeout_fail_open() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2011"
    local repo; repo="$(setup_repo "r11")"
    local cfg; cfg="$(make_marker_config_dir "c11")"
    printf '#!/usr/bin/env bash\nsleep 30\nexit 1\n' > "$TMPDIR_BASE/cfg-c11/bin/review-code-size"
    chmod +x "$TMPDIR_BASE/cfg-c11/bin/review-code-size"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "11: review-code-size timeout -> approve (only fail-open path)"
}

# 12. process.env CODE_FILE_EXTENSIONS is ignored by gate — only .env is authoritative.
test_12_env_var_ignored() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2012"
    local repo; repo="$(setup_repo "r12")"
    local cfg; cfg="$(make_plain_config_dir "c12")"
    printf 'CODE_FILE_EXTENSIONS=js;sh;py\n' > "$TMPDIR_BASE/cfg-c12/.env"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/src"
    make_lines 501 > "$repo/src/big.ts"
    git -C "$repo" add src/big.ts
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg" "CODE_FILE_EXTENSIONS=ts"
    assert_approve "12: forged process.env CODE_FILE_EXTENSIONS=ts ignored, .env (js;sh;py) authoritative -> approve"
}

# 13. CODE_FILE_EXTENSIONS supplied only via .env is honoured.
test_13_env_from_dotenv() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2013"
    local repo; repo="$(setup_repo "r13")"
    local cfg; cfg="$(make_plain_config_dir "c13")"
    printf 'CODE_FILE_EXTENSIONS=js;sh;py;ts\n' > "$TMPDIR_BASE/cfg-c13/.env"
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/src"
    make_lines 501 > "$repo/src/big.ts"
    git -C "$repo" add src/big.ts
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "13: CODE_FILE_EXTENSIONS from .env only -> block" "big.ts"
}

# 14. No .env in the config dir -> defaults apply, no crash.
test_14_no_dotenv() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate2014"
    local repo; repo="$(setup_repo "r14")"
    local cfg; cfg="$(make_plain_config_dir "c14")"   # deliberately no .env
    write_complete_state "$wfdir" "$sid"
    mkdir -p "$repo/bin"
    make_lines 501 > "$repo/bin/big.js"
    git -C "$repo" add bin/big.js
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "14: missing .env -> defaults apply, still blocks" "big.js"
}
