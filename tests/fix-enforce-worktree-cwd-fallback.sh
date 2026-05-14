#!/bin/bash
# tests/fix-enforce-worktree-cwd-fallback.sh
#
# Tests for hooks/enforce-worktree.js fail-open when process.cwd() points to
# a directory that no longer exists (issue #268). Companion fix is in
# skills/worktree-end/SKILL.md step 6b.5 (cd <main> as a separate Bash call
# before step 6c's git worktree remove — they cannot be combined because
# enforce-worktree.js rejects chained commands in isAllowedWorktreeCommand).
# This test guards the hook-level backstop.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$HOOK" ]; then
    echo "FAIL: hooks/enforce-worktree.js not found"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# --- C1: dead CWD → fail-open (POSIX only) ---
case "$(uname -s)" in
    Linux*|Darwin*|FreeBSD*)
        tmp="$(mktemp -d)"
        payload='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/whatever.txt","new_string":"x"}}'
        OUT=$(
            cd "$tmp" && rm -rf "$tmp" &&
            echo "$payload" | ENFORCE_WORKTREE=on run_with_timeout 30 node "$HOOK" 2>/tmp/.c1_err.$$
        )
        RC=$?
        ERR=$(cat /tmp/.c1_err.$$ 2>/dev/null)
        rm -f /tmp/.c1_err.$$
        rm -rf "$tmp" 2>/dev/null
        if [ "$RC" -eq 0 ] \
           && ! echo "$OUT" | grep -q '"block"' \
           && ! echo "$ERR" | grep -q "at Object\." \
           && echo "$ERR" | grep -q "enforce-worktree: fail-open"; then
            pass "C1: dead CWD → fail-open exit 0, no block, audit stderr present"
        else
            fail "C1: dead CWD → fail-open (rc=$RC out=$OUT err=$ERR)"
        fi
        ;;
    *)
        echo "SKIP: C1 — POSIX-only; C4 covers equivalent Windows scenario via mock"
        PASS=$((PASS + 1))
        ;;
esac

# --- C2: existing non-git CWD + gh-write → still blocked ---
tmp2="$(mktemp -d 2>/dev/null || mktemp -d -t cwdtest)"
payload='{"tool_name":"Bash","tool_input":{"command":"gh api -X PATCH /repos/o/r/issues/1 -f body=test"}}'
OUT=$(cd "$tmp2" && echo "$payload" | ENFORCE_WORKTREE=on run_with_timeout 30 node "$HOOK" 2>/tmp/.c2_err.$$)
RC=$?
ERR=$(cat /tmp/.c2_err.$$ 2>/dev/null)
rm -f /tmp/.c2_err.$$
rmdir "$tmp2" 2>/dev/null
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"block"' && echo "$OUT" | grep -q "cannot determine repo root"; then
    pass "C2: existing non-git CWD + gh-write → still blocked"
else
    fail "C2: existing non-git CWD + gh-write → still blocked (rc=$RC out=$OUT err=$ERR)"
fi

# --- C3: main-worktree write still blocked ---
# Resolve the actual main worktree (git-common-dir == git-dir).
# AGENTS_DIR may itself be a linked worktree, so we cannot use it directly.
_main_worktree_dir=""
if command -v git >/dev/null 2>&1; then
    _wt_list=$(git -C "$AGENTS_DIR" worktree list --porcelain 2>/dev/null)
    # The first 'worktree <path>' line is the main worktree.
    _main_worktree_dir=$(echo "$_wt_list" | awk '/^worktree /{print substr($0,10); exit}')
fi
if [ -z "$_main_worktree_dir" ] || [ ! -d "$_main_worktree_dir" ]; then
    echo "SKIP: C3 — cannot resolve main worktree path"
    PASS=$((PASS + 1))
else
    if command -v cygpath >/dev/null 2>&1; then
        _main_worktree_node="$(cygpath -m "$_main_worktree_dir")"
    else
        _main_worktree_node="$_main_worktree_dir"
    fi
    payload="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${_main_worktree_node}/README.md\",\"new_string\":\"x\"}}"
    OUT=$(cd "$_main_worktree_dir" && echo "$payload" | ENFORCE_WORKTREE=on run_with_timeout 30 node "$HOOK" 2>/tmp/.c3_err.$$)
    RC=$?
    ERR=$(cat /tmp/.c3_err.$$ 2>/dev/null)
    rm -f /tmp/.c3_err.$$
    if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"block"'; then
        pass "C3: main-worktree write still blocked"
    else
        fail "C3: main-worktree write still blocked (rc=$RC out=$OUT err=$ERR)"
    fi
fi

# --- C4: deterministic test of fs.existsSync=false branch (unit-backstop) ---
mock_dir="$(mktemp -d 2>/dev/null || mktemp -d -t c4_mock)"
if [ -z "$mock_dir" ] || [ ! -d "$mock_dir" ]; then
    mock_dir="$AGENTS_DIR/.tmp-c4-mock-$$"
    mkdir -p "$mock_dir"
fi
trap 'rm -rf "$mock_dir" 2>/dev/null; rm -f /tmp/.c4_err.$$ 2>/dev/null' EXIT INT TERM HUP

mock_file="$mock_dir/mock_fs.js"
cat > "$mock_file" <<'EOF'
const fs = require('fs');
const real = fs.existsSync;
fs.existsSync = function(p) {
  try {
    if (p === process.cwd()) return false;
  } catch (e) {
    return false;
  }
  return real.apply(fs, arguments);
};
EOF

if command -v cygpath >/dev/null 2>&1; then
    _mock_file_node="$(cygpath -m "$mock_file")"
else
    _mock_file_node="$mock_file"
fi

payload='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/whatever.txt","new_string":"x"}}'
OUT=$(cd "$AGENTS_DIR" && echo "$payload" | ENFORCE_WORKTREE=on run_with_timeout 30 node --require "$_mock_file_node" "$HOOK" 2>/tmp/.c4_err.$$)
RC=$?
ERR=$(cat /tmp/.c4_err.$$ 2>/dev/null)
rm -f /tmp/.c4_err.$$
rm -rf "$mock_dir"
trap - EXIT INT TERM HUP
if [ "$RC" -eq 0 ] \
   && ! echo "$OUT" | grep -q '"block"' \
   && ! echo "$ERR" | grep -q "at Object\." \
   && echo "$ERR" | grep -q "enforce-worktree: fail-open"; then
    pass "C4: mocked fs.existsSync=false → fail-open, audit stderr present"
else
    fail "C4: mocked fs.existsSync=false → fail-open (rc=$RC out=$OUT err=$ERR)"
fi

# --- C5: enforce-issue-close.js does not call process.cwd() ---
ICC_HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-issue-close.js"
if [ ! -f "$ICC_HOOK" ]; then
    fail "C5: enforce-issue-close.js not found at $ICC_HOOK"
elif grep -q "process\.cwd" "$ICC_HOOK"; then
    fail "C5: enforce-issue-close.js calls process.cwd() — dead-CWD assumption violated (issue #268)"
else
    pass "C5: enforce-issue-close.js does not call process.cwd() (dead-CWD safe)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
