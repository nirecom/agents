# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, fingerprint, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 4: Error paths and edge-case input shapes (T11, T11b, T12-T14, T18-T24).
# computeReviewScopeFingerprint returns {ok:false} (ERR) on git errors;
# {ok:true, fingerprint:''} (EMPTY) when no in-scope files are staged.
# ===========================================================================

echo ""
echo "=== Error paths and edge-case input shapes (T11, T11b, T12-T24) ==="

# T11: nonexistent repoDir → git error → ERR ({ok:false})
REPO_NONEXISTENT="$TMPDIR_BASE/this-path-does-not-exist-at-all"
TOKEN_NONEXISTENT=$(call_compute_fingerprint "$REPO_NONEXISTENT")
if [ "$TOKEN_NONEXISTENT" = "ERR" ]; then
    pass "T11. nonexistent repoDir argument: returns ERR ({ok:false})"
else
    fail "T11. nonexistent repoDir argument: expected ERR, got: $TOKEN_NONEXISTENT"
fi

# T11b: non-git directory (exists on disk, not a git repo) → git error → ERR
REPO_NOTGIT="$TMPDIR_BASE/repo-not-a-git-repo"
mkdir -p "$REPO_NOTGIT"
printf 'just a plain directory, not a git repo\n' > "$REPO_NOTGIT/placeholder.txt"
TOKEN_NOTGIT=$(call_compute_fingerprint "$REPO_NOTGIT")
if [ "$TOKEN_NOTGIT" = "ERR" ]; then
    pass "T11b. non-git directory (exists on disk, no .git): returns ERR ({ok:false})"
else
    fail "T11b. non-git directory: expected ERR, got: $TOKEN_NOTGIT"
fi

# T12: empty staged file mixed with an unrelated deletion.
# The empty-blob OID should survive alongside the deletion being filtered out.
REPO_EMPTY="$TMPDIR_BASE/repo-empty"
init_repo "$REPO_EMPTY"
mkdir -p "$REPO_EMPTY/tests"
printf 'delete me\n' > "$REPO_EMPTY/tests/deleted.sh"
git -C "$REPO_EMPTY" add tests/deleted.sh
(cd "$REPO_EMPTY" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_EMPTY" rm -q tests/deleted.sh
mkdir -p "$REPO_EMPTY/tests"
: > "$REPO_EMPTY/tests/empty.sh"
git -C "$REPO_EMPTY" add tests/empty.sh

TOKEN_EMPTY=$(call_compute_fingerprint "$REPO_EMPTY")
if is_valid_hex_token "$TOKEN_EMPTY"; then
    pass "T12. empty staged file survives alongside an unrelated deletion, yields a valid hex fingerprint"
else
    fail "T12. empty staged file + unrelated deletion: expected valid hex fingerprint, got: $TOKEN_EMPTY"
fi

# T13: space-containing filename alongside a deletion.
# Verifies -z NUL-delimited parsing handles space-containing filenames correctly.
# Note: embedded-newline filenames are not constructible (OS/git reject control chars).
REPO_SPACE="$TMPDIR_BASE/repo-space"
init_repo "$REPO_SPACE"
mkdir -p "$REPO_SPACE/tests"
printf 'delete me\n' > "$REPO_SPACE/tests/deleted.sh"
git -C "$REPO_SPACE" add tests/deleted.sh
(cd "$REPO_SPACE" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_SPACE" rm -q tests/deleted.sh
mkdir -p "$REPO_SPACE/tests"
printf 'content with a space-named file\n' > "$REPO_SPACE/tests/my file.sh"
git -C "$REPO_SPACE" add "tests/my file.sh"

TOKEN_SPACE=$(call_compute_fingerprint "$REPO_SPACE")
if is_valid_hex_token "$TOKEN_SPACE"; then
    pass "T13. space-containing filename survives alongside an unrelated deletion, yields a valid hex fingerprint"
else
    fail "T13. space-containing filename + unrelated deletion: expected valid hex fingerprint, got: $TOKEN_SPACE"
fi

# T14: shell-metacharacter filename alongside a deletion.
# computeReviewScopeFingerprint uses execFileSync (no shell), so injection must not fire.
REPO_META="$TMPDIR_BASE/repo-meta"
MARKER_NAME="pwned.marker"
rm -f "$TMPDIR_BASE/$MARKER_NAME" "$REPO_META/$MARKER_NAME" "$AGENTS_DIR/$MARKER_NAME"
init_repo "$REPO_META"
mkdir -p "$REPO_META/tests"
printf 'delete me\n' > "$REPO_META/tests/deleted.sh"
git -C "$REPO_META" add tests/deleted.sh
(cd "$REPO_META" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_META" rm -q tests/deleted.sh
mkdir -p "$REPO_META/tests"
META_NAME="tests/\$(touch ${MARKER_NAME}).sh"
printf 'metachar filename content\n' > "$REPO_META/$META_NAME"
git -C "$REPO_META" add "$META_NAME"

TOKEN_META=$(call_compute_fingerprint "$REPO_META")
if is_valid_hex_token "$TOKEN_META"; then
    pass "T14. shell-metacharacter filename survives alongside deletion, yields valid hex fingerprint"
else
    fail "T14. shell-metacharacter filename + deletion: expected valid hex fingerprint, got: $TOKEN_META"
fi

if [ ! -e "$TMPDIR_BASE/$MARKER_NAME" ] && [ ! -e "$REPO_META/$MARKER_NAME" ] && [ ! -e "$AGENTS_DIR/$MARKER_NAME" ]; then
    pass "T14b. shell-metacharacter filename does not trigger command injection (marker file never created)"
else
    fail "T14b. shell-metacharacter filename triggered command injection — marker file was created"
fi

# T18: empty-string repoDir → execFileSync throws synchronously → ERR ({ok:false})
TOKEN_EMPTY_REPODIR=$(call_compute_fingerprint "")
if [ "$TOKEN_EMPTY_REPODIR" = "ERR" ]; then
    pass "T18. empty-string repoDir argument: returns ERR ({ok:false})"
else
    fail "T18. empty-string repoDir argument: expected ERR, got: $TOKEN_EMPTY_REPODIR"
fi

# T19: omitted/undefined repoDir → fail-closed {ok:false} (#2327), even when cwd is a repo.
REPO_UNDEFINED_CWD="$TMPDIR_BASE/repo-undefined-cwd"
init_repo "$REPO_UNDEFINED_CWD"
mkdir -p "$REPO_UNDEFINED_CWD/tests"
printf 'undefined-repoDir cwd fixture\n' > "$REPO_UNDEFINED_CWD/tests/fixture.sh"
git -C "$REPO_UNDEFINED_CWD" add tests/fixture.sh

UNDEFINED_REPODIR_RESULT=$(
    cd "$REPO_UNDEFINED_CWD" && run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            const result = m.computeReviewScopeFingerprint();
            if (!result) { process.stdout.write('NO_FUNC'); process.exit(0); }
            if (!result.ok) { process.stdout.write('ERR'); }
            else if (!result.fingerprint) { process.stdout.write('EMPTY'); }
            else { process.stdout.write(String(result.fingerprint)); }
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" 2>/dev/null || echo "ERROR"
)
if [ "$UNDEFINED_REPODIR_RESULT" = "ERR" ]; then
    pass "T19. omitted/undefined repoDir: fail-closed ERR ({ok:false}), no process.cwd() fallback"
else
    fail "T19. omitted/undefined repoDir: expected ERR, got=$UNDEFINED_REPODIR_RESULT"
fi

# T22: deterministic git-subprocess fault injection via poisoned GIT_DIR env var.
# Verified: bogus GIT_DIR makes git's own path resolution fail → {ok:false} → ERR.
REPO_GITDIR_FAULT="$TMPDIR_BASE/repo-gitdir-fault"
init_repo "$REPO_GITDIR_FAULT"
mkdir -p "$REPO_GITDIR_FAULT/tests"
printf 'staged under a repo whose GIT_DIR is about to be poisoned\n' > "$REPO_GITDIR_FAULT/tests/fixture.sh"
git -C "$REPO_GITDIR_FAULT" add tests/fixture.sh

TOKEN_GITDIR_FAULT=$(GIT_DIR="$REPO_GITDIR_FAULT/.git-bogus-nonexistent" call_compute_fingerprint "$REPO_GITDIR_FAULT")
if [ "$TOKEN_GITDIR_FAULT" = "ERR" ]; then
    pass "T22. git subprocess fault injection (bogus GIT_DIR env var): returns ERR ({ok:false})"
else
    fail "T22. git subprocess fault injection: expected ERR, got: $TOKEN_GITDIR_FAULT"
fi

# T23: explicit repoDir=null → fail-closed {ok:false}, same as omitted/undefined (T19).
REPO_NULL_CWD="$TMPDIR_BASE/repo-null-cwd"
init_repo "$REPO_NULL_CWD"
mkdir -p "$REPO_NULL_CWD/tests"
printf 'null-repoDir cwd fixture\n' > "$REPO_NULL_CWD/tests/fixture.sh"
git -C "$REPO_NULL_CWD" add tests/fixture.sh

NULL_REPODIR_RESULT=$(
    cd "$REPO_NULL_CWD" && run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            const result = m.computeReviewScopeFingerprint(null);
            if (!result) { process.stdout.write('NO_FUNC'); process.exit(0); }
            if (!result.ok) { process.stdout.write('ERR'); }
            else if (!result.fingerprint) { process.stdout.write('EMPTY'); }
            else { process.stdout.write(String(result.fingerprint)); }
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" 2>/dev/null || echo "ERROR"
)
if [ "$NULL_REPODIR_RESULT" = "ERR" ]; then
    pass "T23. explicit repoDir=null: fail-closed ERR ({ok:false}), same as T19"
else
    fail "T23. explicit repoDir=null: expected ERR, got=$NULL_REPODIR_RESULT"
fi

# T24: space-named DELETED path alongside a surviving modification.
# After D-status exclusion the space-named deletion contributes nothing;
# the surviving modification should yield a valid fingerprint.
REPO_DEL_SPACE="$TMPDIR_BASE/repo-del-space"
init_repo "$REPO_DEL_SPACE"
mkdir -p "$REPO_DEL_SPACE/tests"
printf 'delete me, space-named\n' > "$REPO_DEL_SPACE/tests/my deleted file.sh"
printf 'modify me v1\n' > "$REPO_DEL_SPACE/tests/modified.sh"
git -C "$REPO_DEL_SPACE" add "tests/my deleted file.sh" tests/modified.sh
(cd "$REPO_DEL_SPACE" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_DEL_SPACE" rm -q "tests/my deleted file.sh"
printf 'modify me v2\n' > "$REPO_DEL_SPACE/tests/modified.sh"
git -C "$REPO_DEL_SPACE" add tests/modified.sh

TOKEN_DEL_SPACE=$(call_compute_fingerprint "$REPO_DEL_SPACE")
if is_valid_hex_token "$TOKEN_DEL_SPACE"; then
    pass "T24. space-named DELETED path alongside a surviving modification: yields a valid hex fingerprint"
else
    fail "T24. space-named deleted path: expected valid hex fingerprint, got: $TOKEN_DEL_SPACE"
fi
