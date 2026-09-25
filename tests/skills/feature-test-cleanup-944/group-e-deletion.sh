# Group E: audit-tests.sh REAL deletion path (Cases 29-32)
# Tests: bin/audit-tests.sh, bin/lib/test-retire-predicate.sh
# Tags: audit-tests, deletion, apply-by-default, scope:issue-specific, TL2
# Sourced by tests/feature-test-cleanup-944.sh
#
# Every other group exercises audit-tests.sh with --dry-run (or via the
# separate --fix-headers path), so the branch that actually removes files was
# never executed by any test. Under the apply-by-default convention a flagless
# run of audit-tests.sh DELETES retired test files, so that branch is the
# highest-blast-radius code in this script.
#
# All work happens inside a throwaway fixture repo built by setup_audit_repo
# (mktemp -d under $TMPDIR_BASE). The real tests/ tree is never an input.
#
# Fixture design, revised for #1833 — the three survival verdicts:
#   orphan     : every `# Tests:` token is format-OK, missing, not renamed
#                → the only candidate; deleted once the issue gate allows it
#   malformed  : a token that fails FRONTMATTER_TOKEN_VALID_RE (annotated prose)
#                → undecidable: not a candidate, not deleted, only diagnosed
#   renamed    : a format-OK token whose path was renamed away in git history
#                → the target is ALIVE: not a candidate, not deleted
# The retired SKIP_DELETE_HAS_A_OR_B label belonged to the old model, where
# these three were all candidates and the A/B flags were checked at delete time.
# They are now separated before candidacy, so that label must never reappear.

if [[ ! -f "$AUDIT_TESTS" ]]; then
    skip "Cases 29-32: bin/audit-tests.sh does not exist yet"
else

# The shared make_gh_stub (tests/feature-test-cleanup-944.sh) emits
# "<state> <closed_at>" pairs with a long-past default closed_at, so the delete
# gate is satisfied and the survival verdict is the only variable left.

# setup_delete_repo — fixture repo with one deletable and two protected
# dispatchers, all pointing at CLOSED + long-stale issues.
setup_delete_repo() {
    local repo
    repo=$(setup_audit_repo)

    # renamed precondition: a tracked file that is later renamed away, so
    # find_renamed_path() resolves the stale token to its new home.
    mkdir -p "$repo/bin"
    printf '#!/bin/bash\necho renamed-fixture\n' > "$repo/bin/renamed-old.sh"
    git -C "$repo" add bin/renamed-old.sh
    backdate_commit "$repo" 300 "add renamed-old.sh"
    git -C "$repo" mv bin/renamed-old.sh bin/renamed-new.sh
    backdate_commit "$repo" 290 "rename renamed-old.sh -> renamed-new.sh"

    printf '#!/bin/bash\n# Tests: bin/never-existed.sh\n' \
        > "$repo/tests/feature-100-orphan.sh"
    printf '#!/bin/bash\n# Tests: bin/also-gone.sh (annotated)\n' \
        > "$repo/tests/feature-300-malformed.sh"
    printf '#!/bin/bash\n# Tests: bin/renamed-old.sh\n' \
        > "$repo/tests/feature-400-renamed.sh"
    git -C "$repo" add tests/feature-100-orphan.sh tests/feature-300-malformed.sh tests/feature-400-renamed.sh
    backdate_commit "$repo" 200 "stale dispatchers"

    echo "$repo"
}

# ── Case 29/30/31: flagless (apply-by-default) run really deletes ────────────
STUB29=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB29" "closed"
REPO29=$(setup_delete_repo)

EXIT29=0
OUT29=$(cd "$REPO29" && PATH="$STUB29:$PATH" run_with_timeout bash "$REPO29/bin/audit-tests.sh" 2>&1) || EXIT29=$?

# Case 29: the orphan dispatcher is reported DELETED: and is gone from disk.
if echo "$OUT29" | grep -q "^DELETED: tests/feature-100-orphan.sh$"; then
    pass "Case 29a: orphan dispatcher reported as DELETED:"
else
    fail "Case 29a: expected 'DELETED: tests/feature-100-orphan.sh' (exit=$EXIT29, output: $OUT29)"
fi

if [[ ! -e "$REPO29/tests/feature-100-orphan.sh" ]]; then
    pass "Case 29b: orphan dispatcher actually removed from disk"
else
    fail "Case 29b: orphan dispatcher still on disk after flagless run"
fi

if git -C "$REPO29" status --porcelain | grep -qE '^D  tests/feature-100-orphan\.sh$'; then
    pass "Case 29c: deletion staged in the index (git rm, not plain rm)"
else
    fail "Case 29c: deletion not staged: $(git -C "$REPO29" status --porcelain)"
fi

# Case 30: a prose token makes the file undecidable — no candidacy, no deletion.
if echo "$OUT29" | grep -q "^MALFORMED_HEADER: tests/feature-300-malformed.sh$"; then
    pass "Case 30a: prose-token dispatcher reported as MALFORMED_HEADER:"
else
    fail "Case 30a: expected 'MALFORMED_HEADER: tests/feature-300-malformed.sh' (output: $OUT29)"
fi

if ! echo "$OUT29" | grep -q "^CANDIDATE: tests/feature-300-malformed.sh$"; then
    pass "Case 30b: prose-token dispatcher is not a candidate"
else
    fail "Case 30b: prose-token dispatcher must not be a candidate (output: $OUT29)"
fi

if [[ -e "$REPO29/tests/feature-300-malformed.sh" ]]; then
    pass "Case 30c: prose-token dispatcher NOT removed"
else
    fail "Case 30c: prose-token dispatcher was deleted — undecidable files must survive"
fi

# Case 31: a renamed token means the target is alive.
if ! echo "$OUT29" | grep -q "^CANDIDATE: tests/feature-400-renamed.sh$"; then
    pass "Case 31a: renamed-token dispatcher is not a candidate (target alive)"
else
    fail "Case 31a: renamed-token dispatcher must not be a candidate (output: $OUT29)"
fi

if [[ -e "$REPO29/tests/feature-400-renamed.sh" ]]; then
    pass "Case 31b: renamed-token dispatcher NOT removed"
else
    fail "Case 31b: renamed-token dispatcher was deleted — rename detection failed"
fi

# Case 31c: the retired label must not come back anywhere in the output.
if ! echo "$OUT29" | grep -q "SKIP_DELETE_HAS_A_OR_B"; then
    pass "Case 31c: retired SKIP_DELETE_HAS_A_OR_B label is gone"
else
    fail "Case 31c: retired SKIP_DELETE_HAS_A_OR_B label still emitted (output: $OUT29)"
fi

# ── Case 32: --dry-run over the same fixture removes nothing ─────────────────
# The same classification is still reported; the DELETED: / SKIP_DELETE_* tokens
# are apply-only by design, so their ABSENCE under --dry-run is itself part of
# the contract being pinned.
STUB32=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB32" "closed"
REPO32=$(setup_delete_repo)
PORC32_BEFORE=$(git -C "$REPO32" status --porcelain)

EXIT32=0
OUT32=$(cd "$REPO32" && PATH="$STUB32:$PATH" run_with_timeout bash "$REPO32/bin/audit-tests.sh" --dry-run 2>&1) || EXIT32=$?

DRY_MISSING=""
for f in feature-100-orphan.sh feature-300-malformed.sh feature-400-renamed.sh; do
    [[ -e "$REPO32/tests/$f" ]] || DRY_MISSING="$DRY_MISSING $f"
done
if [[ -z "$DRY_MISSING" ]]; then
    pass "Case 32a: --dry-run removed nothing from disk"
else
    fail "Case 32a: --dry-run deleted files:$DRY_MISSING (output: $OUT32)"
fi

if [[ "$(git -C "$REPO32" status --porcelain)" == "$PORC32_BEFORE" ]]; then
    pass "Case 32b: --dry-run left the git index untouched"
else
    fail "Case 32b: --dry-run dirtied the index: $(git -C "$REPO32" status --porcelain)"
fi

if echo "$OUT32" | grep -q "^CANDIDATE: tests/feature-100-orphan.sh$" \
   && ! echo "$OUT32" | grep -qE "^CANDIDATE: tests/feature-(300-malformed|400-renamed)\.sh$"; then
    pass "Case 32c: --dry-run classifies exactly the orphan as CANDIDATE:"
else
    fail "Case 32c: --dry-run candidate set wrong (output: $OUT32)"
fi

if ! echo "$OUT32" | grep -qE "^(DELETED|SKIP_DELETE_[A-Z_]+):"; then
    pass "Case 32d: --dry-run emits no DELETED:/SKIP_DELETE_* lines"
else
    fail "Case 32d: --dry-run emitted apply-only classification lines (output: $OUT32)"
fi

fi  # end [[ -f "$AUDIT_TESTS" ]]
