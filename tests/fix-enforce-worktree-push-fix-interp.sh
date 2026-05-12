#!/bin/bash
# tests/fix-enforce-worktree-push-fix-interp.sh
#
# Integration tests for hooks/enforce-worktree.js — Fix 2:
# isReadOnlyInterpreterC(cmd)
#
# Allow `bash -c '...'` / `pwsh -Command '...'` etc. when:
#   - There is NO outer shell chaining (checked on stripQuotedArgs(cmd) — so
#     inner `&&` inside quotes does not trigger).
#   - The inner body, split on shell operators (`&&`, `||`, `;`), classifies
#     EVERY segment as "read-only".
#
# TDD note: Fix 2 is not yet implemented. The current hook classifies any
# `bash -c …` invocation as `write` via the "interpreter-c" WRITE_PATTERN,
# so all ALLOW cases will FAIL RED. BLOCK cases already block — those
# verify the fail-closed paths the hook keeps after Fix 2 lands.

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
const d=path.join(os.tmpdir(),'push-fix-interp-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (enforce-worktree.js not present)"
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

norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
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
    norm_path "$repo"
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

# ─────────────────────────────────────────────────────────────────────────────
# ALLOW cases — read-only inner body (RED until Fix 2 implemented)
# ─────────────────────────────────────────────────────────────────────────────

test_bash_c_cd_and_read_allows() {
    require_guard "test_bash_c_cd_and_read_allows" || return
    local repo; repo="$(setup_main_checkout "interp-cd-read")"
    # cd + read-only command chained with `&&` and `||`. The `&&`/`||`/`;`
    # operators are INSIDE single quotes, so stripQuotedArgs(cmd) removes them
    # and the outer chaining check sees no operators. The inner body has all
    # segments classified as read-only (cd, git status, echo).
    local cmd="bash -c 'cd \"/tmp\" && git status && echo OK || echo FAIL'"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Fix 2: bash -c with read-only inner body (cd && git status && echo) allows"
    else
        fail "Fix 2: bash -c with read-only inner body should allow ($out)"
    fi
}

test_bash_c_ls_and_pwd_allows() {
    require_guard "test_bash_c_ls_and_pwd_allows" || return
    local repo; repo="$(setup_main_checkout "interp-ls-pwd")"
    local cmd="bash -c \"ls && pwd\""
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Fix 2: bash -c \"ls && pwd\" allows"
    else
        fail "Fix 2: bash -c \"ls && pwd\" should allow ($out)"
    fi
}

test_pwsh_command_getchilditem_allows() {
    require_guard "test_pwsh_command_getchilditem_allows" || return
    local repo; repo="$(setup_main_checkout "interp-pwsh-gci")"
    local cmd="pwsh -Command 'Get-ChildItem'"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Fix 2: pwsh -Command 'Get-ChildItem' allows"
    else
        fail "Fix 2: pwsh -Command 'Get-ChildItem' should allow ($out)"
    fi
}

test_powershell_command_getcontent_allows() {
    require_guard "test_powershell_command_getcontent_allows" || return
    local repo; repo="$(setup_main_checkout "interp-ps-gc")"
    local cmd="powershell -Command 'Get-Content x.txt'"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Fix 2: powershell -Command 'Get-Content x.txt' allows"
    else
        fail "Fix 2: powershell -Command 'Get-Content x.txt' should allow ($out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK cases — already blocked by current hook
# ─────────────────────────────────────────────────────────────────────────────

test_bash_c_rm_blocks() {
    require_guard "test_bash_c_rm_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-rm")"
    local cmd="bash -c 'rm -rf /tmp/foo'"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: bash -c 'rm -rf ...' should block ($out)"
    else
        pass "Fix 2: bash -c 'rm -rf ...' blocks"
    fi
}

test_outer_chaining_blocks() {
    require_guard "test_outer_chaining_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-outer")"
    # `bash -c 'echo hi' && rm file` — the outer `&& rm` is NOT inside quotes,
    # so stripQuotedArgs leaves the `&&` visible, and hasShellChaining triggers.
    local cmd="bash -c 'echo hi' && rm file"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: bash -c '...' && rm should block (outer chaining) ($out)"
    else
        pass "Fix 2: outer chaining (bash -c ... && rm) blocks"
    fi
}

test_bash_c_unquoted_body_blocks() {
    require_guard "test_bash_c_unquoted_body_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-unquoted")"
    # `bash -c ls` — body is unquoted bare token, single command.
    # Fix 2 should fail-closed here (cannot determine inner body reliably).
    local cmd="bash -c ls"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: bash -c <unquoted body> should fail-closed ($out)"
    else
        pass "Fix 2: bash -c ls (unquoted body) blocks (fail-closed)"
    fi
}

test_bash_c_unquoted_multitoken_blocks() {
    require_guard "test_bash_c_unquoted_multitoken_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-unq-multi")"
    # `bash -c echo hello` — multi-token unquoted.
    local cmd="bash -c echo hello"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: bash -c echo hello (unquoted multi-token) should block ($out)"
    else
        pass "Fix 2: bash -c echo hello blocks (fail-closed)"
    fi
}

test_bash_c_ansi_c_quoting_blocks() {
    require_guard "test_bash_c_ansi_c_quoting_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-ansic")"
    # `bash -c $'echo hi'` — ANSI-C quoting with $'…'. Fail-closed.
    local cmd="bash -c \$'echo hi'"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: bash -c \$'…' (ANSI-C) should block ($out)"
    else
        pass "Fix 2: bash -c \$'…' (ANSI-C) blocks (fail-closed)"
    fi
}

test_bash_herestring_blocks() {
    require_guard "test_bash_herestring_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-herestr")"
    # `bash <<< 'echo hi'` — here-string is classified write by the
    # here-string WRITE_PATTERN and is not a -c invocation.
    local cmd="bash <<< 'echo hi'"
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: bash <<< '...' (here-string) should block ($out)"
    else
        pass "Fix 2: bash <<< '...' blocks (here-string write pattern)"
    fi
}

test_pwsh_command_remove_item_blocks() {
    require_guard "test_pwsh_command_remove_item_blocks" || return
    local repo; repo="$(setup_main_checkout "interp-pwsh-rm")"
    # pwsh -Command with a write cmdlet inside — Remove-Item is in write patterns.
    local cmd="pwsh -Command \"Remove-Item foo\""
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Fix 2: pwsh -Command 'Remove-Item …' should block ($out)"
    else
        pass "Fix 2: pwsh -Command 'Remove-Item …' blocks"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

# ALLOW cases (RED until Fix 2 implemented)
test_bash_c_cd_and_read_allows
test_bash_c_ls_and_pwd_allows
test_pwsh_command_getchilditem_allows
test_powershell_command_getcontent_allows

# BLOCK cases
test_bash_c_rm_blocks
test_outer_chaining_blocks
test_bash_c_unquoted_body_blocks
test_bash_c_unquoted_multitoken_blocks
test_bash_c_ansi_c_quoting_blocks
test_bash_herestring_blocks
test_pwsh_command_remove_item_blocks

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
