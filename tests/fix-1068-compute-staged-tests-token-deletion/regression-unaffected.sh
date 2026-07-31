# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 2: Regression cases unaffected by the deletion-poisoning bug
# (T2, T5, T6) — PASS both before and after the fix.
# ===========================================================================

# ---------------------------------------------------------------------------
# T2 — All-deletions case: every staged tests/ path is a deletion.
# Existing fail-open behavior (null) must be preserved after the fix, since
# there are zero surviving A/M/R paths under tests/ to hash.
# EXPECTED: PASS both before and after the fix.
# ---------------------------------------------------------------------------
REPO_ALLDEL="$TMPDIR_BASE/repo-alldel"
init_repo "$REPO_ALLDEL"
mkdir -p "$REPO_ALLDEL/tests"
printf 'a\n' > "$REPO_ALLDEL/tests/a.sh"
printf 'b\n' > "$REPO_ALLDEL/tests/b.sh"
git -C "$REPO_ALLDEL" add tests/a.sh tests/b.sh
(cd "$REPO_ALLDEL" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_ALLDEL" rm -q tests/a.sh tests/b.sh

TOKEN_ALLDEL=$(call_compute_token "$REPO_ALLDEL")
if [ "$TOKEN_ALLDEL" = "NULL" ]; then
    pass "T2. all-deletions staged under tests/: returns null (fail-open preserved)"
else
    fail "T2. all-deletions staged under tests/: expected NULL, got: $TOKEN_ALLDEL"
fi

# ---------------------------------------------------------------------------
# T5 — Rename (R-status) case: a renamed tests/ file must be treated as a
# valid entry, not excluded like a deletion.
# NOTE: `git diff --cached --name-only` already collapses a staged rename
# into a single row for the *new* path (no separate old-path row appears),
# so this case does not exercise the #1068 bug directly — it guards against
# a fix that over-filters and accidentally excludes R-status paths too.
# Concern C7 (LOW): rename detection is forced via an explicit
# `git config diff.renames true` (matching T9's pattern in
# status-combinations.sh) rather than relying on the ambient/global git
# config default, per skills/_shared/test-design.md "config-dependent
# branches" rule.
# EXPECTED: PASS both before and after the fix.
# ---------------------------------------------------------------------------
REPO_RENAME="$TMPDIR_BASE/repo-rename"
init_repo "$REPO_RENAME"
git -C "$REPO_RENAME" config diff.renames true
mkdir -p "$REPO_RENAME/tests"
printf 'rename me please, this has enough content to be detected as a rename\nsecond line\nthird line\n' > "$REPO_RENAME/tests/original.sh"
git -C "$REPO_RENAME" add tests/original.sh
(cd "$REPO_RENAME" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_RENAME" mv tests/original.sh tests/renamed.sh

# Concern 7 (LOW): assert the fixture is genuinely detected as R-status by
# git itself before calling computeStagedTestsToken — do not merely assume
# `git mv` produces a rename row (rename detection depends on content
# similarity and the ambient diff.renames config).
RENAME_STATUS_LINE=$(git -C "$REPO_RENAME" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*renamed\.sh$' || true)
if [[ -n "$RENAME_STATUS_LINE" ]]; then
    pass "T5pre. rename fixture: renamed.sh is genuinely detected as R-status by git ($RENAME_STATUS_LINE)"
else
    fail "T5pre. rename fixture: renamed.sh was NOT detected as R-status by git — fixture invalid (name-status: $(git -C "$REPO_RENAME" diff --cached --name-status))"
fi

TOKEN_RENAME=$(call_compute_token "$REPO_RENAME")
if is_valid_hex_token "$TOKEN_RENAME"; then
    pass "T5. renamed staged tests/ file yields a valid non-null hex token"
else
    fail "T5. renamed staged tests/ file: expected valid hex token, got: $TOKEN_RENAME"
fi

# ---------------------------------------------------------------------------
# T6 — Regression: addition-only staged set (no deletions) must keep behaving
# as before the fix (non-null hex token), matching the existing T9-style
# expectation in tests/feature-833-review-tests-sentinel-ssot.sh.
# EXPECTED: PASS both before and after the fix.
# ---------------------------------------------------------------------------
REPO_ADDONLY="$TMPDIR_BASE/repo-addonly"
init_repo "$REPO_ADDONLY"
mkdir -p "$REPO_ADDONLY/tests"
printf 'brand new test file\n' > "$REPO_ADDONLY/tests/new-feature.sh"
git -C "$REPO_ADDONLY" add tests/new-feature.sh

TOKEN_ADDONLY_1=$(call_compute_token "$REPO_ADDONLY")
TOKEN_ADDONLY_2=$(call_compute_token "$REPO_ADDONLY")
if is_valid_hex_token "$TOKEN_ADDONLY_1" && [ "$TOKEN_ADDONLY_1" = "$TOKEN_ADDONLY_2" ]; then
    pass "T6. addition-only staged tests/ set: unaffected regression case yields stable non-null token"
else
    fail "T6. addition-only regression: first=$TOKEN_ADDONLY_1 second=$TOKEN_ADDONLY_2 (expected equal, non-null hex)"
fi
