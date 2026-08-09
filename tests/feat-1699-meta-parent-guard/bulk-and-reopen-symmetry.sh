# tests/feat-1699-meta-parent-guard/bulk-and-reopen-symmetry.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/lib/require-meta-parent.sh
# Tags: issue-create, dispatch, meta-parent, guard, bulk-sub-of, reopen, orthogonality, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether a real partial bulk run leaves GitHub in the same intermediate state the mock
#   reproduces (rate limiting, retries, eventual consistency of sub_issue attachment).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Group K/L — the guard's two edges on the route it governs, and its absence on the
# route it must NOT govern.
#
# Group A pins `bulk-sub-of` REJECTION only (A4/A4b), and an always-on guard looks identical
# from the rejection side — one hard-wired to fail keeps A4 green while making every
# legitimate bulk run impossible. The success path (K) is what distinguishes them.
#
# L is the same principle in the other direction: the guard exists because sub-of /
# bulk-sub-of ATTACH under a claimed parent. `reopen` attaches and creates nothing, so
# extending the guard there would make the everyday reopen of an ordinary `type:task` issue
# fail rc 2. "The guard does not fire on reopen" is a contract, not an omission.

# --- K1: bulk-sub-of under an eligible parent — the success path ----------------------
setup_mock
export GH_MOCK_LABELS_99="type:task,meta"
export GH_MOCK_TITLE_99="Group: platform hardening"
export GH_MOCK_ISSUE_NUMS="401,402"
MANIFEST="$TMP/manifest-ok.tsv"
printf 'child one\tBackground: b\\nChanges: c\n' > "$MANIFEST"
printf 'child two\tBackground: b\\nChanges: c\n' >> "$MANIFEST"
run_dispatch --verdict bulk-sub-of --parent 99 --manifest "$MANIFEST" --
if [ "$RC" -eq 0 ]; then
    pass "K1-bulk-eligible-rc0"
else
    fail "K1-bulk-eligible-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
n=$(count_creates)
if [ "${n:-0}" -eq 2 ]; then
    pass "K1b-bulk-eligible-creates-every-manifest-row"
else
    fail "K1b-bulk-eligible-creates-every-manifest-row" "want 2 creates, one per manifest row (got: $n) — a guard that passes but drops rows is as broken as one that rejects"
fi
a=$(count_attaches)
if [ "${a:-0}" -eq 2 ]; then
    pass "K1c-bulk-eligible-attaches-every-child"
else
    fail "K1c-bulk-eligible-attaches-every-child" "want 2 sub_issues POSTs (got: $a) — created-but-unattached children are orphans"
fi
# The skill maps URL n back to manifest row n, so an order-insensitive assertion would let
# a reshuffle through.
if [ "$(printf '%s\n' "$OUT" | grep -c 'issues/40')" -eq 2 ] \
   && [ "$(printf '%s\n' "$OUT" | sed -n '1p')" = "https://github.com/nirecom/agents/issues/401" ] \
   && [ "$(printf '%s\n' "$OUT" | sed -n '2p')" = "https://github.com/nirecom/agents/issues/402" ]; then
    pass "K1d-bulk-eligible-urls-in-manifest-order"
else
    fail "K1d-bulk-eligible-urls-in-manifest-order" "stdout must be the created URLs in manifest order; got: $OUT"
fi
# The guard must still have RUN, not been skipped for eligible-looking input.
if grep -q 'issue view 99' "$GH_MOCK_ARGS_LOG"; then
    pass "K1e-bulk-eligible-still-consults-the-guard"
else
    fail "K1e-bulk-eligible-still-consults-the-guard" "no parent lookup in the gh log — the success path bypassed the guard entirely"
fi
teardown_mock

# --- K2: bulk-sub-of, parent lookup indeterminate → fail CLOSED, no partial state -----
# Twin of A5 (sub-of). Bulk is where fail-open hurts most: one indeterminate lookup would
# strand a whole manifest's worth of issues.
setup_mock
export GH_MOCK_VIEW_FAIL=1
export GH_MOCK_ISSUE_NUMS="411,412"
MANIFEST="$TMP/manifest-closed.tsv"
printf 'child one\tBackground: b\\nChanges: c\n' > "$MANIFEST"
printf 'child two\tBackground: b\\nChanges: c\n' >> "$MANIFEST"
run_dispatch --verdict bulk-sub-of --parent 99 --manifest "$MANIFEST" --
if [ "$RC" -eq 1 ]; then
    pass "K2-bulk-indeterminate-rc1"
else
    fail "K2-bulk-indeterminate-rc1" "want rc 1 — indeterminate is structural, not a caller mistake (got: $RC); stderr: $ERR"
fi
n=$(count_creates); a=$(count_attaches)
if [ "${n:-0}" -eq 0 ] && [ "${a:-0}" -eq 0 ]; then
    pass "K2b-bulk-indeterminate-no-partial-state"
else
    fail "K2b-bulk-indeterminate-no-partial-state" "want 0 creates and 0 attaches (got creates=$n, attaches=$a) — a refused bulk run must leave nothing behind"
fi
# Nothing on stdout either: the caller treats stdout lines as "these issues now exist".
if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
    pass "K2c-bulk-indeterminate-emits-no-urls"
else
    fail "K2c-bulk-indeterminate-emits-no-urls" "stdout must be empty when nothing was created; got: $OUT"
fi
teardown_mock

# --- L1: reopen does NOT consult the parent guard (CPR-ORTH, negative direction) ------
# #99 is deliberately the shape the guard REJECTS (plain type:task, no Group: title) — the
# ordinary issue a regression reopens. If the guard spread here, rc would become 2.
setup_mock
export GH_MOCK_LABELS_99="type:task"
export GH_MOCK_TITLE_99="dispatcher drops the last manifest row"
run_dispatch --verdict reopen --target 99 --note "regressed after PR #1900"
if [ "$RC" -eq 0 ]; then
    pass "L1-reopen-non-meta-target-rc0"
else
    fail "L1-reopen-non-meta-target-rc0" "want rc 0 — reopen must accept an ordinary issue (got: $RC); stderr: $ERR"
fi
# The guard's lookup is `issue view <n> --json labels,title`; its absence proves the guard
# was not consulted, independent of the exit code.
if grep -q 'issue view 99 --json labels,title' "$GH_MOCK_ARGS_LOG"; then
    fail "L1b-reopen-does-not-invoke-the-meta-parent-guard" "reopen performed the guard's labels,title lookup — the parent-eligibility check leaked onto a route that attaches nothing"
else
    pass "L1b-reopen-does-not-invoke-the-meta-parent-guard"
fi
if [ "$(count_creates)" -eq 0 ]; then
    pass "L1c-reopen-creates-nothing"
else
    fail "L1c-reopen-creates-nothing" "reopen must not create an issue (got: $(count_creates) creates)"
fi
if grep -q 'issue reopen 99' "$GH_MOCK_ARGS_LOG"; then
    pass "L1d-reopen-actually-reopened-the-target"
else
    fail "L1d-reopen-actually-reopened-the-target" "no 'gh issue reopen 99' in the log — L1/L1b would be vacuously green if the branch never ran"
fi
teardown_mock

# --- L2: `none` and `sibling` are already covered in none-path.sh (D1b/D2b) -----------
# Not repeated here: the class is "verdicts that attach nothing", and D1b/D2b own the two
# create-only members. L1 adds the member that creates nothing at all.

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) -------
# SKIPPED: a real bulk run interrupted midway by a GitHub 5xx.
# Because: TL2 cannot reproduce partial API failures with real retry semantics.
# L3 gap:  only a live run shows whether the resume path re-creates already-created children.
