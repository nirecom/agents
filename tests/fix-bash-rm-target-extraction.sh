#!/bin/bash
# tests/fix-bash-rm-target-extraction.sh
# Tests: hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, bin, tests
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

# --- R_Q2: double-quoted non-repo path → allow ---
run_case "R_Q2: double-quoted non-repo path with space → allow" \
    allow \
    "rm \"${NON_REPO_BASE}/quoted file.md\""

# --- R_Q3: single-quoted non-repo path → allow ---
run_case "R_Q3: single-quoted non-repo path → allow" \
    allow \
    "rm '/tmp/claude-rm-test-single/path.md'"

# --- R_Q4: flag + double-quoted non-repo path with space → allow ---
run_case "R_Q4: flag + double-quoted non-repo path with space → allow" \
    allow \
    "rm -rf \"${NON_REPO_BASE}/sub dir\""

# --- R_Q5: mixed unquoted + quoted non-repo targets → allow ---
run_case "R_Q5: mixed unquoted + quoted non-repo targets → allow" \
    allow \
    "rm ${NON_REPO_BASE}/a \"${NON_REPO_BASE}/b c\""

# --- R_Q_SEMI: rm "a;b.md" → block (outer regex truncates at ;, accepted constraint) ---
run_case "R_Q_SEMI: rm \"a;b.md\" → blocked (outer regex truncates at ;)" \
    block \
    'rm "a;b.md"'

# --- R_Q_BSLASH: rm "foo\"bar.md" → block (backslash escape not handled, accepted constraint) ---
run_case "R_Q_BSLASH: rm \"foo\\\"bar.md\" → blocked (backslash escape not handled)" \
    block \
    'rm "foo\"bar.md"'

# --- R_Q_single_in_repo: single-quoted in-repo path with spaces → blocked (symmetry with R_Q) ---
run_case "R_Q_single_in_repo: single-quoted in-repo path with spaces → blocked" \
    block \
    "rm '${_main_worktree_node}/path with spaces/file'"

# --- R_LONG: long flags + non-repo path → allow (long flags skipped) ---
run_case "R_LONG: rm --recursive --force non-repo path → allow" \
    allow \
    "rm --recursive --force ${NON_REPO_BASE}/sub"

# --- R_EMPTY: rm -rf with no positionals → blocked (empty targets; hook default blocks) ---
run_case "R_EMPTY: rm -rf with no positionals → blocked" \
    block \
    "rm -rf"

# --- R_DD: rm -- README.md → blocked (-- end-of-flags; README.md resolves in-repo) ---
run_case "R_DD: rm -- README.md → blocked" \
    block \
    "rm -- README.md"

# --- R_Q6: multiple double-quoted non-repo targets → allow ---
run_case "R_Q6: multiple double-quoted non-repo targets → allow" \
    allow \
    "rm \"${NON_REPO_BASE}/a\" \"${NON_REPO_BASE}/b c\""

# --- R_Q7: mixed double-quoted, one in-repo → blocked ---
run_case "R_Q7: mixed double-quoted with in-repo target → blocked" \
    block \
    "rm \"${NON_REPO_BASE}/a\" \"${_main_worktree_node}/README.md\""

# --- R_Q_REL: double-quoted relative in-repo path → blocked (regression guard) ---
run_case "R_Q_REL: rm \"README.md\" (double-quoted relative in-repo) → blocked" \
    block \
    'rm "README.md"'

# --- R_TRAVERSAL: double-quoted path traversal back into repo → blocked ---
# CWD is the main worktree; "../<repo-name>/README.md" resolves in-repo.
_repo_name="$(basename "${_main_worktree_node}")"
run_case "R_TRAVERSAL: rm \"../<repo>/README.md\" traversal → blocked" \
    block \
    "rm \"../${_repo_name}/README.md\""

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
