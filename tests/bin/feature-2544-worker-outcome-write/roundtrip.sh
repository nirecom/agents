# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced last, after the fixture repo is built.
# Tests: bin/worker-dispatch.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/dispatch-outcome.js
# Tags: worker-dispatch, outcome, run-tests, hook, integration, writer-to-reader, TL2, scope:issue-specific
# Writer to reader: the real dispatcher writes the outcome, the real hook reads it on
# a later unrelated Bash call. No outcome is built by hand anywhere in this fragment.

RT_HOOK_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests.js"
# State seeding and reads reuse the hook-side probe, so both tests name state one way.
RT_PROBE_JS="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2544-dispatch-outcome/probe.js"
F2544_AGENTS="$(np "$SCRIPT_CHECKOUT_ROOT")"
export F2544_AGENTS
RT_LATER_CMD="git status"

rt_probe() { node "$(np "$RT_PROBE_JS")" "$@" 2>/dev/null; }
rt_step() { rt_probe field "$1" run_tests "$2"; }

RT_HOOK_RC=0
# rt_hook <sid> <command> — one PostToolUse delivery of a Bash call that ran no test.
rt_hook() {
    local input
    input="$(rt_probe hook-input "$1" "$2" 0 "")"
    RT_HOOK_RC=0
    (cd "$TMPD" && printf '%s' "$input" | run_with_timeout 60 node "$(np "$RT_HOOK_JS")" >/dev/null 2>&1) || RT_HOOK_RC=$?
}

# rt_dispatch <label> <sid> <stem> <canned> — returns 1 (failing once) when the dispatcher
# left no outcome, so the reader assertions after it never pass on an absent file.
rt_dispatch() {
    local p
    rt_probe prefix "$2"
    p="$(seed_payload "$2" "$3" "$(tr_json)")"
    assert_eq "$1/control-no-outcome-before-the-dispatcher-runs" "no" "$(has_file "$2" "$3.outcome.json")"
    set_canned "$4"
    dispatch test-runner "$p"
    assert_eq "$1/control-dispatcher-exit-0" "0" "$DRC"
    assert_eq "$1/control-later-command-is-no-test-command" "false" \
        "$(rt_probe call hooks/workflow-run-tests/exec-model.js isTestCommand "[\"$RT_LATER_CMD\"]")"
    if [ "$(has_file "$2" "$3.outcome.json")" = "yes" ]; then
        pass "$1/dispatcher-wrote-the-outcome"
        return 0
    fi
    fail "$1/dispatcher-wrote-the-outcome" "no $3.outcome.json in the control dir: $(ctrl_ls "$2")"
    return 1
}

group_roundtrip_pass() {
    local sid="s2544rtpass" stem="worker-test-runner-1" rec
    rt_dispatch "roundtrip-pass" "$sid" "$stem" "$PASS_CANNED" || return 0
    assert_eq "roundtrip-pass/control-stdout-status" "pass" "$(field_of status)"
    assert_eq "roundtrip-pass/control-pending-before-the-later-call" "pending" "$(rt_step "$sid" status)"
    rt_hook "$sid" "$RT_LATER_CMD"
    assert_eq "roundtrip-pass/hook-exit-0" "0" "$RT_HOOK_RC"
    assert_eq "roundtrip-pass/run-tests-complete" "complete" "$(rt_step "$sid" status)"
    assert_eq "roundtrip-pass/run-outcome-pass" "pass" "$(rt_step "$sid" run_outcome)"
    assert_eq "roundtrip-pass/ingested-marker-written" "yes" "$(has_file "$sid" "$stem.ingested")"
    rec="$(rt_step "$sid" outcome_source)"
    assert_has "roundtrip-pass/outcome-source-names-the-stem" "$stem" "$rec"
    assert_has "roundtrip-pass/outcome-source-carries-the-payload-digest" "$(sha_of "$WF_RAW/$sid.control/$stem.json")" "$rec"
    assert_has "roundtrip-pass/outcome-source-carries-the-outcome-digest" "$(sha_of "$WF_RAW/$sid.control/$stem.outcome.json")" "$rec"
}

group_roundtrip_fail() {
    local sid="s2544rtfail" stem="worker-test-runner-1"
    # The canned failing line names this path; the reader checks it against the payload cwd.
    mkdir -p "$REPO_RAW/tests/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$REPO_RAW/tests/bin/a.sh"
    rt_dispatch "roundtrip-fail" "$sid" "$stem" "$FAIL_CANNED" || return 0
    assert_eq "roundtrip-fail/control-stdout-status" "fail" "$(field_of status)"
    rt_probe seed "$sid" run_tests complete
    assert_eq "roundtrip-fail/control-an-earlier-complete-is-in-place" "complete" "$(rt_step "$sid" status)"
    rt_hook "$sid" "$RT_LATER_CMD"
    assert_eq "roundtrip-fail/hook-exit-0" "0" "$RT_HOOK_RC"
    assert_eq "roundtrip-fail/run-tests-not-complete" "pending" "$(rt_step "$sid" status)"
    assert_eq "roundtrip-fail/run-outcome-fail" "fail" "$(rt_step "$sid" run_outcome)"
    assert_eq "roundtrip-fail/failing-list-carried-through" '["tests/bin/a.sh"]' "$(rt_step "$sid" failing_tests)"
    assert_has "roundtrip-fail/outcome-source-names-the-stem" "$stem" "$(rt_step "$sid" outcome_source)"
}

# A dispatch-recorded failing list is the one bin/run-tests-baseline classifies: the
# failing test is committed and recorded as the merge base, so it fails there too and
# every failure is pre-existing. The run-all cache (ledger, base checkouts) stays in TMPD.
group_roundtrip_fail_baseline() {
    local sid="s2544rtbaseline" stem="worker-test-runner-1" base out rc=0
    mkdir -p "$REPO_RAW/tests/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$REPO_RAW/tests/bin/a.sh"
    rt_dispatch "roundtrip-baseline" "$sid" "$stem" "$FAIL_CANNED" || return 0
    rt_hook "$sid" "$RT_LATER_CMD"
    assert_eq "roundtrip-baseline/hook-exit-0" "0" "$RT_HOOK_RC"
    assert_eq "roundtrip-baseline/control-run-outcome-fail" "fail" "$(rt_step "$sid" run_outcome)"
    assert_eq "roundtrip-baseline/control-failing-list-carried-through" '["tests/bin/a.sh"]' "$(rt_step "$sid" failing_tests)"
    git -C "$REPO_RAW" add tests/bin/a.sh >/dev/null 2>&1
    git -C "$REPO_RAW" commit -q --no-verify -m "failing test" >/dev/null 2>&1
    base="$(git -C "$REPO_RAW" rev-parse HEAD)"
    out="$(cd "$TMPD" && run_with_timeout 60 node "$(np "$SCRIPT_CHECKOUT_ROOT/bin/workflow/record-merge-base-baseline")" \
        --session "$sid" --base "$base" --reason "fixture commit" --repo "$MAIN" 2>&1)" || rc=$?
    assert_eq "roundtrip-baseline/control-merge-base-recorded" "0" "$rc"
    assert_has "roundtrip-baseline/control-merge-base-recorded-output" "RECORDED base=$base" "$out"
    rc=0
    out="$(cd "$TMPD" && run_with_timeout 300 env "RUN_ALL_CACHE_DIR=$(np "$TMPD/run-all-cache")" \
        bash "$SCRIPT_CHECKOUT_ROOT/bin/run-tests-baseline" --session "$sid" --worktree "$REPO_RAW" --per-test-timeout 60 2>&1)" || rc=$?
    assert_eq "roundtrip-baseline/baseline-exit-0-all-preexisting" "0" "$rc"
    assert_has "roundtrip-baseline/baseline-classifies-the-dispatched-failure" "BASELINE: preexisting tests/bin/a.sh" "$out"
    assert_eq "roundtrip-baseline/run-tests-completed-by-baseline" "complete" "$(rt_step "$sid" status)"
    assert_eq "roundtrip-baseline/completion-basis-baseline" "baseline-preexisting" "$(rt_step "$sid" completion_basis)"
}

case_begin "roundtrip-passing-dispatch-completes-run-tests-on-a-later-call" "hooks/workflow-run-tests.js"
group_roundtrip_pass
case_end

case_begin "roundtrip-failing-dispatch-carries-the-failing-list" "bin/worker-dispatch.js"
group_roundtrip_fail
case_end

case_begin "roundtrip-dispatched-failing-list-feeds-the-baseline" "hooks/workflow-run-tests/dispatch-outcome.js"
group_roundtrip_fail_baseline
case_end
