# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, fingerprint, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 2: Regression cases unaffected by the deletion-poisoning bug
# (T2, T5, T5pre, T6) — PASS both before and after the fix.
# ===========================================================================

echo ""
echo "=== Regression cases unaffected by deletion-poisoning (T2, T5, T6) ==="

# T2: all-deletions case — zero in-scope survivors → EMPTY ({ok:true, fingerprint:''}).
# The old null (fail-open) becomes an explicit "nothing staged in scope" result.
REPO_ALLDEL="$TMPDIR_BASE/repo-alldel"
init_repo "$REPO_ALLDEL"
mkdir -p "$REPO_ALLDEL/tests"
printf 'a\n' > "$REPO_ALLDEL/tests/a.sh"
printf 'b\n' > "$REPO_ALLDEL/tests/b.sh"
git -C "$REPO_ALLDEL" add tests/a.sh tests/b.sh
(cd "$REPO_ALLDEL" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_ALLDEL" rm -q tests/a.sh tests/b.sh

TOKEN_ALLDEL=$(call_compute_fingerprint "$REPO_ALLDEL")
if [ "$TOKEN_ALLDEL" = "EMPTY" ]; then
    pass "T2. all-deletions staged under tests/: returns EMPTY (ok:true, no in-scope survivors)"
else
    fail "T2. all-deletions staged under tests/: expected EMPTY, got: $TOKEN_ALLDEL"
fi

# T5: rename (R-status) case — renamed tests/ file is treated as a valid entry, not excluded.
# Concern C7: rename detection forced via explicit `git config diff.renames true`.
REPO_RENAME="$TMPDIR_BASE/repo-rename"
init_repo "$REPO_RENAME"
git -C "$REPO_RENAME" config diff.renames true
mkdir -p "$REPO_RENAME/tests"
printf 'rename me please, this has enough content to be detected as a rename\nsecond line\nthird line\n' > "$REPO_RENAME/tests/original.sh"
git -C "$REPO_RENAME" add tests/original.sh
(cd "$REPO_RENAME" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_RENAME" mv tests/original.sh tests/renamed.sh

RENAME_STATUS_LINE=$(git -C "$REPO_RENAME" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*renamed\.sh$' || true)
if [[ -n "$RENAME_STATUS_LINE" ]]; then
    pass "T5pre. rename fixture: renamed.sh is genuinely detected as R-status by git ($RENAME_STATUS_LINE)"
else
    fail "T5pre. rename fixture: renamed.sh was NOT detected as R-status by git — fixture invalid (name-status: $(git -C "$REPO_RENAME" diff --cached --name-status))"
fi

TOKEN_RENAME=$(call_compute_fingerprint "$REPO_RENAME")
if is_valid_hex_token "$TOKEN_RENAME"; then
    pass "T5. renamed staged tests/ file yields a valid hex fingerprint"
else
    fail "T5. renamed staged tests/ file: expected valid hex fingerprint, got: $TOKEN_RENAME"
fi

# T6: addition-only staged set — no deletions, non-null stable fingerprint.
REPO_ADDONLY="$TMPDIR_BASE/repo-addonly"
init_repo "$REPO_ADDONLY"
mkdir -p "$REPO_ADDONLY/tests"
printf 'brand new test file\n' > "$REPO_ADDONLY/tests/new-feature.sh"
git -C "$REPO_ADDONLY" add tests/new-feature.sh

TOKEN_ADDONLY_1=$(call_compute_fingerprint "$REPO_ADDONLY")
TOKEN_ADDONLY_2=$(call_compute_fingerprint "$REPO_ADDONLY")
if is_valid_hex_token "$TOKEN_ADDONLY_1" && [ "$TOKEN_ADDONLY_1" = "$TOKEN_ADDONLY_2" ]; then
    pass "T6. addition-only staged tests/ set: stable, non-null hex fingerprint"
else
    fail "T6. addition-only regression: first=$TOKEN_ADDONLY_1 second=$TOKEN_ADDONLY_2 (expected equal, non-null hex)"
fi
