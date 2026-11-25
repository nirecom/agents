# tests/bin/feat-1699-meta-parent-guard/label-repair-no-delete.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh, bin/github-issues/sync-labels.sh
# Tags: issue-create, dispatch, labels, sync-labels, no-delete, destructive, security, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: real `gh label delete --yes` irreversibility and real label inventories (the mock records
#   one synthetic label); checked at WORKFLOW_USER_VERIFIED preflight (category: skill-orchestration).
# Group R — repairing ONE missing label must not delete the repo's other labels. sync-labels.sh's
# DELETE branch removes every remote label absent from `.github/labels.yml`; both issue-creation
# paths call it as a repair, so both must pass `--no-delete`. R1/R2 assert no `gh label delete`;
# R3 proves the DELETE branch is real and that `--no-delete` is what suppresses it.


R_SYNC="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/sync-labels.sh"
R_LABELS_YML="$SCRIPT_CHECKOUT_ROOT/.github/labels.yml"
# In no labels.yml and no protected: list — the DELETE branch's one candidate, standing
# in for a repo's own taxonomy.
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
# Two runs differing only in the flag isolate the flag as the cause.
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
# Deletion only: a --no-delete that also stopped creating would fail the repair itself.
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
# `meta` absent → the dispatcher repairs before creating the parent, because a parent
# without `meta` is invisible to require-meta-parent.sh.
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
# Non-vacuity: if `meta` was never created, sync never ran and "no deletes" is trivial.
if r_created "meta"; then
    pass "R1b-meta-was-repaired"
else
    fail "R1b-meta-was-repaired" "the dispatcher must create the missing 'meta' label before the parent; log: $(tr '\n' ';' < "$GH_MOCK_ARGS_LOG")"
fi
assert_no_deletes "R1c" "the make-parent meta repair"
teardown_mock

# --- R2: the type:task repair in issue-create.sh (CPR-ORTH sibling) ----------------------
# Reached through the dispatcher's `none` path. Phase 0a only runs when the remote is
# github.com, so this runs in a throwaway fixture repo, not the developer's checkout.
setup_mock
export GH_MOCK_REPO_LABELS="$R_DOOMED"
export GH_MOCK_NEW_ISSUE_NUM=311
R_FIX="$TMP/fixture-repo"
mkdir -p "$R_FIX"
git -C "$R_FIX" init -q
git -C "$R_FIX" config core.hooksPath /dev/null
git -C "$R_FIX" remote add origin https://github.com/example/fixture.git
# #3142 R2: issue-create.sh reaches the board resolver, whose cache falls back to $HOME. The real
# cache must come out unchanged, so HOME is pinned for the dispatcher run only and the real file's
# checksum (or `absent`) is compared before and after.
R_REAL_HOME="$HOME"
R_REAL_CACHE="$R_REAL_HOME/.workflow-state/cache/project-resolve.tsv"
r_cache_sum() { if [ -f "$R_REAL_CACHE" ]; then cksum < "$R_REAL_CACHE"; else echo absent; fi; }
R_CACHE_BEFORE="$(r_cache_sum)"
mkdir -p "$TMP/home"
R_CWD="$PWD"
cd "$R_FIX" || exit 1
export HOME="$TMP/home"
run_dispatch --verdict none -- --title "standalone" --body "$(printf "$CANONICAL_BODY")"
export HOME="$R_REAL_HOME"
cd "$R_CWD" || exit 1
if [ "$(r_cache_sum)" = "$R_CACHE_BEFORE" ]; then
    pass "R2e-real-resolver-cache-unchanged"
else
    fail "R2e-real-resolver-cache-unchanged" "the run wrote the developer's real $R_REAL_CACHE (before: $R_CACHE_BEFORE, after: $(r_cache_sum))"
fi
if [ "$RC" -eq 0 ]; then
    pass "R2a-none-rc0"
else
    fail "R2a-none-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi
# Non-vacuity, twice: the repair branch announces itself, and the label must exist after.
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
