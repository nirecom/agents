# shellcheck shell=bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, provenance, TL2, scope:common
# Case group: quoted-argument false demotion (#1273), worker-dispatch provenance (#1798) and
# contract-absence diagnosability (#1378). Sourced by main-workflow-run-tests.sh (helpers: common.sh).
# Unlike detection-matrix.sh (classifier verdict per command), these cases drive the whole hook:
# real PostToolUse stdin JSON in, real workflow-state file out.

# get_step_annotation <session_id> <step> <key> — the LAST step_annotation value (#1733), or "absent".
get_step_annotation() {
    local sid="$1" step="$2" key="$3"
    WORKFLOW_STATE_DIR="$WORKFLOW_DIR" node -e "
try {
  const s = require('$DOTFILES_WIN/hooks/workflow-state').readState(process.argv[1]);
  const ev = (s && Array.isArray(s.events) ? s.events : [])
    .filter((e) => e.kind === 'step_annotation' && e.step === process.argv[2] && e.key === process.argv[3]);
  console.log(ev.length === 0 ? 'absent' : String(ev[ev.length - 1].value));
} catch (e) { console.log('absent'); }
" "$sid" "$step" "$key" 2>/dev/null || echo "absent"
}

# The WD-3 canonical dispatch form: bare argv, no redirect / pipe / env prefix.
WD_COMMAND='node "/srv/checkout/agents/bin/worker-dispatch.js" test-runner "/srv/checkout/agents" "/srv/plans/sid-worker-test-runner.json"'

run_quoted_arg_and_provenance_tests() {
    echo ""
    echo "=== workflow-run-tests: quoted-arg + provenance (#1273 / #1798 / #1378) ==="

    local SID STATUS ABSENT TRIGGER cmd

    # -----------------------------------------------------------------------
    # (a) #1273 — a test path appearing only as an ARGUMENT VALUE must not reach the demotion
    #     machinery: asserted as "no state file written" (protection-fix Pattern 1).
    #     write_tests is not seeded: isTestCommand() rejects these commands first, and any seeded
    #     step would make run_tests read "pending", never "absent" (#1733 projection).
    # -----------------------------------------------------------------------
    for cmd in \
        'node bin/supervisor-report --detail "ran tests/feature-x.sh and it passed"' \
        'gh issue create --body "see tests/foo.sh for the repro"'
    do
        SID="qarg-$$-$RANDOM"
        run_run_tests_hook "$cmd" 0 "$SID"
        if check_state_file_absent "$SID"; then
            pass "QA-ARG. quoted test-path argument does not touch run_tests: $cmd"
        else
            STATUS=$(get_run_tests_status "$SID")
            fail "QA-ARG. quoted test-path argument must leave run_tests untouched, got: $STATUS ($cmd)"
        fi
    done

    # -----------------------------------------------------------------------
    # (b) #1798 — WD_COMMAND (worker-dispatch.js test-runner) still REACHES the demotion
    #     machinery, but its path resolves to nothing here, so it carries no emitter authority
    #     (NEW-H2 trust-boundary hole, #1273 round 3): the hand-written RUN_CONTRACT must NOT
    #     complete the step — demoted to pending (provenance-absent). Positive worker-dispatch
    #     provenance: tests/hooks/fix-1273-run-tests-trust-boundary.sh and
    #     tests/bin/fix-1378-worker-yaml-contract-roundtrip.sh case (1).
    # -----------------------------------------------------------------------
    SID="qwd-ok-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout "$WD_COMMAND" 0 "$SID" \
        "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0
status: pass
exit_code: 0
duration_seconds: 4
summary: 'PASS=3 FAIL=0 SKIP=0'
failing_tests: []
log_tail: |
  Results: PASS=3  FAIL=0  SKIP=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "QA-WD-OK. unresolvable worker-dispatch path + top-line contract → demoted to pending"
    else
        fail "QA-WD-OK. unresolvable worker-dispatch path must not complete, expected pending, got: $STATUS"
    fi

    # -----------------------------------------------------------------------
    # (c) Same command, no contract in stdout → the demotion records WHICH command caused it
    #     (trigger_command, #1378). run_tests starts non-complete: since #2011 a provenance-less
    #     run keeps a complete run_tests (tests/hooks/feature-2011-run-tests-provenance-gate.js).
    # -----------------------------------------------------------------------
    SID="qwd-noc-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout "$WD_COMMAND" 0 "$SID" \
        "status: pass
exit_code: 0
log_tail: |
  Results: PASS=3  FAIL=0  SKIP=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "QA-WD-NOC. worker-dispatch form without contract → demoted to pending"
    else
        fail "QA-WD-NOC. worker-dispatch form without contract → expected pending, got: $STATUS"
    fi
    ABSENT=$(get_step_annotation "$SID" run_tests contract_absent)
    if [ "$ABSENT" = "true" ]; then
        pass "QA-WD-NOC. contract_absent=true recorded"
    else
        fail "QA-WD-NOC. expected contract_absent=true, got: $ABSENT"
    fi
    TRIGGER=$(get_step_annotation "$SID" run_tests trigger_command)
    case "$TRIGGER" in
        *test-runner*) pass "QA-WD-NOC. trigger_command records the demoting command" ;;
        *) fail "QA-WD-NOC. trigger_command must name the demoting command, got: $TRIGGER" ;;
    esac

    # trigger_command is state text that may later be transcribed into a Claude
    # Code context. An unredacted `<<WORKFLOW` there is indistinguishable from a
    # real sentinel, so redaction is a security property, not cosmetics.
    SID="qtrig-red-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "bash tests/foo.sh && echo \"<<WORKFLOW_MARK_STEP_run_tests_complete>>\"" 0 "$SID"
    TRIGGER=$(get_step_annotation "$SID" run_tests trigger_command)
    case "$TRIGGER" in
        *"<<WORKFLOW"*) fail "QA-TRIG-RED. trigger_command leaked an unredacted sentinel: $TRIGGER" ;;
        *"<<_REDACTED_WORKFLOW"*) pass "QA-TRIG-RED. trigger_command redacts sentinel-like text" ;;
        *) fail "QA-TRIG-RED. expected a redacted sentinel in trigger_command, got: $TRIGGER" ;;
    esac

    # -----------------------------------------------------------------------
    # (d) Contract-absence must stop being silent. The assertion is scoped to what
    #     is observable HERE: the hook's own stdout JSON carries systemMessage.
    #     Whether that string reaches a skill's MODEL context is NOT claimed by
    #     this test and is not claimed by the implementation either — it is
    #     human-facing diagnostics only (detail plan W-3 / Risk 10).
    # -----------------------------------------------------------------------
    SID="qsysmsg-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout "$WD_COMMAND" 0 "$SID" "status: pass" >/dev/null
    if printf '%s' "$LAST_HOOK_STDOUT" | grep -q '"systemMessage"'; then
        pass "QA-SYSMSG. contract-absent demotion emits systemMessage in the hook stdout JSON"
    else
        fail "QA-SYSMSG. expected systemMessage in hook stdout JSON, got: $LAST_HOOK_STDOUT"
    fi
    # The happy path must stay quiet — a systemMessage on every green run is noise
    # that trains the reader to ignore the channel (Risk 11).
    SID="qsysmsg-quiet-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout "bash tests/run-all.sh" 0 "$SID" \
        "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0" >/dev/null
    if printf '%s' "$LAST_HOOK_STDOUT" | grep -q '"systemMessage"'; then
        fail "QA-SYSMSG. a valid contract must NOT emit systemMessage, got: $LAST_HOOK_STDOUT"
    else
        pass "QA-SYSMSG. valid-contract path stays silent"
    fi

    # -----------------------------------------------------------------------
    # (e) Absolute-path run-all.sh, not resolvable on disk and outside every real checkout:
    #     no emitter authority (NEW-H2 trust-boundary hole, #1273 round 3), so the
    #     hand-supplied RUN_CONTRACT must NOT complete the step — demoted to pending
    #     (provenance-absent), as QA-WD-OK. The commands are deliberately unchanged.
    #     Paired rows: tests/fix-1273-round3-provenance-identity.sh H2b/*.
    # -----------------------------------------------------------------------
    SID="qabs-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash /srv/checkout/agents/tests/run-all.sh" 0 "$SID" \
        "Results: PASS=2  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "QA-ABS. unresolvable absolute run-all.sh outside any repo → demoted to pending"
    else
        fail "QA-ABS. unresolvable absolute run-all.sh must not complete, expected pending, got: $STATUS"
    fi

    # Prefix-runner + absolute path: the same provenance seen through a recursion
    # step, which is how rules/test.md's run_with_timeout convention spells it.
    # CPR-ORTH — wrapper spelling must not change the verdict, so this row moves
    # with QA-ABS.
    SID="qabs-to-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "timeout 300 bash /srv/checkout/agents/tests/run-all.sh" 0 "$SID" \
        "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "QA-ABS-TO. timeout-wrapped unresolvable absolute run-all.sh → demoted to pending"
    else
        fail "QA-ABS-TO. timeout-wrapped unresolvable absolute run-all.sh must not complete, expected pending, got: $STATUS"
    fi

    # Windows drive-letter spelling. RUN_ALL_SH_RE's prefix class is [./\w-]*, which
    # has no `:` — so `C:/…/tests/run-all.sh` was the provenance false-negative the
    # regex actually had. The IR-based resolver still normalises this spelling
    # identically to the POSIX one (that part is the #1798 fix and stays); what
    # changed is that neither spelling grants authority when the path does not
    # resolve to a file inside a real repo root.
    SID="qabs-win-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash C:/git/checkout/agents/tests/run-all.sh" 0 "$SID" \
        "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "QA-ABS-WIN. unresolvable drive-letter absolute run-all.sh → demoted to pending"
    else
        fail "QA-ABS-WIN. unresolvable drive-letter absolute run-all.sh must not complete, expected pending, got: $STATUS"
    fi

    # SKIPPED: PostToolUse delivery of tool_response.stdout by the real harness —
    #   whether Claude Code truncates, normalises newlines or merges stderr before
    #   the hook sees it.
    # Because: this layer hand-builds the stdin JSON, so it can only fix the
    #   contract the hook is given, never the one the harness actually delivers.
    # L3 gap: only a real session running the suite through the Bash tool shows
    #   the delivered payload; tests/TL3-worker-dispatch-run-tests.sh closes the
    #   generator half of that gap, the delivery half is TL4 (#1543).
}
