# tests/feat-1699-meta-parent-guard/make-parent-preflight.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh
# Tags: issue-create, dispatch, meta-parent, make-parent, error-path, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether a real `gh issue create` rejects the same argv the mock accepts, and whether
#   a real stranded parent is recoverable from the operator's side.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group E — make-parent's pre-creation validation, and the seam it does NOT cover
#
# `make-parent` creates two issues in sequence and GitHub has no transaction. The only
# defence available is to reject a bad proposal argv while nothing has been created yet,
# so the boundary between "rejected before the first create" and "rejected after the
# parent is live" is the contract this group measures.
#
# The dispatcher validates argv PRESENCE (--title, and one of --body/--body-file) itself
# — those are cases B9/B9b in make-parent.sh. Everything else about the proposal is
# validated by issue-create.sh, which the dispatcher reaches only on the SECOND create.
# E1–E4 therefore pin the current, weaker reality: a proposal that issue-create.sh will
# refuse still costs one live meta parent. E5 pins the same seam from the other side (a
# transport failure on the second create). These cases exist to make that boundary
# visible and to fail loudly the day it moves — in either direction.
#
# The cost of that boundary is bounded by the REPORTING contract, which every case below
# also pins: when the proposal create fails after the parent is live, the dispatcher exits
# 1 explicitly (not via a `set -e` unwind), names the stranded parent by number AND URL on
# stderr, and states how to recover — while stdout stays empty, because the URL contract
# for make-parent is two URLs or none, never a half-built pair.

# mpp_run <extra passthrough args...> — standard make-parent argv with a substitutable tail
mpp_run() {
    run_dispatch --verdict make-parent --children "42" -- --title "proposal title" "$@"
}

# assert_stranded_parent <label-prefix> <parent-number> — the shared shape of E1..E4.
# One create (the meta parent) reached gh; the dispatcher then exited 1 and reported the
# stranded parent on stderr, with nothing on stdout.
assert_stranded_parent() {
    local p="$1" parent="$2" n
    n=$(count_creates)
    # rc 1, exactly: the dispatcher reaches its own `exit 1` after printing the report.
    # A `set -e` unwind of the failing command substitution would surface issue-create.sh's
    # own rc (2 for a usage error) instead, so the exact value is what distinguishes
    # "reported then aborted" from "silently unwound".
    if [ "$RC" -eq 1 ]; then
        pass "${p}-rc1"
    else
        fail "${p}-rc1" "want rc 1 from the dispatcher's explicit abort after reporting the stranded parent (got: $RC); stderr: $ERR"
    fi
    # ONE, not zero: the dispatcher validates argv PRESENCE only, so a proposal that
    # issue-create.sh refuses is caught on the second create, after the parent is live.
    # If a future change moves that validation ahead of the parent create, this flips to
    # 0 and the case fails — which is the notification, not a regression.
    if [ "${n:-0}" -eq 1 ]; then
        pass "${p}-exactly-one-create-parent-only"
    else
        fail "${p}-exactly-one-create-parent-only" "want exactly 1 gh issue create (the meta parent) (got: ${n:-0}) — if this is 0 the dispatcher now validates before creating, and this case should be re-pinned"
    fi
    if [ -z "$(printf '%s' "$OUT" | grep . || true)" ]; then
        pass "${p}-no-url-on-stdout"
    else
        fail "${p}-no-url-on-stdout" "stdout carried a URL although the run aborted: $OUT"
    fi
    # The number alone is not enough to act on, and the URL alone is not greppable against
    # a notes file — the report must carry both.
    if printf '%s' "$ERR" | grep -q "#${parent}"; then
        pass "${p}-stderr-names-stranded-number"
    else
        fail "${p}-stderr-names-stranded-number" "stderr does not name the stranded parent #${parent}: $ERR"
    fi
    if printf '%s' "$ERR" | grep -q "issues/${parent}\$\|issues/${parent}[^0-9]"; then
        pass "${p}-stderr-names-stranded-url"
    else
        fail "${p}-stderr-names-stranded-url" "stderr does not carry the stranded parent's URL (.../issues/${parent}): $ERR"
    fi
    if printf '%s' "$ERR" | grep -qi 'recover'; then
        pass "${p}-stderr-states-recovery"
    else
        fail "${p}-stderr-states-recovery" "stderr does not tell the operator how to recover from the stranded parent: $ERR"
    fi
}

# --- E1: proposal body that fails the canonical Background/Changes schema ---------------
setup_mock
export GH_MOCK_ISSUE_NUMS="601,602"
mpp_run --body "just some prose with no canonical fields"
assert_stranded_parent E1-malformed-body 601
# The parent created here is #601. stdout is the URL contract and must stay empty, so the
# report has exactly one channel available: stderr. E1d checks that channel end to end —
# the operator can read the whole intermediate state off a single stream.
if printf '%s' "$ERR" | grep -q 'Stranded meta parent: #601'; then
    pass "E1d-stranded-parent-reported-on-stderr"
else
    fail "E1d-stranded-parent-reported-on-stderr" "stderr must name the stranded parent #601 so the operator can locate the empty \`Group: \` issue: $ERR"
fi
teardown_mock

# --- E2: --body-file naming a path that does not exist ----------------------------------
setup_mock
export GH_MOCK_ISSUE_NUMS="611,612"
mpp_run --body-file "$TMP/definitely-not-here.md"
assert_stranded_parent E2-missing-body-file 611
teardown_mock

# --- E3: passthrough argv issue-create.sh refuses (a type:* label) -----------------------
# `--label type:task` is rejected by issue-create.sh's own parser. The dispatcher passes
# the proposal's labels through untouched, so it cannot see the problem coming.
setup_mock
export GH_MOCK_ISSUE_NUMS="621,622"
mpp_run --body "$(printf "$CANONICAL_BODY")" --label "type:task"
assert_stranded_parent E3-rejected-label 621
teardown_mock

# --- E4: an argument no downstream script knows ------------------------------------------
setup_mock
export GH_MOCK_ISSUE_NUMS="631,632"
mpp_run --body "$(printf "$CANONICAL_BODY")" --totally-unknown-flag x
assert_stranded_parent E4-unknown-passthrough-arg 631
teardown_mock

# --- E5: the SECOND create fails at the transport layer ----------------------------------
# The parent is already live on GitHub at this point; the proposal is not. This is the
# worst intermediate state make-parent can reach, and unlike the partial-attach case
# (B10) the dispatcher has not yet emitted either URL.
setup_mock
export GH_MOCK_ISSUE_NUMS="641,642"
export GH_MOCK_CREATE_FAIL_FROM=2
mpp_run --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 1 ]; then
    pass "E5-second-create-failure-rc1"
else
    fail "E5-second-create-failure-rc1" "want rc 1 from the dispatcher's explicit abort when the proposal create fails (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 2 ]; then
    pass "E5b-second-create-was-attempted"
else
    fail "E5b-second-create-was-attempted" "want 2 create attempts, the second failing (got: ${n:-0})"
fi
# No attach may be issued: attaching to a parent whose only child never came into being
# would compound the mess.
a=$(count_attaches)
if [ "${a:-0}" -eq 0 ]; then
    pass "E5c-no-attach-after-failed-child-create"
else
    fail "E5c-no-attach-after-failed-child-create" "want 0 sub_issues POSTs (got: ${a:-0})"
fi
if [ -z "$(printf '%s' "$OUT" | grep . || true)" ]; then
    pass "E5d-no-url-on-stdout"
else
    fail "E5d-no-url-on-stdout" "stdout carried a URL although the proposal was never created: $OUT"
fi
# Same reporting contract as E1d, reached through the transport layer instead of through
# argv validation — which is why it is worth a second case: the two routes run through the
# same `child_rc` guard, but only a distinct case proves the guard is not argv-specific.
if printf '%s' "$ERR" | grep -q 'Stranded meta parent: #641'; then
    pass "E5e-stranded-parent-reported-on-stderr"
else
    fail "E5e-stranded-parent-reported-on-stderr" "stderr must name the stranded parent #641 after a transport-layer failure on the second create: $ERR"
fi
if printf '%s' "$ERR" | grep -q 'issues/641$\|issues/641[^0-9]'; then
    pass "E5f-stranded-parent-url-on-stderr"
else
    fail "E5f-stranded-parent-url-on-stderr" "stderr does not carry the stranded parent's URL (.../issues/641): $ERR"
fi
if printf '%s' "$ERR" | grep -qi 'recover'; then
    pass "E5g-stranded-parent-recovery-instruction"
else
    fail "E5g-stranded-parent-recovery-instruction" "stderr does not tell the operator how to recover (create the proposal manually and attach, or close the parent): $ERR"
fi
teardown_mock

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) ---------
# SKIPPED: executing the recovery of a stranded meta parent (create the proposal manually
#          and attach it, or close the parent) after E1/E5.
# Because: the reporting half of this gap is now CLOSED and covered above — E1d/E5e/E5f/E5g
#          pin number, URL, and recovery instruction on stderr. What remains open is the
#          ACTING half: the dispatcher deliberately does not clean up after itself (an
#          automatic close would destroy an issue an operator may want to reuse), so there
#          is no in-process recovery path for a test to drive.
# L3 gap:  every failure here is simulated by the gh mock. No test drives a real GitHub
#          rejection, so what remains unverified is (a) whether real `gh issue create`
#          fails on the same argv the mock refuses, and (b) whether the reported parent is
#          in fact reachable and recoverable at that URL — only a real run against
#          github.com shows the operator an empty `Group: ` parent with no children.
