#!/bin/bash
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-targets/rm.js
# Tags: worktree, enforce, hook, rm, bash-write-targets, scope:issue-specific
#
# Verifies that extractRmTargets resolves bare $VAR tokens against the caller
# environment (NEW behaviour in fix #1095), while keeping fail-closed for
# undefined vars, composite suffixes, ${VAR} form, values with spaces or
# glob chars, command substitution, and ${VAR} brace form.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

assert_fn_result() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# call_rm CMD [VAR=value ...]
# Runs node with optional env vars injected via --env-var KEY=VALUE pairs.
# Extra args after CMD are passed as NODE_ENV_PAIRS (space-separated KEY=VALUE).
call_rm() {
    local cmd="$1"; shift
    # Build env injection snippet from remaining KEY=VALUE pairs
    local env_setup=""
    for pair in "$@"; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        # Escape for JS string (single-backslash paths on Windows need doubling)
        local val_esc
        val_esc="$(printf '%s' "$val" | sed 's/\\/\\\\/g; s/'"'"'/\\'"'"'/g')"
        env_setup="${env_setup}process.env['${key}'] = '${val_esc}';"
    done
    run_with_timeout 30 node -e "
      try {
        ${env_setup}
        const m = require('$MODULE');
        const r = m.extractRmTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# L3 gap: these tests call extractRmTargets directly (unit). They do not test
# the full enforce-worktree hook pipeline (PreToolUse event, path-outside-repo
# check, allow-list logic). An L3 test would fire a real rm command inside a
# Claude Code session and observe whether the hook blocks or allows it.
# ─────────────────────────────────────────────────────────────────────────────

test_rm_var_resolution() {
    # NEW BEHAVIOR (will fail until rm.js tokenizeRmArgs is fixed):
    # $VAR with a defined, simple-path value → resolves to the path.
    assert_fn_result 'rm -rf "$SCRATCHPAD" (defined) → ["/tmp/test-scratch"]' \
        "$(call_rm 'rm -rf "$SCRATCHPAD"' 'SCRATCHPAD=/tmp/test-scratch')" \
        '["/tmp/test-scratch"]'

    # EXISTING BEHAVIOR (must pass now and after fix):
    # $VAR not set → null (fail-closed, unresolvable).
    assert_fn_result 'rm -rf "$UNDEFINED_VAR" (unset) → null' \
        "$(call_rm 'rm -rf "$UNDEFINED_VAR"')" \
        'null'

    # NEW BEHAVIOR (will fail until rm.js tokenizeRmArgs is fixed):
    # $VAR with a literal suffix ($SCRATCHPAD/child) → resolves to env+suffix.
    # detail.md Step 3 allows the simple-form $VAR and $VAR/<literal-suffix>.
    assert_fn_result 'rm -rf "$SCRATCHPAD/child" (literal suffix) → ["/tmp/child"]' \
        "$(call_rm 'rm -rf "$SCRATCHPAD/child"' 'SCRATCHPAD=/tmp')" \
        '["/tmp/child"]'

    # ${VAR} brace form → null (fail-closed; only bare $VAR is resolved).
    assert_fn_result 'rm -rf "${SCRATCHPAD}" (brace form) → null' \
        "$(call_rm 'rm -rf "${SCRATCHPAD}"' 'SCRATCHPAD=/tmp')" \
        'null'

    # $VAR resolves to a value containing a space → null (fail-closed).
    assert_fn_result 'rm -rf "$SCRATCHPAD" with space in value → null' \
        "$(call_rm 'rm -rf "$SCRATCHPAD"' 'SCRATCHPAD=/path with space')" \
        'null'

    # $VAR resolves to a value containing a glob char (*) → null (fail-closed).
    assert_fn_result 'rm -rf "$SCRATCHPAD" with glob in value → null' \
        "$(call_rm 'rm -rf "$SCRATCHPAD"' 'SCRATCHPAD=/path/with*glob')" \
        'null'

    # Command substitution $(cmd) → null (fail-closed, isUnresolvableToken).
    assert_fn_result 'rm -rf "$(cmd)" → null' \
        "$(call_rm 'rm -rf "$(cmd)"')" \
        'null'
}

test_rm_var_resolution

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
