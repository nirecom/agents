# shellcheck shell=bash
# tests/hooks/feature-1665-run-outcome/k-unrunnable-contract.sh
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, run-tests, run-outcome, run-contract, unrunnable, hook, TL2, scope:issue-specific
#
# TL2 — the hook against the 6-field RUN_CONTRACT (#2501 D5-3; plan is the SSOT).
# WHY: a parser that stops at EXECUTED=N leaves the suffix after the match, so the
# run-all route reads every green run as stdout-unattributed; and a FAIL=0 run with
# UNRUNNABLE>0 must pend with ONE install-guidance message on both routes.
# EXPECTED RED until D5 lands; K7b is a green regression pin.

K_GREEN6_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0"

K_GREEN4_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5"

K_UNRUN_STDOUT="Running tests/alpha.sh
PASS: alpha
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (2 files)

Results: PASS=3  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"

K_FAIL_UNRUN_STDOUT="Running tests/broken.sh
FAIL: tests/broken.sh (exit 1)
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (2 files)

Results: PASS=2  FAIL=1  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"

K_ALLUNRUN_STDOUT="UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (2 files)

Results: PASS=0  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=2 TIMEOUT=0"

# _k_sysmsg <hook-stdout-json> -> the systemMessage string, or (none).
_k_sysmsg() {
    run_with_timeout 30 node -e '
let o = null;
try { o = JSON.parse(process.argv[1]); } catch (e) {}
process.stdout.write(o && typeof o.systemMessage === "string" ? o.systemMessage : "(none)");
' "$1" 2>/dev/null || echo "(none)"
}

# _k_mentions_count <msg> <n> -> yes when the message names UNRUNNABLE with the
# whole-number count n and points at the `Missing runtimes:` line.
_k_mentions_count() {
    run_with_timeout 30 node -e '
const m = process.argv[1], n = process.argv[2];
const count = new RegExp("UNRUNNABLE[^0-9]*" + n + "(?![0-9])").test(m);
const guide = /Missing runtimes/.test(m);
process.stdout.write(count && guide ? "yes" : "no");
' "$1" "$2" 2>/dev/null || echo "no"
}

run_k_unrunnable_contract_cases() {
    echo ""
    echo "=== k-unrunnable-contract (TL2: 6-field RUN_CONTRACT at the hook) ==="

    local sid out msg_runall msg_worker

    # --- K1: 6-field green contract completes on the run-all direct path ----
    # stdoutAttributed() must still see the contract as the LAST thing in stdout.
    sid="f1665-k1"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$K_GREEN6_STDOUT")"
    assert_eq "K1/6-field-green-status-complete" "complete" "$(step_field "$sid" run_tests status)"
    assert_eq "K1/6-field-green-outcome-pass" "pass" "$(step_field "$sid" run_tests run_outcome)"
    assert_eq "K1/6-field-green-no-demotion-message" "(none)" "$(_k_sysmsg "$out")"

    # --- K2: a legacy 4-field green contract no longer completes (#2501 C3) ---
    # 4 fields cannot say UNRUNNABLE=0, so the run pends and names the stale base.
    sid="f1665-k2"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$K_GREEN4_STDOUT")"
    assert_eq "K2/4-field-green-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_contains "K2/4-field-green-reason-contract-legacy-shape" "(contract-legacy-shape)" "$(_k_sysmsg "$out")"
    assert_eq "K2/4-field-green-outcome-withheld" "(absent)" "$(step_field "$sid" run_tests run_outcome)"

    # --- K3: FAIL=0 UNRUNNABLE=2 on the run-all path ------------------------
    sid="f1665-k3"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$K_UNRUN_STDOUT")"
    msg_runall="$(_k_sysmsg "$out")"
    assert_eq "K3/runall-unrunnable-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_contains "K3/runall-reason-contract-unrunnable" "(contract-unrunnable)" "$msg_runall"
    assert_eq "K3/runall-outcome-unrunnable" "unrunnable" "$(step_field "$sid" run_tests run_outcome)"

    # --- K4: the same run on the worker route (status: unrunnable) ----------
    # The pass-only allowlist vetoes `unrunnable`; contract-unrunnable must still
    # be the reported reason, not worker-status-veto.
    sid="f1665-k4"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0" unrunnable 0)")"
    msg_worker="$(_k_sysmsg "$out")"
    assert_eq "K4/worker-unrunnable-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_contains "K4/worker-reason-contract-unrunnable" "(contract-unrunnable)" "$msg_worker"
    assert_eq "K4/worker-outcome-unrunnable" "unrunnable" "$(step_field "$sid" run_tests run_outcome)"

    # --- K5: one message regardless of route --------------------------------
    if [ "$msg_runall" = "(none)" ] || [ "$msg_worker" = "(none)" ]; then
        fail "K5/same-message-on-both-routes" "a route produced no systemMessage: runall=$msg_runall worker=$msg_worker"
    else
        assert_eq "K5/same-message-on-both-routes" "$msg_runall" "$msg_worker"
    fi

    # --- K6: the message carries the count and the install guidance ---------
    assert_eq "K6/runall-message-names-count-and-missing-runtimes" "yes" "$(_k_mentions_count "$msg_runall" 2)"
    assert_eq "K6/worker-message-names-count-and-missing-runtimes" "yes" "$(_k_mentions_count "$msg_worker" 2)"

    # --- K7: FAIL>0 with UNRUNNABLE>0 keeps the old reasons -----------------
    # A real failure outranks the missing runtime: contract-unrunnable is only
    # for runs whose sole defect is the runtime.
    sid="f1665-k7a"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$K_FAIL_UNRUN_STDOUT")"
    msg_runall="$(_k_sysmsg "$out")"
    assert_contains "K7a/runall-fail-and-unrunnable-reason-contract-invalid" "(contract-invalid)" "$msg_runall"
    case "$msg_runall" in
        *contract-unrunnable*) fail "K7a/runall-fail-and-unrunnable-not-contract-unrunnable" "$msg_runall" ;;
        "(none)") fail "K7a/runall-fail-and-unrunnable-not-contract-unrunnable" "no systemMessage" ;;
        *) pass "K7a/runall-fail-and-unrunnable-not-contract-unrunnable" ;;
    esac

    sid="f1665-k7b"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0" fail 1)")"
    msg_worker="$(_k_sysmsg "$out")"
    assert_contains "K7b/worker-fail-and-unrunnable-reason-worker-status-veto" "(worker-status-veto)" "$msg_worker"
    case "$msg_worker" in
        *contract-unrunnable*) fail "K7b/worker-fail-and-unrunnable-not-contract-unrunnable" "$msg_worker" ;;
        "(none)") fail "K7b/worker-fail-and-unrunnable-not-contract-unrunnable" "no systemMessage" ;;
        *) pass "K7b/worker-fail-and-unrunnable-not-contract-unrunnable" ;;
    esac
    assert_eq "K7b/worker-fail-and-unrunnable-outcome-fail" "fail" "$(step_field "$sid" run_tests run_outcome)"

    # --- K8: every selected test UNRUNNABLE (EXECUTED=0) ---------------------
    # contract-unrunnable carries no executed condition and is ordered before
    # contract-invalid (plan D5-3). Both routes record the same outcome word, so
    # resume logic does not depend on which route ran the suite.
    sid="f1665-k8a"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$K_ALLUNRUN_STDOUT")"
    msg_runall="$(_k_sysmsg "$out")"
    assert_eq "K8a/runall-all-unrunnable-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_contains "K8a/runall-all-unrunnable-reason-contract-unrunnable" "(contract-unrunnable)" "$msg_runall"
    assert_eq "K8a/runall-all-unrunnable-message-names-count" "yes" "$(_k_mentions_count "$msg_runall" 2)"
    assert_eq "K8a/runall-all-unrunnable-outcome-unrunnable" "unrunnable" "$(step_field "$sid" run_tests run_outcome)"

    sid="f1665-k8b"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0 UNRUNNABLE=2 TIMEOUT=0" unrunnable 0)")"
    msg_worker="$(_k_sysmsg "$out")"
    assert_eq "K8b/worker-all-unrunnable-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_contains "K8b/worker-all-unrunnable-reason-contract-unrunnable" "(contract-unrunnable)" "$msg_worker"
    assert_eq "K8b/worker-all-unrunnable-outcome-unrunnable" "unrunnable" "$(step_field "$sid" run_tests run_outcome)"

    # --- K9: anything but whitespace after the contract's fields is no contract ---
    # WHY: a cut-off `UNRUNNABLE=1 TIMEOUT=` used to parse as its 4-field prefix (UNRUNNABLE read
    # as 0) and complete a run whose files never launched. The worker route is the discriminating
    # one: on run-all the suffix already fails stdoutAttributed(). Blanks and a CR still parse.
    # Self-inconsistent counts (EXECUTED != PASS+FAIL+SKIP, TIMEOUT > FAIL) are no contract either.
    # name | reject, accept or legacy (parses as 4 fields: pends, #2501 C3) | contract line
    # (kept byte-exact: only '|' splits)
    local row k9_name k9_want k9_line k9_runall_msg k9_base="RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    local -a k9_rows=(
        "cutoff-timeout-value|reject|$k9_base UNRUNNABLE=1 TIMEOUT="
        "cutoff-pair-half|reject|$k9_base UNRUNNABLE=1"
        "junk-after-fields|reject|$k9_base junk"
        "count-past-exact-integers|reject|RUN_CONTRACT: PASS=99999999999999999999 FAIL=0 SKIP=0 EXECUTED=99999999999999999999"
        "unrunnable-past-exact-integers|reject|$k9_base UNRUNNABLE=9007199254740993 TIMEOUT=0"
        "count-largest-exact-integer|accept|RUN_CONTRACT: PASS=9007199254740991 FAIL=0 SKIP=0 EXECUTED=9007199254740991 UNRUNNABLE=0 TIMEOUT=0"
        "four-largest-exact-integer|legacy|RUN_CONTRACT: PASS=9007199254740991 FAIL=0 SKIP=0 EXECUTED=9007199254740991"
        "inconsistent-executed|reject|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0"
        "inconsistent-legacy-executed|reject|RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=3"
        "inconsistent-timeout-above-fail|reject|$k9_base UNRUNNABLE=0 TIMEOUT=1"
        "four-trailing-blanks|legacy|$k9_base  "$'\t'" "
        "four-trailing-cr|legacy|$k9_base"$'\r'
        "six-trailing-blanks|accept|$k9_base UNRUNNABLE=0 TIMEOUT=0  "$'\t'" "
        "six-trailing-cr|accept|$k9_base UNRUNNABLE=0 TIMEOUT=0"$'\r'
    )
    for row in "${k9_rows[@]}"; do
        IFS='|' read -r k9_name k9_want k9_line <<<"$row"
        sid="f1665-k9w-$k9_name"
        seed_step "$sid" write_tests complete
        out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" "$(_wd_payload "$k9_line" pass 0)")"
        msg_worker="$(_k_sysmsg "$out")"
        sid="f1665-k9r-$k9_name"
        seed_step "$sid" write_tests complete
        k9_runall_msg="$(_k_sysmsg "$(drive_hook "$RUNALL_CMD" 0 "$sid" "Running tests/alpha.sh
PASS: alpha

Results: PASS=1  FAIL=0  SKIP=0
$k9_line")")"
        if [ "$k9_want" = accept ]; then
            assert_eq "K9/$k9_name-worker-status-complete" "complete" "$(step_field "f1665-k9w-$k9_name" run_tests status)"
            assert_eq "K9/$k9_name-runall-status-complete" "complete" "$(step_field "$sid" run_tests status)"
        elif [ "$k9_want" = legacy ]; then
            assert_eq "K9/$k9_name-worker-status-pending" "pending" "$(step_field "f1665-k9w-$k9_name" run_tests status)"
            assert_contains "K9/$k9_name-worker-reason-contract-legacy-shape" "(contract-legacy-shape)" "$msg_worker"
            assert_eq "K9/$k9_name-runall-status-pending" "pending" "$(step_field "$sid" run_tests status)"
            assert_contains "K9/$k9_name-runall-reason-contract-legacy-shape" "(contract-legacy-shape)" "$k9_runall_msg"
        else
            assert_eq "K9/$k9_name-worker-status-pending" "pending" "$(step_field "f1665-k9w-$k9_name" run_tests status)"
            assert_contains "K9/$k9_name-worker-reason-contract-absent" "(contract-absent)" "$msg_worker"
            assert_eq "K9/$k9_name-worker-outcome-withheld" "(absent)" "$(step_field "f1665-k9w-$k9_name" run_tests run_outcome)"
            assert_eq "K9/$k9_name-runall-status-pending" "pending" "$(step_field "$sid" run_tests status)"
        fi
    done
}
