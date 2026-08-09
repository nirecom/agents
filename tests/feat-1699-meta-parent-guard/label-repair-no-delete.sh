# tests/feat-1699-meta-parent-guard/label-repair-no-delete.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh, bin/github-issues/sync-labels.sh
# Tags: issue-create, dispatch, labels, sync-labels, no-delete, destructive, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether real `gh label delete --yes` is in fact irreversible on GitHub (assumed from
#   the API docs; the mock only records that the call was made).
# - Real remote label inventories, which are larger and repo-specific — the blast radius
#   asserted here is one synthetic label.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group R — repairing ONE missing label must not delete the repo's other labels
#
# Why: `sync-labels.sh` is a full reconciler. Its DELETE branch removes every remote label
# that is absent from `.github/labels.yml` and not listed under `protected:`. Both issue
# creation paths call it as a REPAIR — one label is missing and needs creating — so
# without `--no-delete` a single `/issue-create` run against a repo with its own label
# taxonomy silently destroys that taxonomy. The two call sites are symmetric (CPR-ORTH),
# so both are pinned here; a fix applied to one alone is the defect this group exists for.
#
# The assertions are behavioural, not textual: R1/R2 assert that no `gh label delete` is
# ever issued, and R3 drives sync-labels.sh directly to prove the DELETE branch is real
# and that `--no-delete` is what suppresses it. Without R3 the first two would pass
# against a flag nobody honours.

R_SYNC="$AGENTS_DIR/bin/github-issues/sync-labels.sh"
R_LABELS_YML="$AGENTS_DIR/.github/labels.yml"
# A remote label that appears in no labels.yml and no protected: list — the DELETE
# branch's one candidate, standing in for a repo's own taxonomy.
R_DOOMED="doomed-taxonomy-label"

r_delete_calls() { grep -c '^label delete ' "$GH_MOCK_ARGS_LOG" 2>/dev/null || true; }
r_created()      { grep -q "^label create $1 " "$GH_MOCK_ARGS_LOG" 2>/dev/null; }

# assert_no_deletes <case-id> <what-ran>
assert_no_deletes() {
    local cid="$1" what="$2" n
    n=$(r_delete_calls)
    if [ "${n:-0}" -eq 0 ]; then
        pass "$cid-no-label-deleted"
    else
        fail "$cid-no-label-deleted" "$what issued ${n} \`gh label delete\` call(s) while repairing one missing label — a repo's own labels would be destroyed: $(grep '^label delete ' "$GH_MOCK_ARGS_LOG" | tr '\n' ';')"
    fi
    if grep -q "^label list " "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
        pass "$cid-doomed-label-was-visible"
    else
        fail "$cid-doomed-label-was-visible" "sync-labels never listed the remote labels, so '$R_DOOMED' was never a delete candidate and the assertion above is vacuous"
    fi
}

# --- R3 (first, because R1/R2 depend on it being true): the DELETE branch is real -------
# Same labels.yml and same remote inventory as R1/R2 use, driven directly. Two runs
# differing only in the flag isolate the flag as the cause.
setup_mock
export GH_MOCK_REPO_LABELS="type:task,$R_DOOMED"

: > "$GH_MOCK_ARGS_LOG"
bash "$RWT" 60 bash "$R_SYNC" "$R_LABELS_YML" > "$TMP/sync-bare.out" 2>&1
R_BARE_RC=$?
if grep -q "^label delete $R_DOOMED " "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "R3a-bare-sync-does-delete"
else
    fail "R3a-bare-sync-does-delete" "sync-labels.sh without --no-delete must delete '$R_DOOMED' (rc=$R_BARE_RC) — if it does not, --no-delete pins nothing; log: $(tr '\n' ';' < "$GH_MOCK_ARGS_LOG")"
fi

: > "$GH_MOCK_ARGS_LOG"
bash "$RWT" 60 bash "$R_SYNC" --no-delete "$R_LABELS_YML" > "$TMP/sync-nodelete.out" 2>&1
R_ND_RC=$?
if [ "$(r_delete_calls)" -eq 0 ]; then
    pass "R3b-no-delete-suppresses-the-delete"
else
    fail "R3b-no-delete-suppresses-the-delete" "--no-delete must suppress every \`gh label delete\` (got: $(grep '^label delete ' "$GH_MOCK_ARGS_LOG" | tr '\n' ';'))"
fi
if grep -qF "[NO-DELETE] Skipped delete: $R_DOOMED" "$TMP/sync-nodelete.out"; then
    pass "R3c-no-delete-reports-the-skip"
else
    fail "R3c-no-delete-reports-the-skip" "the suppressed delete must be reported so an operator can still see the drift (stdout: $(head -c 400 "$TMP/sync-nodelete.out"))"
fi
# The flag must suppress deletion only — a --no-delete that also stopped creating would
# make both call sites fail to repair the very label they were called for.
if r_created "meta"; then
    pass "R3d-no-delete-still-creates"
else
    fail "R3d-no-delete-still-creates" "--no-delete must still CREATE missing labels ('meta' was absent from the mock repo); log: $(tr '\n' ';' < "$GH_MOCK_ARGS_LOG")"
fi
if [ "$R_ND_RC" -eq 0 ]; then
    pass "R3e-no-delete-rc0"
else
    fail "R3e-no-delete-rc0" "sync-labels.sh --no-delete must succeed (got rc=$R_ND_RC); output: $(head -c 300 "$TMP/sync-nodelete.out")"
fi
teardown_mock

# --- R1: the make-parent `meta` repair in issue-create-dispatch.sh -----------------------
# `meta` absent from the remote → the dispatcher repairs before creating the parent,
# because a parent without `meta` is invisible to require-meta-parent.sh.
setup_mock
export GH_MOCK_REPO_LABELS="type:task,$R_DOOMED"
export GH_MOCK_ISSUE_NUMS="301,302"
run_dispatch --verdict make-parent --children "42,43" -- \
    --title "improve retry backoff" \
    --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 0 ]; then
    pass "R1a-make-parent-rc0"
else
    fail "R1a-make-parent-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
# Non-vacuity: the repair path must actually have been taken. If `meta` was never
# created, sync never ran and "no deletes" is trivially true.
if r_created "meta"; then
    pass "R1b-meta-was-repaired"
else
    fail "R1b-meta-was-repaired" "the dispatcher must create the missing 'meta' label before the parent; log: $(tr '\n' ';' < "$GH_MOCK_ARGS_LOG")"
fi
assert_no_deletes "R1c" "the make-parent meta repair"
teardown_mock

# --- R2: the type:task repair in issue-create.sh (CPR-ORTH sibling) ----------------------
# Reached through the dispatcher's `none` path, which is how the skill reaches it. Phase 0a
# only runs when the remote is github.com, so the case runs inside a throwaway fixture repo
# with a github.com origin rather than against the developer's checkout.
setup_mock
export GH_MOCK_REPO_LABELS="$R_DOOMED"
export GH_MOCK_NEW_ISSUE_NUM=311
R_FIX="$TMP/fixture-repo"
mkdir -p "$R_FIX"
git -C "$R_FIX" init -q
git -C "$R_FIX" config core.hooksPath /dev/null
git -C "$R_FIX" remote add origin https://github.com/example/fixture.git
R_CWD="$PWD"
cd "$R_FIX" || exit 1
run_dispatch --verdict none -- --title "standalone" --body "$(printf "$CANONICAL_BODY")"
cd "$R_CWD" || exit 1
if [ "$RC" -eq 0 ]; then
    pass "R2a-none-rc0"
else
    fail "R2a-none-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
# Non-vacuity, twice over: the repair branch announces itself on stderr, and the label
# it was called for must exist afterwards.
if printf '%s' "$ERR" | grep -qF "labels synced (type:task was missing)"; then
    pass "R2b-repair-branch-taken"
else
    fail "R2b-repair-branch-taken" "issue-create.sh Phase 0a did not run the label repair — the assertion below would be vacuous (stderr: $(printf '%s' "$ERR" | head -c 400))"
fi
if r_created "type:task"; then
    pass "R2c-type-task-was-repaired"
else
    fail "R2c-type-task-was-repaired" "the missing 'type:task' label must be created; log: $(tr '\n' ';' < "$GH_MOCK_ARGS_LOG")"
fi
assert_no_deletes "R2d" "the issue-create.sh type:task repair"
teardown_mock
