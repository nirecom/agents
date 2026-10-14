# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced after roundtrip.sh (reuses its helpers).
# Tests: bin/worker-dispatch.js, hooks/workflow-run-tests.js, skills/run-tests/scripts/show-dispatch-outcome.sh, bin/workflow/run-tests-baseline-evidence
# Tags: worker-dispatch, outcome, run-tests, baseline, background, WD-BG, integration, e2e, TL2, scope:issue-specific
# #2486: the WD-BG order of a real >600 s run. The background launch's PostToolUse (empty
# stdout) arrives BEFORE the outcome exists; the outcome is ingested only by the later
# display command's PostToolUse, and only then does the baseline evidence CLI see the list.
# hold-stub.js keeps the real dispatcher between its claim and its outcome write, so the
# launch event is delivered while the outcome is provably absent (steps 4 and 6 are the controls).

BB_HOLD_PRELOAD="$CASE_DIR/hold-stub.js"
BB_SHOW_SH="$SCRIPT_CHECKOUT_ROOT/skills/run-tests/scripts/show-dispatch-outcome.sh"
BB_EVIDENCE="$SCRIPT_CHECKOUT_ROOT/bin/workflow/run-tests-baseline-evidence"
BB_ENTERED="$TMPD/bb-hold-entered"
BB_RELEASE="$TMPD/bb-hold-release"
BB_PID=""

# bb_hook <sid> <command> <stdout> — one PostToolUse delivery of a Bash call with this stdout.
bb_hook() {
    local input
    input="$(rt_probe hook-input "$1" "$2" 0 "$3")"
    RT_HOOK_RC=0
    (cd "$TMPD" && printf '%s' "$input" | run_with_timeout 60 node "$(np "$RT_HOOK_JS")" >/dev/null 2>&1) || RT_HOOK_RC=$?
}
# bb_failing <sid> — "<rc>|<stdout>" of the evidence CLI's failing subcommand (newlines as ~).
bb_failing() {
    local o rc=0
    o="$(cd "$TMPD" && run_with_timeout 60 node "$(np "$BB_EVIDENCE")" failing --session "$1" 2>/dev/null)" || rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$o" | tr '\n' '~')"
}
# bb_release_and_wait — always lets the held dispatcher go and reaps it; sets BB_RC.
bb_release_and_wait() {
    : > "$BB_RELEASE"
    BB_RC=0
    if [ -n "$BB_PID" ]; then wait "$BB_PID" || BB_RC=$?; fi
    BB_PID=""
}

group_background_baseline() {
    local sid="s2486bgbase" stem="worker-test-runner-1" p cmd show rc i seq_before list_before
    rt_probe prefix "$sid"
    mkdir -p "$REPO_RAW/tests/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$REPO_RAW/tests/bin/a.sh"
    # Step 2: a >600 s budget, the RNT-7 background path (WD-BG applies above 570 s).
    p="$(seed_payload "$sid" "$stem" "{\"cwd\":\"$MAIN\",\"test_args\":[\"tests/bin/a.sh\"],\"timeout_seconds\":900}")"
    set_canned "$FAIL_CANNED"
    : > "$CALLLOG"
    rm -f "$BB_ENTERED" "$BB_RELEASE"

    # Step 3: the real dispatcher, launched in the background and held after its claim.
    (cd "$TMPD" && exec env "WD_SPAWN_MODULE=$(np "$SPAWN_JS")" "WD_CANNED=$(np "$CANNED")" "WD_CALL_LOG=$(np "$CALLLOG")" \
        "WD_HOLD_ENTERED=$(np "$BB_ENTERED")" "WD_HOLD_RELEASE=$(np "$BB_RELEASE")" \
        node -r "$(np "$PRELOAD")" -r "$(np "$BB_HOLD_PRELOAD")" "$(np "$DISPATCH_JS")" test-runner "$MAIN" "$p" \
        >"$TMPD/bb.out" 2>"$TMPD/bb.err") &
    BB_PID=$!
    i=0
    while [ ! -f "$BB_ENTERED" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
    if [ ! -f "$BB_ENTERED" ]; then
        fail "bg-baseline/dispatcher-reached-the-worker" "no hold entry within 60s: $(head -c 300 "$TMPD/bb.err" 2>/dev/null)"
        bb_release_and_wait
        return 0
    fi
    pass "bg-baseline/dispatcher-reached-the-worker"

    # Step 4 (control): claimed, no outcome yet.
    assert_eq "bg-baseline/control-claim-marker-present" "yes" "$(has_file "$sid" "$stem.dispatched")"
    assert_eq "bg-baseline/control-no-outcome-while-held" "no" "$(has_file "$sid" "$stem.outcome.json")"

    # Step 5: the background launch's own PostToolUse — WD-3 command form, empty stdout.
    cmd="node \"$(np "$DISPATCH_JS")\" test-runner \"$MAIN\" \"$p\""
    assert_eq "bg-baseline/control-launch-command-is-a-test-command" "true" "$(rt_probe is-test-command "$cmd")"
    bb_hook "$sid" "$cmd" ""
    assert_eq "bg-baseline/launch-hook-exit-0" "0" "$RT_HOOK_RC"

    # Step 6 (control): nothing ingested from the launch event.
    [ "$(rt_step "$sid" status)" != "complete" ] && pass "bg-baseline/launch-does-not-complete-run-tests" \
        || fail "bg-baseline/launch-does-not-complete-run-tests" "status=complete before any outcome"
    assert_eq "bg-baseline/launch-records-no-failing-list" "absent" "$(rt_step "$sid" failing_tests)"
    assert_eq "bg-baseline/launch-dispatch-is-unsettled" "$stem" "$(rt_probe unsettled "$sid")"
    show="$(bb_failing "$sid")"
    assert_eq "bg-baseline/evidence-not-classifiable-before-the-outcome" "3" "${show%%|*}"

    # Step 7: release; the dispatcher writes the outcome and exits.
    bb_release_and_wait
    assert_eq "bg-baseline/dispatcher-exit-0" "0" "$BB_RC"
    assert_eq "bg-baseline/outcome-written-after-release" "yes" "$(has_file "$sid" "$stem.outcome.json")"
    # The worker got max(30, 900-5): the >600 s budget is used as-is.
    rc="$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean);
const a=l.length?JSON.parse(l[l.length-1]).args:[];const i=a.indexOf("--deadline");process.stdout.write(i<0?"none":String(a[i+1]));' \
        "$(np "$CALLLOG")" 2>&1)"
    assert_eq "bg-baseline/worker-deadline-is-895" "895" "$rc"

    # Step 8: the real display command, then its PostToolUse.
    cmd="bash \"$(np "$BB_SHOW_SH")\" --session $sid"
    show="$(cd "$TMPD" && run_with_timeout 60 bash "$BB_SHOW_SH" --session "$sid" 2>&1)"
    assert_has "bg-baseline/display-outcome-present" "OUTCOME=present" "$show"
    assert_has "bg-baseline/display-status-fail" "status: fail" "$show"
    bb_hook "$sid" "$cmd" "$show"
    assert_eq "bg-baseline/display-hook-exit-0" "0" "$RT_HOOK_RC"

    # Step 9: ingested by the display call.
    assert_eq "bg-baseline/run-outcome-fail" "fail" "$(rt_step "$sid" run_outcome)"
    assert_eq "bg-baseline/failing-list-recorded" '["tests/bin/a.sh"]' "$(rt_step "$sid" failing_tests)"
    assert_has "bg-baseline/outcome-source-names-the-stem" "$stem" "$(rt_step "$sid" outcome_source)"
    assert_eq "bg-baseline/ingested-marker-written" "yes" "$(has_file "$sid" "$stem.ingested")"
    assert_eq "bg-baseline/run-tests-stays-pending" "pending" "$(rt_step "$sid" status)"

    # Step 10: the baseline evidence CLI now sees the dispatched failing list.
    show="$(bb_failing "$sid")"
    assert_eq "bg-baseline/evidence-exit-0" "0" "${show%%|*}"
    assert_has "bg-baseline/evidence-has-seq" "|SEQ=" "$show"
    assert_has "bg-baseline/evidence-lists-the-failure" "~tests/bin/a.sh" "$show"

    # Step 11 (negative): a second display + hook ingests nothing new.
    seq_before="$(rt_step "$sid" updated_seq)"; list_before="$(rt_step "$sid" failing_tests)"
    show="$(cd "$TMPD" && run_with_timeout 60 bash "$BB_SHOW_SH" --session "$sid" 2>&1)"
    bb_hook "$sid" "$cmd" "$show"
    assert_eq "bg-baseline/redisplay-keeps-updated-seq" "$seq_before" "$(rt_step "$sid" updated_seq)"
    assert_eq "bg-baseline/redisplay-keeps-failing-list" "$list_before" "$(rt_step "$sid" failing_tests)"
}

case_begin "background-dispatch-ingested-by-the-display-call-feeds-the-baseline" "hooks/workflow-run-tests.js"
group_background_baseline
case_end
