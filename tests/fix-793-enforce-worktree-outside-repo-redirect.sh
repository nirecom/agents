#!/bin/bash
# tests/fix-793-enforce-worktree-outside-repo-redirect.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-targets/redirect.js, hooks/lib/bash-write-targets/tee.js, hooks/lib/bash-write-targets/helpers.js
# Tags: worktree, enforce, hook, redirect, shell-expansion, fix-983, fix-878
#
# Unit + integration tests for issue #793: extractRedirectTargets must
# expand a safe, static subset of shell tokens ($HOME, ${HOME}, ~,
# $WORKFLOW_PLANS_DIR) so that out-of-repo redirect writes can be
# allowed by enforce-worktree.js. All other variable expansions remain
# fail-closed (null).
#
# RED before expandStaticShellTokens is implemented in
# hooks/lib/bash-write-targets.js; GREEN after.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets.js"
HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

# Home directory, normalized to forward slashes (so it matches Node's
# os.homedir() return value after the same normalization).
HOME_DIR="$(node -e 'const os=require("os"); process.stdout.write(os.homedir().replace(/\\/g, "/"))')"

# Main worktree path (used by the integration test as CWD so the hook
# sees a main-checkout). git worktree list --porcelain emits "worktree
# <path>" with the FIRST entry being the main worktree.
MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree[[:space:]]+/, ""); print; exit}')"
if [ -n "$MAIN_WT" ] && command -v cygpath >/dev/null 2>&1; then
    MAIN_WT="$(cygpath -u "$MAIN_WT" 2>/dev/null || echo "$MAIN_WT")"
fi

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

call_redirect() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractRedirectTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

# Call extractRedirectTargets with WORKFLOW_PLANS_DIR explicitly set in the
# Node child's environment.
call_redirect_with_wpd() {
    local wpd="$1" cmd="$2"
    MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$wpd" run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractRedirectTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" 2>/dev/null
}

# Call extractRedirectTargets with WORKFLOW_PLANS_DIR unset.
# `env -u` doesn't see bash functions, so invoke node directly with a timeout
# implemented inline.
call_redirect_no_wpd() {
    if command -v timeout >/dev/null 2>&1; then
        env -u WORKFLOW_PLANS_DIR timeout 30 node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractRedirectTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$1" 2>/dev/null
    else
        env -u WORKFLOW_PLANS_DIR node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractRedirectTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$1" 2>/dev/null
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

# Build the expected JSON array containing an absolute path under HOME_DIR.
EXPECTED_HOME_PATH='["'"$HOME_DIR"'/.workflow-plans/f.json"]'
EXPECTED_HOME_FOO_LITERAL='["$HOME/foo"]'

# ─────────────────────────────────────────────────────────────────────────────
# Unit cases — extractRedirectTargets with static shell-token expansion
# ─────────────────────────────────────────────────────────────────────────────

test_expand_home_quoted() {
    # Case 1: "$HOME/..." (double-quoted) → expanded.
    # Outer single quotes prevent Bash from expanding $HOME before reaching node.
    assert_fn_result 'redirect: "$HOME/..." double-quoted → expanded' \
        "$(call_redirect 'printf x > "$HOME/.workflow-plans/f.json"')" \
        "$EXPECTED_HOME_PATH"
}

test_expand_home_unquoted() {
    # Case 2: $HOME/... (unquoted) → expanded.
    assert_fn_result 'redirect: $HOME/... unquoted → expanded' \
        "$(call_redirect 'printf x > $HOME/.workflow-plans/f.json')" \
        "$EXPECTED_HOME_PATH"
}

test_expand_tilde() {
    # Case 3: ~/... → expanded.
    assert_fn_result 'redirect: ~/... → expanded' \
        "$(call_redirect 'printf x > ~/.workflow-plans/f.json')" \
        "$EXPECTED_HOME_PATH"
}

test_expand_brace_home() {
    # Case 4: "${HOME}/..." (brace, double-quoted) → expanded.
    assert_fn_result 'redirect: "${HOME}/..." brace → expanded' \
        "$(call_redirect 'printf x > "${HOME}/.workflow-plans/f.json"')" \
        "$EXPECTED_HOME_PATH"
}

test_singlequoted_home_literal() {
    # Case 5 (C1 critical pin): single-quoted '$HOME/foo' must stay literal —
    # POSIX shells NEVER expand inside single quotes.
    assert_fn_result "redirect: single-quoted '\$HOME/foo' stays literal" \
        "$(call_redirect "printf x > '\$HOME/foo'")" \
        "$EXPECTED_HOME_FOO_LITERAL"
}

test_backslash_escaped_home() {
    # Case 6 (C1 critical pin): "\$HOME/foo" — backslash-escaped dollar
    # signals "do not expand"; fail-closed.
    assert_fn_result 'redirect: "\$HOME/foo" backslash-escaped → null' \
        "$(call_redirect 'printf x > "\$HOME/foo"')" \
        'null'
}

test_workflow_plans_dir_set() {
    # Case 7: $WORKFLOW_PLANS_DIR set in env → expanded to its value.
    assert_fn_result 'redirect: $WORKFLOW_PLANS_DIR set → expanded' \
        "$(call_redirect_with_wpd /c/test-plans 'printf x > $WORKFLOW_PLANS_DIR/state.json')" \
        '["/c/test-plans/state.json"]'
}

test_workflow_plans_dir_unset() {
    # Case 8: $WORKFLOW_PLANS_DIR unset → fail-closed (NOT "/state.json").
    assert_fn_result 'redirect: $WORKFLOW_PLANS_DIR unset → null' \
        "$(call_redirect_no_wpd 'printf x > $WORKFLOW_PLANS_DIR/state.json')" \
        'null'
}

test_unknown_var_unquoted() {
    # Case 9: unknown $FOO unquoted → fail-closed.
    assert_fn_result 'redirect: unknown $FOO unquoted → null' \
        "$(call_redirect 'printf x > $FOO/bar')" \
        'null'
}

test_midpath_home_no_expansion() {
    # Case 10: mid-path $HOME — the $HOME is not at the leading position of
    # the token. Treat as unresolvable unquoted token containing $ → null.
    assert_fn_result 'redirect: mid-path $HOME (unquoted) → null' \
        "$(call_redirect 'echo x > /tmp/$HOME/foo')" \
        'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# Integration — enforce-worktree.js end-to-end
# ─────────────────────────────────────────────────────────────────────────────
#
# Pipe a Bash PreToolUse payload whose command writes to
# "$HOME/.workflow-plans/test.json" (outside the repo). When the hook is run
# from the MAIN worktree CWD, behavior depends on extractRedirectTargets:
#   • Before implementation: target extraction returns null → fail-closed →
#     block ("main worktree" reason).
#   • After implementation: $HOME is expanded → target is outside repo →
#     areAllBashTargetsOutsideSessionScope short-circuits to done() → {}.
#
# Skipped silently if the main worktree path cannot be determined (CI/clone).

test_integration_outside_repo_redirect_allowed() {
    if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
        pass "integration: skipped (main worktree path not resolvable)"
        return
    fi
    local stdin_json got
    stdin_json='{"tool_name":"Bash","tool_input":{"command":"printf x > \"$HOME/.workflow-plans/test.json\""},"session_id":"test-session-793"}'
    got="$(printf '%s' "$stdin_json" | (
        cd "$MAIN_WT" || exit 1
        ENFORCE_WORKTREE=on CLAUDE_SESSION_ID=test-session-793 \
            run_with_timeout 30 node "$HOOK" 2>/dev/null
    ))"
    # After implementation, the hook should allow ({}).
    if [ "$got" = "{}" ]; then
        pass "integration: \$HOME/... redirect from main worktree allowed (got '{}')"
    else
        fail "integration: \$HOME/... redirect from main worktree expected '{}', got '$got'"
    fi
}

# Security pins: mixed expansion — $HOME followed by unresolvable tokens must fail-closed.
test_security_mixed_expansion_pins() {
    # $HOME/$FOO: trailing $FOO is unresolvable → must return null, not "$HOME_DIR/$FOO/file"
    assert_fn_result 'security: $HOME/$FOO mixed → null (fail-closed)' \
        "$(call_redirect 'printf x > $HOME/$FOO/file')" 'null'
    # Double-quoted "$HOME/$(pwd)/file": command substitution in remainder → null
    assert_fn_result 'security: "$HOME/$(pwd)/file" → null (fail-closed)' \
        "$(call_redirect 'printf x > "$HOME/$(pwd)/file"')" 'null'
    # ${HOME} balanced brace form OK — regression: must still expand
    assert_fn_result 'security: ${HOME}/... balanced braces → expanded' \
        "$(call_redirect 'printf x > ${HOME}/.workflow-plans/f.json')" \
        '["'"$HOME_DIR"'/.workflow-plans/f.json"]'
    # $HOME} unbalanced (trailing }) → null (brace mismatch, not a known expansion)
    assert_fn_result 'security: $HOME}/file unbalanced brace → null' \
        "$(call_redirect 'printf x > $HOME}/file')" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# V-series: Approach C — generic env var expansion constrained to plans-dir
# (#983 / #878). A "$<VAR>"-prefixed target whose env value resolves UNDER
# WORKFLOW_PLANS_DIR may be expanded. If the value is outside plans-dir,
# the var is unset, or the resulting path escapes via "..", the expansion
# must fail-closed (null).
# ─────────────────────────────────────────────────────────────────────────────

# Call extractRedirectTargets with multiple env vars: WORKFLOW_PLANS_DIR + extras.
# extra_env is a single string of KEY=VALUE pairs (space-separated) or empty.
call_redirect_with_envs() {
    local wpd="$1" extra_env="$2" cmd="$3"
    if command -v timeout >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$wpd" env $extra_env timeout 30 node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractRedirectTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$cmd" 2>/dev/null
    else
        MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$wpd" env $extra_env node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractRedirectTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$cmd" 2>/dev/null
    fi
}

# Call extractTeeTargets with WORKFLOW_PLANS_DIR + extras.
call_tee_with_envs() {
    local wpd="$1" extra_env="$2" cmd="$3"
    if command -v timeout >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$wpd" env $extra_env timeout 30 node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractTeeTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$cmd" 2>/dev/null
    else
        MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$wpd" env $extra_env node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractTeeTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$cmd" 2>/dev/null
    fi
}

# Call extractTeeTargets with no extra env (literal/static cases only).
call_tee() {
    if command -v timeout >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 timeout 30 node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractTeeTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$1" 2>/dev/null
    else
        MSYS_NO_PATHCONV=1 node -e "
          try {
            const m = require('$MODULE');
            const r = m.extractTeeTargets(process.argv[1]);
            console.log(JSON.stringify(r));
          } catch (e) { console.log('ERROR: ' + e.message); }
        " -- "$1" 2>/dev/null
    fi
}

# Use /c/test-plans as a fake plans dir for V cases (matches existing Case 7 style).
V_PLANS_DIR='/c/test-plans'

test_V1_state_path_double_quoted() {
    # V1: "$STATE_PATH" → env value points inside plans dir → expanded.
    assert_fn_result 'V1: "$STATE_PATH" → plans-dir → expanded' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "STATE_PATH=$V_PLANS_DIR/state.json" \
            'printf x > "$STATE_PATH"')" \
        '["/c/test-plans/state.json"]'
}

test_V2_state_file_dot_suffix() {
    # V2: "$STATE_FILE.tmp" — identifier followed by `.` (C1 fix).
    assert_fn_result 'V2: "$STATE_FILE.tmp" → plans-dir with suffix → expanded' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "STATE_FILE=$V_PLANS_DIR/state.json" \
            'printf x > "$STATE_FILE.tmp"')" \
        '["/c/test-plans/state.json.tmp"]'
}

test_V3_brace_form_lower() {
    # V3: "${state_path}" brace form, lowercase identifier — also accepted.
    assert_fn_result 'V3: "${state_path}" brace form → expanded' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "state_path=$V_PLANS_DIR/state.json" \
            'printf x > "${state_path}"')" \
        '["/c/test-plans/state.json"]'
}

test_V4_outside_plans_dir() {
    # V4: env value resolves OUTSIDE plans dir → null (fail-closed).
    assert_fn_result 'V4: "$STATE_PATH" → outside plans-dir → null' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "STATE_PATH=/tmp/elsewhere.json" \
            'printf x > "$STATE_PATH"')" \
        'null'
}

test_V5_unset_envvar() {
    # V5: env var unset → null (fail-closed, Case 9 preserved for unknown vars).
    # Make sure UNKNOWN_ENVVAR_XYZ_983 is not in the environment.
    assert_fn_result 'V5: "$UNKNOWN_ENVVAR_XYZ_983" unset → null' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "" \
            'printf x > "$UNKNOWN_ENVVAR_XYZ_983"')" \
        'null'
}

test_V6_path_traversal() {
    # V6: "$STATE_PATH/../../outside" — STATE_PATH is one level deep, so two ".."
    # escapes above plans-dir → null (path-traversal blocked, C2).
    assert_fn_result 'V6: "$STATE_PATH/../../outside" → path-traversal → null' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "STATE_PATH=$V_PLANS_DIR/sub" \
            'printf x > "$STATE_PATH/../../outside"')" \
        'null'
}

test_V7_tee_double_quoted_envvar() {
    # V7: tee "$state_path" → tee target extracted (symmetric tee fix, C3).
    assert_fn_result 'V7: tee "$state_path" → plans-dir → expanded' \
        "$(call_tee_with_envs "$V_PLANS_DIR" "state_path=$V_PLANS_DIR/state.json" \
            'tee "$state_path"')" \
        '["/c/test-plans/state.json"]'
}

test_V8_tee_single_quoted_literal() {
    # V8: tee '$state_path' single-quoted → POSIX literal (single-quote contract).
    assert_fn_result "V8: tee '\$state_path' single-quoted → literal" \
        "$(call_tee "tee '\$state_path'")" \
        '["$state_path"]'
}

test_V_security_path_traversal_etc_passwd() {
    # Security: "$STATE_PATH/../../../etc/passwd" — must fail-closed even when
    # STATE_PATH resolves inside plans dir.
    assert_fn_result 'V-security: "$STATE_PATH/../../../etc/passwd" → null (path-traversal)' \
        "$(call_redirect_with_envs "$V_PLANS_DIR" "STATE_PATH=$V_PLANS_DIR/state.json" \
            'printf x > "$STATE_PATH/../../../etc/passwd"')" \
        'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_expand_home_quoted
test_expand_home_unquoted
test_expand_tilde
test_expand_brace_home
test_singlequoted_home_literal
test_backslash_escaped_home
test_workflow_plans_dir_set
test_workflow_plans_dir_unset
test_unknown_var_unquoted
test_midpath_home_no_expansion
test_security_mixed_expansion_pins
test_integration_outside_repo_redirect_allowed
test_V1_state_path_double_quoted
test_V2_state_file_dot_suffix
test_V3_brace_form_lower
test_V4_outside_plans_dir
test_V5_unset_envvar
test_V6_path_traversal
test_V7_tee_double_quoted_envvar
test_V8_tee_single_quoted_literal
test_V_security_path_traversal_etc_passwd

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
