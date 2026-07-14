#!/usr/bin/env bash
# tests/feature-supervisor-bin-tool-allow.sh
# Tests: hooks/enforce-worktree.js — supervisor bin tool allow-list (#1422)
# Tags: worktree, enforce, hook, supervisor, scope:common
#
# Verifies that supervisor bin tool invocations (bash "$AGENTS_CONFIG_DIR/bin/supervisor-*")
# are allowed from the main worktree when their write targets land outside the session scope
# (e.g. /tmp). The universal target-allow rule in enforce-worktree.js covers this case:
# all extracted write targets outside session scope → allow.
#
# Also documents that node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" is a read-only
# (non-write) command from the enforce-worktree perspective and passes through trivially.
#
# L3 gap (what this test does NOT catch):
# - Real claude -p session where the hook fires as a live PreToolUse event
# - Correctness of the supervisor scripts themselves (only the allow-list behavior is tested)
# Closest-to-action mitigation: hook-registration in bin/check-verification-gate.sh

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'sup-bin-allow-'+process.pid).replace(/\\\\/g,'/');
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
        "$@"
    fi
}

require_guard() {
    if [ ! -f "$GUARD_JS" ]; then
        fail "$1 (enforce-worktree.js not found)"
        return 1
    fi
    return 0
}

guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# ============ Tests ============

# T1: bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" --generate > /tmp/out.jsonl
# The write target (/tmp/out.jsonl) is outside all session repos → universal-target-allow
# fires and the command is allowed from the main worktree.
test_supervisor_review_codex_bash_allow() {
    require_guard "test_supervisor_review_codex_bash_allow" || return
    local repo; repo="$(setup_main_checkout "sup-rc-main")"
    local fake_acd="$TMPDIR_BASE/fake-acd-$$"
    mkdir -p "$fake_acd/bin"
    local cmd='bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" --generate > /tmp/sup-output.jsonl'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$fake_acd")"
    if guard_decision "$out"; then
        pass "T1: bash supervisor-review-codex --generate >/tmp/out.jsonl from main worktree: allow"
    else
        fail "T1: bash supervisor-review-codex --generate >/tmp/out.jsonl should allow (target outside session), got: $out"
    fi
}

# T2: node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" ... (no redirect)
# No write targets visible to the hook (node does not generate a bash-write-patterns hit).
# The command is classified as read-only and passes through.
test_supervisor_write_alert_node_allow() {
    require_guard "test_supervisor_write_alert_node_allow" || return
    local repo; repo="$(setup_main_checkout "sup-wa-main")"
    local fake_acd="$TMPDIR_BASE/fake-acd2-$$"
    mkdir -p "$fake_acd/bin"
    local cmd='node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" --severity error --detail "test finding" --session-id abc123'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$fake_acd")"
    if guard_decision "$out"; then
        pass "T2: node supervisor-write-alert from main worktree: allow (no write targets)"
    else
        fail "T2: node supervisor-write-alert should allow (read-only from hook perspective), got: $out"
    fi
}

# T3: bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" --generate > <repo-file>
# The write target IS inside the session repo → block (regression guard).
test_supervisor_review_codex_in_repo_write_blocks() {
    require_guard "test_supervisor_review_codex_in_repo_write_blocks" || return
    local repo; repo="$(setup_main_checkout "sup-rc-block")"
    local fake_acd="$TMPDIR_BASE/fake-acd3-$$"
    mkdir -p "$fake_acd/bin"
    # Write target inside the repo → should block
    local cmd="bash \"\$AGENTS_CONFIG_DIR/bin/supervisor-review-codex\" --generate > $repo/output.jsonl"
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$fake_acd")"
    if guard_decision "$out"; then
        fail "T3: bash supervisor-review-codex writing into repo should block (main worktree), got allow: $out"
    else
        pass "T3: bash supervisor-review-codex writing into repo from main worktree: block (regression guard)"
    fi
}

# T4: bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" without redirect
# No write target → classified as read-only, passes through.
test_supervisor_review_codex_no_redirect_allow() {
    require_guard "test_supervisor_review_codex_no_redirect_allow" || return
    local repo; repo="$(setup_main_checkout "sup-rc-noredirect")"
    local fake_acd="$TMPDIR_BASE/fake-acd4-$$"
    mkdir -p "$fake_acd/bin"
    local cmd='bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" --list'
    local out
    out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$fake_acd")"
    if guard_decision "$out"; then
        pass "T4: bash supervisor-review-codex --list (no redirect) from main worktree: allow"
    else
        fail "T4: bash supervisor-review-codex --list should allow (no write target), got: $out"
    fi
}

# ============ Run all ============

test_supervisor_review_codex_bash_allow
test_supervisor_write_alert_node_allow
test_supervisor_review_codex_in_repo_write_blocks
test_supervisor_review_codex_no_redirect_allow

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
