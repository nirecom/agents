#!/bin/bash
# tests/fix-bash-rm-target-extraction.sh
#
# Tests for hooks/enforce-worktree.js extractRmTargets path: when CWD is the
# main worktree and ENFORCE_WORKTREE=on, `rm` targets outside the repo's
# session scope must be allowed, while in-repo or unresolvable targets remain
# blocked. Issue #573.

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

# Resolve main worktree path.
_main_worktree_dir=""
if command -v git >/dev/null 2>&1; then
    _wt_list=$(git -C "$AGENTS_DIR" worktree list --porcelain 2>/dev/null)
    _main_worktree_dir=$(echo "$_wt_list" | awk '/^worktree /{print substr($0,10); exit}')
fi
if [ -z "$_main_worktree_dir" ] || [ ! -d "$_main_worktree_dir" ]; then
    echo "FAIL: cannot resolve main worktree path"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi
if command -v cygpath >/dev/null 2>&1; then
    _main_worktree_node="$(cygpath -m "$_main_worktree_dir")"
else
    _main_worktree_node="$_main_worktree_dir"
fi

NON_REPO_BASE="${TMPDIR:-/tmp}/claude-rm-target-test-$$"

run_case() {
    # $1=label  $2=expect ("allow"|"block")  $3=command-string
    local label="$1" expect="$2" cmd="$3"
    # Escape backslashes and double quotes for JSON embedding.
    local esc
    esc=$(printf '%s' "$cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    local payload="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${esc}\"}}"
    local OUT RC
    OUT=$(cd "$_main_worktree_dir" && echo "$payload" | ENFORCE_WORKTREE=on run_with_timeout 30 node "$HOOK" 2>/dev/null)
    RC=$?
    case "$expect" in
        allow)
            if [ "$RC" -eq 0 ] && ! echo "$OUT" | grep -q '"block"'; then
                pass "$label"
            else
                fail "$label (rc=$RC out=$OUT)"
            fi
            ;;
        block)
            if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q '"block"'; then
                pass "$label"
            else
                fail "$label (rc=$RC out=$OUT)"
            fi
            ;;
    esac
}

# --- R1: non-repo absolute path → allow ---
run_case "R1: rm of non-repo absolute path → allow" \
    allow \
    "rm ${NON_REPO_BASE}/scratch.md"

# --- R2: in-repo absolute path → blocked (regression guard) ---
run_case "R2: rm of in-repo absolute path → blocked" \
    block \
    "rm ${_main_worktree_node}/README.md"

# --- R3: rm -rf on non-repo path → allow (flag handling) ---
run_case "R3: rm -rf on non-repo path → allow" \
    allow \
    "rm -rf ${NON_REPO_BASE}/sub"

# --- R4: multiple non-repo targets → allow ---
run_case "R4: multiple non-repo targets → allow" \
    allow \
    "rm ${NON_REPO_BASE}/a ${NON_REPO_BASE}/b"

# --- R5: mixed non-repo + in-repo → blocked (any in-repo target blocks) ---
run_case "R5: mixed non-repo + in-repo → blocked" \
    block \
    "rm ${NON_REPO_BASE}/a ${_main_worktree_node}/README.md"

# --- R6: unresolvable token ($SOMEVAR) → blocked (parseFailure fail-closed) ---
run_case "R6: unresolvable token → blocked" \
    block \
    'rm $SOMEVAR/foo'

# --- R7: relative in-repo path resolved against CWD → blocked ---
run_case "R7: relative in-repo path → blocked" \
    block \
    "rm README.md"

# --- R_Q: quoted path with spaces → blocked (quote fail-closed) ---
run_case "R_Q: quoted in-repo path with spaces → blocked" \
    block \
    "rm \"${_main_worktree_node}/path with spaces/file\""

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
