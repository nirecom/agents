# tests/feat-1699-meta-parent-guard/none-path.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/lib/require-meta-parent.sh
# Tags: issue-create, dispatch, meta-parent, none, sibling, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real `gh` call accounting (the absence of a lookup is observed via the mock args log).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group D — verdicts that name no parent must not pay for the guard
#
# Contract under test: the eligibility lookup belongs to the two attach verdicts only.
# `none` (and `sibling`) create a standalone issue, so a parent lookup there would be
# both a wasted API call and a new failure mode for the most common path.

setup_mock
export GH_MOCK_NEW_ISSUE_NUM=261
run_dispatch --verdict none -- --title "standalone" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 0 ]; then
    pass "D1-none-rc0"
else
    fail "D1-none-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
if gh_called_with "--json labels,title"; then
    fail "D1b-none-skips-parent-guard" "the parent-eligibility lookup ran on the 'none' path"
else
    pass "D1b-none-skips-parent-guard"
fi
if [ "$(count_creates)" -eq 1 ]; then
    pass "D1c-none-creates-one-issue"
else
    fail "D1c-none-creates-one-issue" "want 1 create (got: $(count_creates))"
fi
teardown_mock

setup_mock
export GH_MOCK_NEW_ISSUE_NUM=262
run_dispatch --verdict sibling --related "42" -- --title "sibling issue" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 0 ]; then
    pass "D2-sibling-rc0"
else
    fail "D2-sibling-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
if gh_called_with "--json labels,title"; then
    fail "D2b-sibling-skips-parent-guard" "the parent-eligibility lookup ran on the 'sibling' path"
else
    pass "D2b-sibling-skips-parent-guard"
fi
teardown_mock
