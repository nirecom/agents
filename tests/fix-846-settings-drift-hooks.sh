#!/bin/bash
# tests/fix-846-settings-drift-hooks.sh
# Tests: hooks/post-merge, hooks/post-checkout
# Tags: hook, settings, drift, post-merge, post-checkout
# Tests for issue #846 — git hooks that auto-reassemble ~/.claude/settings.json.
# Drift-detection module tests (T1-T8) and session-start tests (T17-T19) live in
# fix-846-settings-drift.sh.
#
# L2 narrow integration: validates hook trigger logic using sandbox git repos
# with stub assemblers. Each test uses an isolated git repo (mktemp -d) and
# never modifies the real ~/.claude/settings.json.
#
# L3 GAP (what this test does NOT catch):
# - Real assembler invocation: install/assemble-settings.js writing into a real home
# - Git merge conflict edge cases on settings files
# - Cross-OS path resolution edge cases for the real agents repo
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: drift-hooks

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

POST_MERGE="$AGENTS_DIR/hooks/post-merge"
POST_CHECKOUT="$AGENTS_DIR/hooks/post-checkout"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# --- Git hook helpers ---------------------------------------------------------

# init_sandbox_repo TYPE TMPDIR — creates a bare sandbox repo with no hooks.
init_sandbox_repo() {
    local typ="$1" tmp="$2"
    git init -q "$tmp"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config user.name "Test"
    git -C "$tmp" config commit.gpgsign false
    git -C "$tmp" config init.defaultBranch main >/dev/null 2>&1 || true
}

# Build a "fake agents" repo: copy the hooks into a fresh git repo so $0 dirname
# resolves to the sandbox top, allowing the repo guard to pass.
init_agents_sandbox() {
    local tmp="$1"
    git init -q "$tmp"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config user.name "Test"
    git -C "$tmp" config commit.gpgsign false
    mkdir -p "$tmp/hooks/lib" "$tmp/install"
    [ -f "$POST_MERGE" ] && cp "$POST_MERGE" "$tmp/hooks/post-merge" && chmod +x "$tmp/hooks/post-merge"
    [ -f "$POST_CHECKOUT" ] && cp "$POST_CHECKOUT" "$tmp/hooks/post-checkout" && chmod +x "$tmp/hooks/post-checkout"
    # Stub assembler: writes a sentinel file when invoked
    cat > "$tmp/install/assemble-settings.js" <<'NODEEOF'
#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const sentinel = process.env.ASSEMBLER_SENTINEL || path.join(__dirname, 'assembled.sentinel');
fs.writeFileSync(sentinel, String(Date.now()), 'utf8');
NODEEOF
    chmod +x "$tmp/install/assemble-settings.js"
    # Create an initial settings.json so commits can reference it
    echo '{}' > "$tmp/settings.json"
    echo '{}' > "$tmp/settings-extension.json"
    git -C "$tmp" add -A
    # ENFORCE_WORKTREE=off: the global pre-commit hook (agents/hooks/pre-commit) blocks commits on
    # standalone repos (git-common-dir == git-dir); bypass enforcement for sandbox commits.
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "initial"
}

# --- T9: post-merge in non-agents repo → no assembler call (exit 0) -----------
run_t9() {
    require_source "$POST_MERGE" "T9: post-merge non-agents repo no-op" || return
    local tmp; tmp="$(mktemp -d)"
    init_sandbox_repo "other" "$tmp"
    # Copy hook in but DON'T set up the agents layout — the guard should bail
    cp "$POST_MERGE" "$tmp/post-merge"
    chmod +x "$tmp/post-merge"
    local sentinel="$tmp/assembled.sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash "$tmp/post-merge" >/dev/null 2>&1
    local rc=$?
    if [ $rc -eq 0 ] && [ ! -f "$sentinel" ]; then
        pass "T9: post-merge non-agents repo no-op"
    else
        fail "T9: post-merge non-agents repo no-op (rc=$rc, sentinel exists: $([ -f "$sentinel" ] && echo yes || echo no))"
    fi
    rm -rf "$tmp"
}

# --- T10: post-merge, settings.json changed → assembler called ----------------
run_t10() {
    require_source "$POST_MERGE" "T10: post-merge settings.json changed → assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    # Create a branch + change settings.json + merge it
    git -C "$tmp" checkout -q -b feature
    echo '{"changed":true}' > "$tmp/settings.json"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change settings"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    # Use no-ff merge so ORIG_HEAD is set distinctly
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then
        pass "T10: post-merge settings.json changed → assembler"
    else
        fail "T10: post-merge settings.json changed → assembler (sentinel missing)"
    fi
    rm -rf "$tmp"
}

# --- T11: post-merge, settings.json NOT changed → no assembler call -----------
run_t11() {
    require_source "$POST_MERGE" "T11: post-merge settings.json unchanged → no assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    git -C "$tmp" checkout -q -b feature
    echo "// unrelated change" > "$tmp/unrelated.txt"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "unrelated"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T11: post-merge settings.json unchanged → no assembler"
    else
        fail "T11: post-merge settings.json unchanged → no assembler (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- T12: post-merge, settings-extension.json changed → assembler called ------
run_t12() {
    require_source "$POST_MERGE" "T12: post-merge settings-extension changed → assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    git -C "$tmp" checkout -q -b feature
    echo '{"ext":"changed"}' > "$tmp/settings-extension.json"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change ext"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then
        pass "T12: post-merge settings-extension changed → assembler"
    else
        fail "T12: post-merge settings-extension changed → assembler (sentinel missing)"
    fi
    rm -rf "$tmp"
}

# --- T13: post-checkout $3=0 (file checkout) → no assembler call --------------
run_t13() {
    require_source "$POST_CHECKOUT" "T13: post-checkout file-checkout no-op" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha; sha="$(git -C "$tmp" rev-parse HEAD)"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha' '$sha' 0" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T13: post-checkout file-checkout no-op"
    else
        fail "T13: post-checkout file-checkout no-op (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- T14: post-checkout $3=1, settings.json changed → assembler called --------
run_t14() {
    require_source "$POST_CHECKOUT" "T14: post-checkout settings.json changed → assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha_prev; sha_prev="$(git -C "$tmp" rev-parse HEAD)"
    git -C "$tmp" checkout -q -b feature
    echo '{"changed":true}' > "$tmp/settings.json"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change settings"
    local sha_new; sha_new="$(git -C "$tmp" rev-parse HEAD)"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha_prev' '$sha_new' 1" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then
        pass "T14: post-checkout settings.json changed → assembler"
    else
        fail "T14: post-checkout settings.json changed → assembler (sentinel missing)"
    fi
    rm -rf "$tmp"
}

# --- T15: post-checkout $3=1, settings.json NOT changed → no assembler --------
run_t15() {
    require_source "$POST_CHECKOUT" "T15: post-checkout settings.json unchanged → no assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha_prev; sha_prev="$(git -C "$tmp" rev-parse HEAD)"
    git -C "$tmp" checkout -q -b feature
    echo "// unrelated" > "$tmp/unrelated.txt"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "unrelated"
    local sha_new; sha_new="$(git -C "$tmp" rev-parse HEAD)"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha_prev' '$sha_new' 1" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T15: post-checkout settings.json unchanged → no assembler"
    else
        fail "T15: post-checkout settings.json unchanged → no assembler (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- T16: post-checkout $3=1, $1=0000... (initial clone) → no assembler -------
run_t16() {
    require_source "$POST_CHECKOUT" "T16: post-checkout initial clone no-op" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha_new; sha_new="$(git -C "$tmp" rev-parse HEAD)"
    local zero="0000000000000000000000000000000000000000"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$zero' '$sha_new' 1" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T16: post-checkout initial clone no-op"
    else
        fail "T16: post-checkout initial clone no-op (sentinel exists)"
    fi
    rm -rf "$tmp"
}

run_t9
run_t10
run_t11
run_t12
run_t13
run_t14
run_t15
run_t16

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
