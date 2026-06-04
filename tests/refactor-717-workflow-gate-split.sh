#!/bin/bash
# tests/refactor-717-workflow-gate-split.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/path-normalize.js, hooks/workflow-gate/staged-evidence.js, hooks/workflow-gate/gh-detect.js, hooks/workflow-gate/worktree-context.js, hooks/workflow-gate/repo-resolution.js
# Tags: refactor, workflow-gate, module-split, exports
#
# REGRESSION tests (1-2): verify current contract of hooks/workflow-gate.js.
#   These must PASS both BEFORE and AFTER the module split.
#
# POST-REFACTOR contract tests (3-11): verify the target module layout exists,
#   all sibling modules load, each exports the planned symbols, the shim is
#   within the 500-line HARD limit, and key logic is correct.
#   These intentionally FAIL until the refactor (#717) lands.
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
GATE_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"
GATE_DIR="${_AGENTS_DIR_NODE}/hooks/workflow-gate"

if [ ! -f "$GATE_JS" ]; then
    echo "SKIP: hooks/workflow-gate.js not present"
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

# ─── REGRESSION TESTS ────────────────────────────────────────────────────────

# 1. hooks/workflow-gate.js loads without error (require() safe due to require.main guard)
out=$(node -e "require('${GATE_JS}'); console.log('OK');" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "hooks/workflow-gate.js loads without error"
else
    fail_regression "hooks/workflow-gate.js loads without error" "$out"
fi

# 2. hooks/workflow-gate.js exports all 9 expected functions
out=$(node -e "
const m = require('${GATE_JS}');
const expected = [
  'resolveRepoDir',
  'hasStagedTestChanges',
  'hasStagedDocChanges',
  'hasWorktreeNotesDocEvidence',
  'isWorktreeContext',
  'isDocsOnlyStaged',
  'resolveExternalDocsRepo',
  'hasStagedChanges',
  'findAdditionalDirectories',
];
const missing = expected.filter(name => typeof m[name] !== 'function');
if (missing.length === 0) {
  console.log('OK');
} else {
  console.log('FAIL: missing exports: ' + missing.join(', '));
  process.exit(1);
}
" 2>&1)
if [ "$out" = "OK" ]; then
    pass_regression "hooks/workflow-gate.js exports all 9 named functions"
else
    fail_regression "hooks/workflow-gate.js exports all 9 named functions" "$out"
fi

# ─── POST-REFACTOR CONTRACT TESTS ────────────────────────────────────────────

# 3. hooks/workflow-gate/path-normalize.js loads and exports normalizeForWindows as a function
PATHNORM_JS="${GATE_DIR}/path-normalize.js"
if [ -f "$PATHNORM_JS" ]; then
    out=$(node -e "
const m = require('${PATHNORM_JS}');
if (typeof m.normalizeForWindows !== 'function') {
  console.log('FAIL: normalizeForWindows is ' + typeof m.normalizeForWindows);
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "hooks/workflow-gate/path-normalize.js loads and exports normalizeForWindows"
    else
        fail_contract "hooks/workflow-gate/path-normalize.js loads and exports normalizeForWindows" "$out"
    fi
else
    fail_contract "hooks/workflow-gate/path-normalize.js loads and exports normalizeForWindows" "file missing"
fi

# 4. hooks/workflow-gate/staged-evidence.js loads and exports 6 symbols
#    (DOCS_ONLY_ALLOWLIST as RegExp/array, plus 5 functions)
STAGED_JS="${GATE_DIR}/staged-evidence.js"
if [ -f "$STAGED_JS" ]; then
    out=$(node -e "
const m = require('${STAGED_JS}');
const fns = ['hasStagedTestChanges','isDocsOnlyStaged','resolveExternalDocsRepo','hasStagedDocChanges','hasStagedChanges'];
const missingFns = fns.filter(n => typeof m[n] !== 'function');
if (missingFns.length > 0) {
  console.log('FAIL: missing functions: ' + missingFns.join(', '));
  process.exit(1);
}
if (!m.DOCS_ONLY_ALLOWLIST) {
  console.log('FAIL: DOCS_ONLY_ALLOWLIST not exported');
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "hooks/workflow-gate/staged-evidence.js loads and exports 6 symbols"
    else
        fail_contract "hooks/workflow-gate/staged-evidence.js loads and exports 6 symbols" "$out"
    fi
else
    fail_contract "hooks/workflow-gate/staged-evidence.js loads and exports 6 symbols" "file missing"
fi

# 5. hooks/workflow-gate/gh-detect.js loads and exports findGhInPath, toMsys2Path, hasOpenPrForBranch
GHDETECT_JS="${GATE_DIR}/gh-detect.js"
if [ -f "$GHDETECT_JS" ]; then
    out=$(node -e "
const m = require('${GHDETECT_JS}');
const fns = ['findGhInPath','toMsys2Path','hasOpenPrForBranch'];
const missing = fns.filter(n => typeof m[n] !== 'function');
if (missing.length > 0) {
  console.log('FAIL: missing: ' + missing.join(', '));
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "hooks/workflow-gate/gh-detect.js loads and exports 3 functions"
    else
        fail_contract "hooks/workflow-gate/gh-detect.js loads and exports 3 functions" "$out"
    fi
else
    fail_contract "hooks/workflow-gate/gh-detect.js loads and exports 3 functions" "file missing"
fi

# 6. hooks/workflow-gate/worktree-context.js loads and exports isWorktreeContext, isLinkedWorktree, hasWorktreeNotesDocEvidence
WTCTX_JS="${GATE_DIR}/worktree-context.js"
if [ -f "$WTCTX_JS" ]; then
    out=$(node -e "
const m = require('${WTCTX_JS}');
const fns = ['isWorktreeContext','isLinkedWorktree','hasWorktreeNotesDocEvidence'];
const missing = fns.filter(n => typeof m[n] !== 'function');
if (missing.length > 0) {
  console.log('FAIL: missing: ' + missing.join(', '));
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "hooks/workflow-gate/worktree-context.js loads and exports 3 functions"
    else
        fail_contract "hooks/workflow-gate/worktree-context.js loads and exports 3 functions" "$out"
    fi
else
    fail_contract "hooks/workflow-gate/worktree-context.js loads and exports 3 functions" "file missing"
fi

# 7. hooks/workflow-gate/repo-resolution.js loads and exports findAdditionalDirectories, resolveRepoDir
REPORES_JS="${GATE_DIR}/repo-resolution.js"
if [ -f "$REPORES_JS" ]; then
    out=$(node -e "
const m = require('${REPORES_JS}');
const fns = ['findAdditionalDirectories','resolveRepoDir'];
const missing = fns.filter(n => typeof m[n] !== 'function');
if (missing.length > 0) {
  console.log('FAIL: missing: ' + missing.join(', '));
  process.exit(1);
}
console.log('OK');
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "hooks/workflow-gate/repo-resolution.js loads and exports 2 functions"
    else
        fail_contract "hooks/workflow-gate/repo-resolution.js loads and exports 2 functions" "$out"
    fi
else
    fail_contract "hooks/workflow-gate/repo-resolution.js loads and exports 2 functions" "file missing"
fi

# 8. shim file line count is ≤500 (HARD CI gate: file-split.md >500 lines HARD)
GATE_JS_PATH="${AGENTS_DIR}/hooks/workflow-gate.js"
line_count=$(wc -l < "$GATE_JS_PATH" | tr -d ' ')
if [ "$line_count" -le 500 ]; then
    pass_contract "hooks/workflow-gate.js shim is ≤500 lines (currently $line_count)"
else
    fail_contract "hooks/workflow-gate.js shim is ≤500 lines (currently $line_count)" "HARD limit exceeded: must split"
fi

# 9. Cross-module wiring: repo-resolution.js require chain resolves without cycles
#    (loading repo-resolution transitively loads path-normalize, staged-evidence, worktree-context)
if [ -f "$REPORES_JS" ]; then
    out=$(node -e "
// Require repo-resolution; if it imports its siblings they should load cleanly too
try {
  require('${REPORES_JS}');
  console.log('OK');
} catch (e) {
  console.log('FAIL: ' + e.message);
  process.exit(1);
}
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "repo-resolution.js require chain resolves without cycles"
    else
        fail_contract "repo-resolution.js require chain resolves without cycles" "$out"
    fi
else
    fail_contract "repo-resolution.js require chain resolves without cycles" "repo-resolution.js missing"
fi

# 10. normalizeForWindows converts /c/foo to C:\foo (Windows path normalization)
if [ -f "$PATHNORM_JS" ]; then
    out=$(node -e "
const { normalizeForWindows } = require('${PATHNORM_JS}');
const result = normalizeForWindows('/c/foo');
// On all platforms this should produce the canonical Windows form C:\foo
if (result === 'C:\\\\foo') {
  console.log('OK');
} else {
  console.log('FAIL: got ' + JSON.stringify(result) + ', expected C:\\\\foo');
  process.exit(1);
}
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "normalizeForWindows converts /c/foo to C:\\foo"
    else
        fail_contract "normalizeForWindows converts /c/foo to C:\\foo" "$out"
    fi
else
    fail_contract "normalizeForWindows converts /c/foo to C:\\foo" "path-normalize.js missing"
fi

# 11. DOCS_ONLY_ALLOWLIST is a non-empty RegExp (or array-like) value
if [ -f "$STAGED_JS" ]; then
    out=$(node -e "
const { DOCS_ONLY_ALLOWLIST } = require('${STAGED_JS}');
if (!DOCS_ONLY_ALLOWLIST) {
  console.log('FAIL: DOCS_ONLY_ALLOWLIST is falsy');
  process.exit(1);
}
// Accept RegExp or non-empty Array
if (DOCS_ONLY_ALLOWLIST instanceof RegExp) {
  console.log('OK');
} else if (Array.isArray(DOCS_ONLY_ALLOWLIST) && DOCS_ONLY_ALLOWLIST.length > 0) {
  console.log('OK');
} else {
  console.log('FAIL: unexpected type/value: ' + typeof DOCS_ONLY_ALLOWLIST);
  process.exit(1);
}
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "DOCS_ONLY_ALLOWLIST is a non-empty RegExp or array"
    else
        fail_contract "DOCS_ONLY_ALLOWLIST is a non-empty RegExp or array" "$out"
    fi
else
    fail_contract "DOCS_ONLY_ALLOWLIST is a non-empty RegExp or array" "staged-evidence.js missing"
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
