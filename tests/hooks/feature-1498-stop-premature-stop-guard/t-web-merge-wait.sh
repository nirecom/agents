# t-web-merge-wait.sh — T19-T22 (#2527 4-4): C4 exemption human-web-merge-wait
# Tests: hooks/stop-premature-stop-guard.js
# Tags: scope:issue-specific, workflow, release-phase, stop-guard
# Sourced by tests/hooks/feature-1498-stop-premature-stop-guard.sh
# TL3 gap (not caught here): a live Stop event while the background wait-web-merge.sh poller runs.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration
_T_WM_ROOT=""

# The hook finds bin/workflow/next-step from its own real path, so cases run a copied
# checkout whose next-step is a stub printing $T_WM_NEXT_STEP_OUT verbatim.
_t_wm_fixture() {
    [ -n "$_T_WM_ROOT" ] && return 0
    _T_WM_ROOT="$_ISOLATION_TMP_ROOT/t-wm-checkout"
    mkdir -p "$_T_WM_ROOT/bin/workflow"
    printf '%s\n' '#!/usr/bin/env node' 'process.stdout.write(process.env.T_WM_NEXT_STEP_OUT || "");' \
        > "$_T_WM_ROOT/bin/workflow/next-step"
    script_checkout_fixture_copy "$_T_WM_ROOT" hooks bin
}

# _t_wm_run <tmp> <sid> <next-step stdout> — prints "<exit>|<hook stdout>".
_t_wm_run() {
    local tmp="$1" sid="$2" ns_out="$3" hook out rc
    hook="$_T_WM_ROOT/hooks/stop-premature-stop-guard.js"
    command -v cygpath >/dev/null 2>&1 && hook="$(cygpath -m "$hook")"
    git init -q "$tmp/repo" >/dev/null 2>&1
    git -C "$tmp/repo" config core.hooksPath /dev/null
    out="$(cd "$tmp/repo" && echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | T_WM_NEXT_STEP_OUT="$ns_out" WORKFLOW_STATE_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 30 node "$hook" 2>/dev/null)"
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

_t_wm_case() {
    local sid="$1" ns_out="$2" tmp res
    tmp="$(mktemp -d)"
    seed_workflow_state "$tmp" "$sid" "invoke"
    res="$(_t_wm_run "$tmp" "$sid" "$ns_out")"
    rm -rf "$tmp"
    printf '%s' "$res"
}

# T19: ACTION=invoke + WAIT=human-web-merge -> exempt (exit 0, no block).
run_t19() {
    require_source "$HOOK" "T19: WAIT=human-web-merge exempts C4" || return
    _t_wm_fixture
    local res
    res="$(_t_wm_case t19-sid "$(printf 'ACTION=invoke\nNEXT_SKILL=get-release-approval\nWAIT=human-web-merge\nREASON=web-merge-pending\n')")"
    if [ "${res%%|*}" = "0" ] && ! printf '%s' "$res" | grep -q '"block"'; then
        pass "T19: WAIT=human-web-merge -> exit 0, no block"
    else
        fail "T19: expected exit 0 without block for WAIT=human-web-merge (got=$res)"
    fi
}

# T20: ACTION=blocked (e.g. PR closed without merge) -> not invoke, exit 0.
run_t20() {
    require_source "$HOOK" "T20: ACTION=blocked passes C4" || return
    _t_wm_fixture
    local res
    res="$(_t_wm_case t20-sid "$(printf 'ACTION=blocked\nNEXT_HINT=PR was closed without merge; reopen or re-run /commit-push\n')")"
    if [ "${res%%|*}" = "0" ] && ! printf '%s' "$res" | grep -q '"block"'; then
        pass "T20: ACTION=blocked -> exit 0, no block"
    else
        fail "T20: expected exit 0 without block for ACTION=blocked (got=$res)"
    fi
}

# T21: control — ACTION=invoke without WAIT still blocks (exit 2, decision:block).
run_t21() {
    require_source "$HOOK" "T21: invoke without WAIT still blocks" || return
    _t_wm_fixture
    local res
    res="$(_t_wm_case t21-sid "$(printf 'ACTION=invoke\nNEXT_SKILL=get-release-approval\n')")"
    if [ "${res%%|*}" = "2" ] && printf '%s' "$res" | grep -q '{"decision":"block"'; then
        pass "T21: invoke without WAIT -> exit 2 + decision:block"
    else
        fail "T21: expected exit 2 with {\"decision\":\"block\" (got=$res)"
    fi
}

# T22: the exemption matches WAIT=human-web-merge exactly — any other WAIT value, including one
# carrying it as a prefix, still blocks (exit 2, decision:block).
run_t22() {
    require_source "$HOOK" "T22: a non-exact WAIT still blocks" || return
    _t_wm_fixture
    local w res
    for w in other human-web-merge-x; do
        res="$(_t_wm_case "t22-$w-sid" "$(printf 'ACTION=invoke\nNEXT_SKILL=get-release-approval\nWAIT=%s\n' "$w")")"
        if [ "${res%%|*}" = "2" ] && printf '%s' "$res" | grep -q '{"decision":"block"'; then
            pass "T22: invoke with WAIT=$w -> exit 2 + decision:block"
        else
            fail "T22: expected exit 2 with {\"decision\":\"block\" for WAIT=$w (got=$res)"
        fi
    done
}
