#!/bin/bash
# tests/refactor-workflow-mark-split.sh
# Tests: hooks/workflow-mark.js, hooks/workflow-mark/skip-reason.js, hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-mark/clarify-intent-complete-handler.js, hooks/workflow-mark/branching-handler.js, hooks/workflow-mark/user-verified-handler.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark/premise-gate-handlers.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/workflow-mark/reset-handler.js
# Tags: workflow-mark, refactor, module-split, contract
#
# REGRESSION tests (1): verify current contract of hooks/workflow-mark.js.
#   These must PASS both BEFORE and AFTER the module split.
#   workflow-mark.js has no require.main guard so it cannot be require()'d;
#   regression baseline uses `node --check` for syntax validation instead.
#
# POST-REFACTOR contract tests (2-5): verify the target module layout exists,
#   all 8 sibling modules load, validateSkipReason works correctly, and each
#   handler module exports a handle function with arity 1.
#   These intentionally FAIL until the refactor lands.
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
MARK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-mark.js"
MARK_DIR="${_AGENTS_DIR_NODE}/hooks/workflow-mark"

if [ ! -f "$MARK_JS" ]; then
    echo "SKIP: hooks/workflow-mark.js not present"
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

# 1. hooks/workflow-mark.js has valid JS syntax
#    (cannot be require()'d — no require.main guard; syntax check is the baseline)
out=$(node --check "$MARK_JS" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
    pass_regression "hooks/workflow-mark.js has valid JS syntax"
else
    fail_regression "hooks/workflow-mark.js has valid JS syntax" "$out"
fi

# ─── POST-REFACTOR CONTRACT TESTS ────────────────────────────────────────────

# 2. hooks/workflow-mark/ directory exists
if [ -d "$MARK_DIR" ]; then
    pass_contract "hooks/workflow-mark/ directory exists"
else
    fail_contract "hooks/workflow-mark/ directory exists" "$MARK_DIR missing"
fi

# 3. All 8 module files load without error
MODULES=(
    "skip-reason.js"
    "not-needed-handlers.js"
    "clarify-intent-complete-handler.js"
    "branching-handler.js"
    "user-verified-handler.js"
    "mark-step-handler.js"
    "premise-gate-handlers.js"
    "enforce-override-handlers.js"
    "reset-handler.js"
)
for mod in "${MODULES[@]}"; do
    modpath="${MARK_DIR}/${mod}"
    if [ -f "$modpath" ]; then
        out=$(node -e "require('${modpath}'); console.log('OK');" 2>&1)
        if [ "$out" = "OK" ]; then
            pass_contract "hooks/workflow-mark/${mod} loads without error"
        else
            fail_contract "hooks/workflow-mark/${mod} loads without error" "$out"
        fi
    else
        fail_contract "hooks/workflow-mark/${mod} loads without error" "file missing"
    fi
done

# 4. validateSkipReason from skip-reason.js returns {ok: false} for input "none"
SKIP_REASON_JS="${MARK_DIR}/skip-reason.js"
if [ -f "$SKIP_REASON_JS" ]; then
    out=$(node -e "
const m = require('${SKIP_REASON_JS}');
if (typeof m.validateSkipReason !== 'function') {
  console.log('FAIL: validateSkipReason is not a function, got ' + typeof m.validateSkipReason);
  process.exit(1);
}
const result = m.validateSkipReason('none');
if (result && result.ok === false) {
  console.log('OK');
} else {
  console.log('FAIL: expected {ok: false}, got ' + JSON.stringify(result));
  process.exit(1);
}
" 2>&1)
    if [ "$out" = "OK" ]; then
        pass_contract "validateSkipReason returns {ok: false} for input 'none'"
    else
        fail_contract "validateSkipReason returns {ok: false} for input 'none'" "$out"
    fi
else
    fail_contract "validateSkipReason returns {ok: false} for input 'none'" "skip-reason.js missing"
fi

# 5. Each of the 7 handler modules exports a handle function with arity 1
HANDLER_MODULES=(
    "not-needed-handlers.js"
    "clarify-intent-complete-handler.js"
    "branching-handler.js"
    "user-verified-handler.js"
    "mark-step-handler.js"
    "premise-gate-handlers.js"
    "enforce-override-handlers.js"
    "reset-handler.js"
)
for mod in "${HANDLER_MODULES[@]}"; do
    modpath="${MARK_DIR}/${mod}"
    if [ -f "$modpath" ]; then
        out=$(node -e "
const m = require('${modpath}');
if (typeof m.handle !== 'function') {
  console.log('FAIL: handle is not a function, got ' + typeof m.handle);
  process.exit(1);
}
if (m.handle.length !== 1) {
  console.log('FAIL: handle.length === ' + m.handle.length + ', expected 1');
  process.exit(1);
}
console.log('OK');
" 2>&1)
        if [ "$out" = "OK" ]; then
            pass_contract "hooks/workflow-mark/${mod} exports handle with arity 1"
        else
            fail_contract "hooks/workflow-mark/${mod} exports handle with arity 1" "$out"
        fi
    else
        fail_contract "hooks/workflow-mark/${mod} exports handle with arity 1" "file missing"
    fi
done

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
