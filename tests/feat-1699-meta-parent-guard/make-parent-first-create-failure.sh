# tests/feat-1699-meta-parent-guard/make-parent-first-create-failure.sh
# Tests: bin/github-issues/issue-create-dispatch.sh
# Tags: issue-create, dispatch, make-parent, orphan, failure-path, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether a real `gh issue create` that fails AFTER the issue was actually opened
#   (transport error on the response, not the request) is distinguishable at all. The mock
#   fails before creating anything, so "no parent exists" is an assumption here.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Group N — make-parent when the FIRST create fails.
#
# E1..E5 in make-parent-preflight.sh pin "parent exists, proposal does not". The mirror —
# the parent create itself fails, so NO parent exists — allows two silent wrong behaviours:
#
#   (i)  report a parent that does not exist: the issue number is read out of an empty URL,
#        so a naive path prints `Stranded meta parent: # — ` and sends the operator hunting;
#   (ii) create the proposal anyway, producing a real, unattached, UNREPORTED orphan — the
#        exact outcome the guard design exists to prevent, through the back door.
#
# Both are asserted as absences, plus the positive facts that make those absences
# meaningful (the run was attempted, and it failed loudly).

setup_mock
export GH_MOCK_ISSUE_NUMS="701,702"
export GH_MOCK_CREATE_FAIL_FROM=1   # the PARENT create is the one that fails
run_dispatch --verdict make-parent --children 11,12 -- \
    --title "dispatcher drops the last manifest row" --body "$(printf "$CANONICAL_BODY")"

if [ "$RC" -ne 0 ]; then
    pass "N1-first-create-failure-nonzero-rc"
else
    fail "N1-first-create-failure-nonzero-rc" "want non-zero rc when the meta parent could not be created (got: $RC); stdout: $OUT"
fi

# Positive control: a dispatcher that rejected the argv before reaching gh would create
# nothing, report nothing, and satisfy every absence assertion below.
n=$(count_creates)
if [ "${n:-0}" -ge 1 ]; then
    pass "N1b-first-create-was-actually-attempted"
else
    fail "N1b-first-create-was-actually-attempted" "the run never reached a 'gh issue create' (got: ${n:-0}) — the failure under test was not exercised"
fi

# (ii) No orphan: with the parent failed there is nothing left to attach the proposal to.
if [ "${n:-0}" -eq 1 ]; then
    pass "N2-no-proposal-created-after-the-parent-failed"
else
    fail "N2-no-proposal-created-after-the-parent-failed" "want exactly 1 create attempt (the failed parent); got ${n:-0} — the proposal was created with no parent to hold it"
fi
a=$(count_attaches)
if [ "${a:-0}" -eq 0 ]; then
    pass "N2b-no-attach-attempted"
else
    fail "N2b-no-attach-attempted" "want 0 sub_issues POSTs (got: ${a:-0}) — attaching under a parent that was never created cannot succeed and hides the real error"
fi

# stdout is the URL contract: every line claims an issue exists. Nothing was created.
if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
    pass "N3-no-url-on-stdout"
else
    fail "N3-no-url-on-stdout" "stdout must stay empty when no issue was created; got: $OUT"
fi

# (i) No phantom parent: the report is correct only when a parent exists, so it must be
# absent — in particular in its degenerate form, with the number read from an empty URL.
if printf '%s\n' "$ERR" | grep -qE 'Stranded meta parent: #([^0-9]|$)'; then
    fail "N4-no-phantom-stranded-parent-report" "stderr reports a stranded parent with no issue number — the operator is sent looking for an issue that was never created: $ERR"
else
    pass "N4-no-phantom-stranded-parent-report"
fi
if printf '%s\n' "$ERR" | grep -qE 'issues/([^0-9]|$)'; then
    fail "N4b-no-numberless-issue-url-in-the-report" "stderr carries a numberless .../issues/ URL, which resolves to nothing: $ERR"
else
    pass "N4b-no-numberless-issue-url-in-the-report"
fi

# A non-zero rc with silent stderr cannot be told apart from a cancelled run.
if printf '%s' "$ERR" | grep -qiE 'error|fail'; then
    pass "N5-failure-is-reported-on-stderr"
else
    fail "N5-failure-is-reported-on-stderr" "stderr names no error although the run aborted with rc=$RC: $ERR"
fi
teardown_mock

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) -------
# SKIPPED: the create that fails after GitHub already opened the issue (response lost).
# Because: the mock decides failure before writing anything, so the state "issue exists but
#          the client believes it does not" cannot be produced at TL2.
# L3 gap:  only a real network fault shows whether such a run leaves a genuinely invisible
#          orphan — which no exit-code contract can detect from inside the dispatcher.
