#!/bin/bash
# tests/refactor-enforce-worktree-split.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/config.js, hooks/enforce-worktree/git-repo-detection.js, hooks/enforce-worktree/session-scope.js, hooks/enforce-worktree/git-hooks-bypass.js, hooks/enforce-worktree/shared-cmd-utils.js, hooks/enforce-worktree/branch-delete-guard.js, hooks/enforce-worktree/main-worktree-allows.js, hooks/enforce-worktree/bash-write-scope.js, hooks/cleanup-orphan-dir.js
# Tags: enforce-worktree, refactor, module-split, re-export, contract
#
# REGRESSION tests (1-8): verify current contract of hooks/enforce-worktree.js.
#   These must PASS both BEFORE and AFTER the issue #712 module split.
#
# POST-REFACTOR contract tests (9-12): verify the target module layout exists
#   and the renamed export (getWorktreeBaseDir -> getWorktreeBaseDirResolved)
#   is in place. These intentionally FAIL until the refactor lands.
#
# Exit code reflects ONLY regression failures so the test can be checked in
# before the refactor without breaking CI conventions for this file.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
ENFORCE_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
ENFORCE_DIR="${_AGENTS_DIR_NODE}/hooks/enforce-worktree"
CLEANUP_JS="${_AGENTS_DIR_NODE}/hooks/cleanup-orphan-dir.js"

if [ ! -f "$ENFORCE_JS" ]; then
    echo "SKIP: hooks/enforce-worktree.js not present"
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not on PATH"
    exit 0
fi

PASS=0
FAIL=0
REGRESSION_FAIL=0
POST_REFACTOR_FAIL=0

pass_regression() {
    echo "PASS [regression]: $1"
    PASS=$((PASS + 1))
}
fail_regression() {
    echo "FAIL [regression]: $1"
    [ -n "${2:-}" ] && echo "    detail: $2"
    FAIL=$((FAIL + 1))
    REGRESSION_FAIL=$((REGRESSION_FAIL + 1))
}
pass_contract() {
    echo "PASS [post-refactor contract]: $1"
    PASS=$((PASS + 1))
}
fail_contract() {
    echo "FAIL [post-refactor contract]: $1 -- expected until refactor completes"
    [ -n "${2:-}" ] && echo "    detail: $2"
    FAIL=$((FAIL + 1))
    POST_REFACTOR_FAIL=$((POST_REFACTOR_FAIL + 1))
}

run_node() {
    # $1 = label, $2 = node script
    # echo "OK" on success, otherwise non-zero exit + error
    node -e "$2" 2>&1
}

# ─── REGRESSION TESTS ────────────────────────────────────────────────────────

# 1. enforce-worktree.js loads without error
out=$(node -e "require('${ENFORCE_JS}'); console.log('OK');" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "enforce-worktree.js loads without error"
else
    fail_regression "enforce-worktree.js loads without error" "$out"
fi

# 2. setPayloadDerivedPaths / _getPayloadDerivedPaths round-trip
out=$(node -e "
const m = require('${ENFORCE_JS}');
m.setPayloadDerivedPaths(['/a/b', '/c/d']);
const got = m._getPayloadDerivedPaths();
if (Array.isArray(got) && got.length === 2 && got[0] === '/a/b' && got[1] === '/c/d') {
  console.log('OK');
} else {
  console.log('FAIL ' + JSON.stringify(got));
  process.exit(1);
}
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "setPayloadDerivedPaths/_getPayloadDerivedPaths round-trip"
else
    fail_regression "setPayloadDerivedPaths/_getPayloadDerivedPaths round-trip" "$out"
fi

# 3. findFirstUnquotedAnd returns correct index for "git add && git commit"
out=$(node -e "
const { findFirstUnquotedAnd } = require('${ENFORCE_JS}');
const idx = findFirstUnquotedAnd('git add && git commit');
// 'git add ' is 8 chars, then '&&' starts at index 8
if (idx === 8) { console.log('OK'); } else { console.log('FAIL idx=' + idx); process.exit(1); }
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "findFirstUnquotedAnd returns correct index"
else
    fail_regression "findFirstUnquotedAnd returns correct index" "$out"
fi

# 4. parseGitCPath extracts path from "git -C /some/path push"
out=$(node -e "
const { parseGitCPath } = require('${ENFORCE_JS}');
const p = parseGitCPath('git -C /some/path push');
if (p && (p === '/some/path' || p.toLowerCase() === '\\\\some\\\\path' || /some.path\$/.test(p))) {
  console.log('OK');
} else {
  console.log('FAIL ' + JSON.stringify(p));
  process.exit(1);
}
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "parseGitCPath extracts path from git -C arg"
else
    fail_regression "parseGitCPath extracts path from git -C arg" "$out"
fi

# 5. isBranchDeleteCommand detects "git branch -D foo"
out=$(node -e "
const { isBranchDeleteCommand } = require('${ENFORCE_JS}');
if (isBranchDeleteCommand('git branch -D foo') === true) {
  console.log('OK');
} else { console.log('FAIL'); process.exit(1); }
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "isBranchDeleteCommand detects 'git branch -D foo'"
else
    fail_regression "isBranchDeleteCommand detects 'git branch -D foo'" "$out"
fi

# 6. hasGitHooksBypass detects -c core.hooksPath= in command string
out=$(node -e "
const { hasGitHooksBypass } = require('${ENFORCE_JS}');
const cmd = 'git -c core.hooksPath=/dev/null commit -m x';
if (hasGitHooksBypass(cmd) === true) {
  console.log('OK');
} else { console.log('FAIL'); process.exit(1); }
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "hasGitHooksBypass detects -c core.hooksPath= bypass"
else
    fail_regression "hasGitHooksBypass detects -c core.hooksPath= bypass" "$out"
fi

# 7. isAllowedFastForwardMerge allows "git pull --ff-only"
out=$(node -e "
const { isAllowedFastForwardMerge } = require('${ENFORCE_JS}');
if (isAllowedFastForwardMerge('git pull --ff-only') === true) {
  console.log('OK');
} else { console.log('FAIL'); process.exit(1); }
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "isAllowedFastForwardMerge allows 'git pull --ff-only'"
else
    fail_regression "isAllowedFastForwardMerge allows 'git pull --ff-only'" "$out"
fi

# 8. isAllowedNewItemDirectory allows New-Item -ItemType Directory with outside path
# Use a path that is unambiguously outside the agents repo root (/tmp on POSIX,
# C:\Temp on Windows). Both resolve outside any plausible repoRoot.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) OUTSIDE_PATH='C:\\Temp\\enforce-worktree-test-fake' ;;
    *) OUTSIDE_PATH='/tmp/enforce-worktree-test-fake' ;;
esac

# isAllowedNewItemDirectory is currently a module-internal helper (not exported
# pre-refactor). Test it via the exported surface when available; otherwise
# skip gracefully — the function's behavior is exercised indirectly via the
# main hook flow in feature-enforce-worktree-* tests.
out=$(node -e "
const m = require('${ENFORCE_JS}');
if (typeof m.isAllowedNewItemDirectory !== 'function') {
  console.log('SKIP');
  process.exit(0);
}
const cmd = \"New-Item -ItemType Directory -Path '${OUTSIDE_PATH}'\";
const repoRoot = '${_AGENTS_DIR_NODE}';
if (m.isAllowedNewItemDirectory(cmd, repoRoot) === true) {
  console.log('OK');
} else { console.log('FAIL'); process.exit(1); }
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "isAllowedNewItemDirectory allows outside-repo New-Item"
elif [ "$out" = "SKIP" ]; then
    echo "SKIP [regression]: isAllowedNewItemDirectory -- not exported pre-refactor (internal helper); covered by integration tests"
else
    fail_regression "isAllowedNewItemDirectory allows outside-repo New-Item" "$out"
fi

# ─── POST-REFACTOR CONTRACT TESTS ────────────────────────────────────────────

# 9. hooks/enforce-worktree/ directory exists
if [ -d "$ENFORCE_DIR" ]; then
    pass_contract "hooks/enforce-worktree/ directory exists"
else
    fail_contract "hooks/enforce-worktree/ directory exists" "$ENFORCE_DIR missing"
fi

# 10. Each of the 8 planned module files loads without error
MODULES=(
    "config.js"
    "git-repo-detection.js"
    "session-scope.js"
    "git-hooks-bypass.js"
    "shared-cmd-utils.js"
    "branch-delete-guard.js"
    "main-worktree-allows.js"
    "bash-write-scope.js"
)
for mod in "${MODULES[@]}"; do
    modpath="${ENFORCE_DIR}/${mod}"
    if [ -f "$modpath" ]; then
        out=$(node -e "require('${modpath}'); console.log('OK');" 2>&1)
        if [ "$out" = "OK" ]; then
            pass_contract "hooks/enforce-worktree/${mod} loads"
        else
            fail_contract "hooks/enforce-worktree/${mod} loads" "$out"
        fi
    else
        fail_contract "hooks/enforce-worktree/${mod} loads" "file missing"
    fi
done

# 11. enforce-worktree.js exports getWorktreeBaseDirResolved (renamed from getWorktreeBaseDir)
out=$(node -e "
const m = require('${ENFORCE_JS}');
if (typeof m.getWorktreeBaseDirResolved !== 'function') {
  console.log('FAIL typeof=' + typeof m.getWorktreeBaseDirResolved);
  process.exit(1);
}
console.log('OK');
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_contract "enforce-worktree.js exports getWorktreeBaseDirResolved"
else
    fail_contract "enforce-worktree.js exports getWorktreeBaseDirResolved" "$out"
fi

# 12. cleanup-orphan-dir.js uses getWorktreeBaseDirResolved (verifies post-rename import)
# Note: require() does not throw when destructuring a non-existent export — the variable
# is just undefined. A simple require() check would falsely pass. Grep for the symbol instead.
if [ -f "$CLEANUP_JS" ]; then
    if grep -q "getWorktreeBaseDirResolved" "$CLEANUP_JS"; then
        pass_contract "cleanup-orphan-dir.js imports getWorktreeBaseDirResolved (post-rename)"
    else
        fail_contract "cleanup-orphan-dir.js imports getWorktreeBaseDirResolved (post-rename)" "still uses old name getWorktreeBaseDir"
    fi
else
    fail_contract "cleanup-orphan-dir.js imports getWorktreeBaseDirResolved (post-rename)" "file missing"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────

echo "---"
echo "Total: PASS=$PASS FAIL=$FAIL"
echo "Regression failures (must be 0): $REGRESSION_FAIL"
echo "Contract failures (expected pre-refactor): $POST_REFACTOR_FAIL"
if [ "$REGRESSION_FAIL" -eq 0 ]; then
    exit 0
else
    exit 1
fi
