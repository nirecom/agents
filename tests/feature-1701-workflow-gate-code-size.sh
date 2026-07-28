#!/bin/bash
# tests/feature-1701-workflow-gate-code-size.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/code-size-gate.js, bin/review-code-size
# Tags: workflow-gate, hook, gate2, code-size, file-split, scope:issue-specific
#
# Issue #1701 — Gate 2: workflow-gate.js must hard-block `git commit` when a
# STAGED code file exceeds the 500-line HARD limit (rules/coding/file-split.md).
# Gate 2 delegates to hooks/workflow-gate/code-size-gate.js, which shells out to
# `bash bin/review-code-size --staged`.
#
# TL3 gap (what this test does NOT catch):
# - Whether the PreToolUse hook actually fires when Claude Code issues a git commit Bash command
# - Whether settings.json correctly registers hooks/workflow-gate.js for the Bash tool commit command
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"
GATE_MODULE="${AGENTS_DIR}/hooks/workflow-gate/code-size-gate.js"

# ---------------------------------------------------------------------------
# Pre-implementation skip gate.
# Gate 2 lives in hooks/workflow-gate/code-size-gate.js. Until that module
# exists there is nothing to assert — exit 77 (run-all.sh treats it as SKIP).
# ---------------------------------------------------------------------------
if [ ! -f "$GATE_MODULE" ]; then
    echo "SKIP: hooks/workflow-gate/code-size-gate.js not present yet (issue #1701 not implemented)"
    exit 77
fi
if [ ! -f "$HOOK_JS" ]; then
    echo "SKIP: hooks/workflow-gate.js not present"
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'gate2-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

make_lines() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "line $i"; done
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    to_node_path "$d"
}

write_complete_state() {
    local wfdir="$1" sid="$2"
    node -e "
const fs = require('fs');
const path = require('path');
const { VALID_STEPS } = require('$_AGENTS_DIR_NODE/hooks/workflow-state.js');
const steps = {};
const now = new Date().toISOString();
for (const s of VALID_STEPS) steps[s] = { status: 'complete', updated_at: now };
const state = { version: 1, session_id: '$sid', created_at: now, steps };
fs.writeFileSync(path.join('$wfdir', '$sid' + '.json'), JSON.stringify(state, null, 2));
"
}

write_workflow_off_marker() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

# ---------------------------------------------------------------------------
# Config-dir fixtures.
#
# AGENTS_CONFIG_DIR drives two independent decisions (CPR-3 — keep them apart):
#   1. isAgentsSessionRepo()      — compares git common-dirs. A NON-git config
#      dir makes the helper fail closed (true), so Gate 2 stays armed for the
#      temp repo under test.
#   2. resolveAgentsConfigDir()   — which checkout owns bin/review-code-size.
#      The env candidate is adopted only when it carries BOTH markers
#      (hooks/enforce-worktree.js + bin/). A marker-less dir therefore falls
#      through to the module anchor = the real agents checkout.
# ---------------------------------------------------------------------------

# Plain dir: no markers -> real bin/review-code-size is used, Gate 2 armed.
make_plain_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d"
    to_node_path "$d"
}

# Marker dir: adopted by resolveAgentsConfigDir(); bin/review-code-size is
# whatever this fixture puts there (or nothing at all).
make_marker_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d/hooks" "$d/bin"
    echo "// stub marker" > "$d/hooks/enforce-worktree.js"
    to_node_path "$d"
}

# A separate git repo used as the "agents session repo" so that the repo being
# committed to is recognised as a DIFFERENT repo (cross-repo bypass).
make_foreign_git_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo "x" > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "init"
    to_node_path "$d"
}

setup_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config core.autocrlf false
    mkdir -p "$repo/docs"
    echo "init" > "$repo/README.md"
    echo "doc" > "$repo/docs/notes.md"
    git -C "$repo" add README.md docs/notes.md
    git -C "$repo" commit -q -m "initial"
    to_node_path "$repo"
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_commit_payload() {
    local sid="$1" repo="$2" cmd_template="${3:-}"
    local cmd
    if [ -n "$cmd_template" ]; then cmd="$cmd_template"; else cmd="git -C $repo commit -m \"test\""; fi
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(json_quote "$sid")" "$(json_quote "$cmd")"
}

HOOK_OUT=""
HOOK_RC=0
# run_hook <payload> <wfdir> <cfgdir> [extra KEY=VALUE ...]
run_hook() {
    local payload="$1" wfdir="$2" cfg="$3"; shift 3
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 60 \
        env -u CLAUDE_ENV_FILE -u CODE_FILE_EXTENSIONS \
        "AGENTS_CONFIG_DIR=$cfg" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "$@" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

assert_approve() {
    local label="$1"
    if [ "$HOOK_RC" -ne 0 ]; then fail "$label: hook crashed rc=$HOOK_RC" "$HOOK_OUT"; return 1; fi
    if echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "$label"
    else
        fail "$label: expected approve" "$HOOK_OUT"
    fi
}

assert_block() {
    local label="$1" needle="${2:-}"
    if [ "$HOOK_RC" -ne 0 ]; then fail "$label: hook crashed rc=$HOOK_RC" "$HOOK_OUT"; return 1; fi
    if ! echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "$label: expected block" "$HOOK_OUT"
        return 1
    fi
    if [ -n "$needle" ] && ! echo "$HOOK_OUT" | grep -qi -- "$needle"; then
        fail "$label: block reason missing '$needle'" "$HOOK_OUT"
        return 1
    fi
    pass "$label"
}

# ============================================================================
# Tests
# ============================================================================

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

run_all() {
    test_1_hard_limit_block
    test_2_ok_300_lines
    test_3_untracked_only_approves
    test_4_workflow_off_bypass
    test_5_wip_does_not_bypass
    test_6_cross_repo_bypass
    test_7_split_passes
    test_8_bash_missing_blocks
    test_9_script_missing_blocks
    test_10_unexpected_exit_blocks
    test_11_timeout_fail_open
    test_12_env_var_ignored
    test_13_env_from_dotenv
    test_14_no_dotenv
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_GATE2_E2E_INNER:-}" ]; then
        _GATE2_E2E_INNER=1 timeout 300 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
