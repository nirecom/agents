# tests/feat-1699-meta-parent-guard/guard.sh
# Tests: bin/github-issues/lib/require-meta-parent.sh, bin/github-issues/issue-create-dispatch.sh
# Tags: issue-create, dispatch, meta-parent, guard, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - A real `gh issue view` against github.com (label/title read-after-write lag, auth expiry).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group A — parent-eligibility guard (require-meta-parent.sh + dispatcher wiring)
#
# Contract under test: `sub-of` and `bulk-sub-of` must verify the named parent is a
# real meta parent (label `meta` AND title prefix `Group: `, logical AND) BEFORE the
# first `gh issue create`. Ineligible → dispatcher rc 2. Indeterminate (lookup failed)
# → rc 1, fail-CLOSED. Either way, zero issues created.

# --- A1: sub-of, parent lacks the meta label -----------------------------------------
setup_mock
export GH_MOCK_LABELS_99="type:task"
export GH_MOCK_TITLE_99="Group: platform hardening"
run_dispatch --verdict sub-of --parent 99 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 2 ]; then
    pass "A1-sub-of-no-meta-label-rc2"
else
    fail "A1-sub-of-no-meta-label-rc2" "want rc 2 (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 0 ]; then
    pass "A1b-sub-of-no-meta-label-zero-creates"
else
    fail "A1b-sub-of-no-meta-label-zero-creates" "want 0 gh issue create calls (got: $n) — an orphan issue was created before the guard ran"
fi
teardown_mock

# --- A2: sub-of, meta label present but title is not a Group: title ------------------
# The AND is the point: a bare `meta` label must not be a bypass.
setup_mock
export GH_MOCK_LABELS_99="type:task,meta"
export GH_MOCK_TITLE_99="hardening work"
run_dispatch --verdict sub-of --parent 99 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 2 ]; then
    pass "A2-sub-of-meta-without-group-title-rc2"
else
    fail "A2-sub-of-meta-without-group-title-rc2" "want rc 2 (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 0 ]; then
    pass "A2b-sub-of-meta-without-group-title-zero-creates"
else
    fail "A2b-sub-of-meta-without-group-title-zero-creates" "want 0 creates (got: $n)"
fi
teardown_mock

# --- A3: sub-of, fully eligible parent → proceeds -------------------------------------
setup_mock
export GH_MOCK_LABELS_99="type:task,meta"
export GH_MOCK_TITLE_99="Group: platform hardening"
export GH_MOCK_NEW_ISSUE_NUM=301
run_dispatch --verdict sub-of --parent 99 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 0 ]; then
    pass "A3-sub-of-eligible-rc0"
else
    fail "A3-sub-of-eligible-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 1 ]; then
    pass "A3b-sub-of-eligible-one-create"
else
    fail "A3b-sub-of-eligible-one-create" "want 1 create (got: $n)"
fi
if gh_called_with "sub_issues"; then
    pass "A3c-sub-of-eligible-attached"
else
    fail "A3c-sub-of-eligible-attached" "no sub_issues POST in the gh log"
fi
teardown_mock

# --- A4: bulk-sub-of under an ineligible parent --------------------------------------
setup_mock
export GH_MOCK_LABELS_99="type:task"
export GH_MOCK_TITLE_99="not a group"
export GH_MOCK_ISSUE_NUMS="401,402"
MANIFEST="$TMP/manifest.tsv"
printf 'child one\tBackground: b\\nChanges: c\n' > "$MANIFEST"
printf 'child two\tBackground: b\\nChanges: c\n' >> "$MANIFEST"
run_dispatch --verdict bulk-sub-of --parent 99 --manifest "$MANIFEST" --
if [ "$RC" -eq 2 ]; then
    pass "A4-bulk-sub-of-ineligible-rc2"
else
    fail "A4-bulk-sub-of-ineligible-rc2" "want rc 2 (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 0 ]; then
    pass "A4b-bulk-sub-of-ineligible-zero-creates"
else
    fail "A4b-bulk-sub-of-ineligible-zero-creates" "want 0 creates (got: $n) — bulk orphans are the worst case"
fi
teardown_mock

# --- A5: parent lookup fails → indeterminate → fail-CLOSED ---------------------------
setup_mock
export GH_MOCK_VIEW_FAIL=1
run_dispatch --verdict sub-of --parent 99 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 1 ]; then
    pass "A5-sub-of-lookup-failure-rc1"
else
    fail "A5-sub-of-lookup-failure-rc1" "want rc 1 (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 0 ]; then
    pass "A5b-sub-of-lookup-failure-zero-creates"
else
    fail "A5b-sub-of-lookup-failure-zero-creates" "want 0 creates (got: $n) — indeterminate must not fall through to create"
fi
teardown_mock

# --- A6: require-meta-parent.sh standalone exit codes ---------------------------------
setup_mock
export GH_MOCK_LABELS_99="type:task,meta"
export GH_MOCK_TITLE_99="Group: platform hardening"
bash "$RWT" 30 bash "$GUARD" 99 >"$TMP/g.out" 2>"$TMP/g.err"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "A6-guard-eligible-rc0"
else
    fail "A6-guard-eligible-rc0" "want rc 0 (got: $rc); stderr: $(cat "$TMP/g.err")"
fi
# One lookup only: the guard must answer both conditions from a single API round trip.
views=$(grep -c 'issue view' "$GH_MOCK_ARGS_LOG" 2>/dev/null) || true
if [ "${views:-0}" -eq 1 ]; then
    pass "A6b-guard-single-lookup"
else
    fail "A6b-guard-single-lookup" "want exactly 1 'gh issue view' call (got: ${views:-0})"
fi
teardown_mock

setup_mock
export GH_MOCK_LABELS_99="type:task"
export GH_MOCK_TITLE_99="Group: platform hardening"
bash "$RWT" 30 bash "$GUARD" 99 >"$TMP/g.out" 2>"$TMP/g.err"; rc=$?
GUARD_ERR="$(cat "$TMP/g.err")"
if [ "$rc" -eq 3 ]; then
    pass "A7-guard-ineligible-rc3"
else
    fail "A7-guard-ineligible-rc3" "want rc 3 (got: $rc); stderr: $GUARD_ERR"
fi
# The message must name WHICH condition failed — "not eligible" alone leaves the
# operator guessing between label and title.
# Both tokens are required: the script's own path contains "meta", so a bare 'meta'
# grep would also match `require-meta-parent.sh: No such file` and report a false green.
if printf '%s' "$GUARD_ERR" | grep -q 'meta' && printf '%s' "$GUARD_ERR" | grep -qi 'label'; then
    pass "A7b-guard-rc3-names-missing-condition"
else
    fail "A7b-guard-rc3-names-missing-condition" "stderr does not name the missing 'meta' label: $GUARD_ERR"
fi
# Two recovery routes, enumerated. Counted as enumerated lines so the assertion does
# not depend on the exact wording of either route.
routes=$(printf '%s\n' "$GUARD_ERR" | grep -c -E '^[[:space:]]*([0-9]+[).]|[-*])[[:space:]]') || true
if [ "${routes:-0}" -ge 2 ]; then
    pass "A7c-guard-rc3-two-recovery-routes"
else
    fail "A7c-guard-rc3-two-recovery-routes" "want >=2 enumerated recovery lines (got: ${routes:-0}); stderr: $GUARD_ERR"
fi
# Explicitly NOT a copy-paste --add-label one-liner: slapping `meta` on an issue that
# was never scoped as a group is the mistake the guard exists to prevent.
# Conditioned on rc 3 so the case cannot go green merely because the guard is absent
# and produced no stderr at all.
if [ "$rc" -eq 3 ] && ! printf '%s' "$GUARD_ERR" | grep -q -- '--add-label'; then
    pass "A7d-guard-rc3-no-add-label-oneliner"
else
    fail "A7d-guard-rc3-no-add-label-oneliner" "want rc 3 (got: $rc) with no '--add-label' one-liner in stderr: $GUARD_ERR"
fi
teardown_mock

setup_mock
export GH_MOCK_VIEW_FAIL=1
bash "$RWT" 30 bash "$GUARD" 99 >"$TMP/g.out" 2>"$TMP/g.err"; rc=$?
if [ "$rc" -eq 4 ]; then
    pass "A8-guard-indeterminate-rc4"
else
    fail "A8-guard-indeterminate-rc4" "want rc 4 (got: $rc); stderr: $(cat "$TMP/g.err")"
fi
teardown_mock

# --- A9: no environment bypass --------------------------------------------------------
# A skip switch would be discovered and used; the guard must have none.
setup_mock
export GH_MOCK_LABELS_99="type:task"
export GH_MOCK_TITLE_99="plain"
export REQUIRE_META_PARENT=0
export SKIP_META_PARENT_CHECK=1
export META_PARENT_GUARD=off
run_dispatch --verdict sub-of --parent 99 -- --title "child" --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 2 ] && [ "$(count_creates)" -eq 0 ]; then
    pass "A9-guard-has-no-env-bypass"
else
    fail "A9-guard-has-no-env-bypass" "want rc 2 with 0 creates even with bypass-looking env vars set (rc=$RC, creates=$(count_creates))"
fi
unset REQUIRE_META_PARENT SKIP_META_PARENT_CHECK META_PARENT_GUARD
teardown_mock

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) -------
# SKIPPED: guard behaviour when the real GitHub API returns a partial / eventually
#          consistent label set (label added seconds earlier, not yet visible).
# Because: requires real API replication lag; the mock answers deterministically at TL2.
# L3 gap:  only a real `gh` against github.com can exhibit the read-after-write window
#          that would turn an eligible parent into a spurious rc=3 rejection.
#
# SKIPPED: guard behaviour when `gh` auth expires mid-run (token revoked between the
#          preflight `gh auth status` and the parent lookup).
# Because: fault injection into a live credential store is not possible at TL2;
#          GH_MOCK_VIEW_FAIL approximates the exit code but not the auth-specific stderr.
# L3 gap:  only a real host can confirm such a failure is classified indeterminate
#          (guard rc 4 → dispatcher rc 1, fail-CLOSED) rather than as an ineligible parent.
