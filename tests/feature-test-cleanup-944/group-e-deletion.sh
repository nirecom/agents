# Group E: audit-tests.sh REAL deletion path (Cases 29-32)
# Tests: bin/audit-tests.sh, bin/lib/test-frontmatter-fix.sh
# Tags: audit-tests, deletion, apply-by-default, scope:issue-specific, TL2
# Sourced by tests/feature-test-cleanup-944.sh
#
# Every other group exercises audit-tests.sh with --dry-run (or via the
# separate --fix-headers path), so the branch that actually removes files —
# `if [[ "$APPLY" -eq 1 ]]` → classify_tests_header → git rm / DELETED: /
# SKIP_DELETE_HAS_A_OR_B: — was never executed by any test. Under the
# apply-by-default convention a flagless run of audit-tests.sh DELETES retired
# test files, so that branch is the highest-blast-radius code in this script.
#
# All work happens inside a throwaway fixture repo built by setup_audit_repo
# (mktemp -d under $TMPDIR_BASE). The real tests/ tree is never an input.
#
# Fixture design — the three CHR_ALL_C outcomes (bin/lib/test-frontmatter-fix.sh):
#   all-C : every `# Tests:` token is format-OK, missing, and not renamed
#           → CHR_ALL_C=1 → deleted
#   has-A : a token that fails FRONTMATTER_TOKEN_VALID_RE (annotated form)
#           → CHR_HAS_A=1 → kept
#   has-B : a format-OK token whose path was renamed away in git history
#           → CHR_HAS_B=1 → kept

if [[ ! -f "$AUDIT_TESTS" ]]; then
    skip "Cases 29-32: bin/audit-tests.sh does not exist yet"
else

# The shared make_gh_stub (tests/feature-test-cleanup-944.sh) emits
# "<state> <closed_at>" pairs with a long-past default closed_at, which is what
# the deletion path needs: audit-tests.sh filters on the issue's closed_at
# (#1557), not on the file's commit date.

# setup_delete_repo — fixture repo with one deletable and two protected
# dispatchers, all pointing at CLOSED + long-stale issues.
setup_delete_repo() {
    local repo
    repo=$(setup_audit_repo)

    # has-B precondition: a tracked file that is later renamed away, so
    # find_renamed_path() resolves the stale token to its new home.
    mkdir -p "$repo/bin"
    printf '#!/bin/bash\necho renamed-fixture\n' > "$repo/bin/renamed-old.sh"
    git -C "$repo" add bin/renamed-old.sh
    backdate_commit "$repo" 300 "add renamed-old.sh"
    git -C "$repo" mv bin/renamed-old.sh bin/renamed-new.sh
    backdate_commit "$repo" 290 "rename renamed-old.sh -> renamed-new.sh"

    printf '#!/bin/bash\n# Tests: bin/never-existed.sh\n' \
        > "$repo/tests/feature-100-allc.sh"
    printf '#!/bin/bash\n# Tests: bin/also-gone.sh (annotated)\n' \
        > "$repo/tests/feature-300-hasa.sh"
    printf '#!/bin/bash\n# Tests: bin/renamed-old.sh\n' \
        > "$repo/tests/feature-400-hasb.sh"
    git -C "$repo" add tests/feature-100-allc.sh tests/feature-300-hasa.sh tests/feature-400-hasb.sh
    backdate_commit "$repo" 200 "stale dispatchers"

    echo "$repo"
}

# ── Case 29/30/31: flagless (apply-by-default) run really deletes ────────────
STUB29=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB29" "closed"
REPO29=$(setup_delete_repo)

EXIT29=0
OUT29=$(cd "$REPO29" && PATH="$STUB29:$PATH" run_with_timeout bash "$REPO29/bin/audit-tests.sh" 2>&1) || EXIT29=$?

# Case 29: the all-C dispatcher is reported DELETED: and is gone from disk.
if echo "$OUT29" | grep -q "^DELETED: tests/feature-100-allc.sh$"; then
    pass "Case 29a: all-C dispatcher reported as DELETED:"
else
    fail "Case 29a: expected 'DELETED: tests/feature-100-allc.sh' (exit=$EXIT29, output: $OUT29)"
fi

if [[ ! -e "$REPO29/tests/feature-100-allc.sh" ]]; then
    pass "Case 29b: all-C dispatcher actually removed from disk"
else
    fail "Case 29b: all-C dispatcher still on disk after flagless run"
fi

if git -C "$REPO29" status --porcelain | grep -qE '^D  tests/feature-100-allc\.sh$'; then
    pass "Case 29c: deletion staged in the index (git rm, not plain rm)"
else
    fail "Case 29c: deletion not staged: $(git -C "$REPO29" status --porcelain)"
fi

# Case 30: an A-tier token blocks deletion.
if echo "$OUT29" | grep -q "^SKIP_DELETE_HAS_A_OR_B: tests/feature-300-hasa.sh$"; then
    pass "Case 30a: A-tier dispatcher reported as SKIP_DELETE_HAS_A_OR_B:"
else
    fail "Case 30a: expected 'SKIP_DELETE_HAS_A_OR_B: tests/feature-300-hasa.sh' (output: $OUT29)"
fi

if [[ -e "$REPO29/tests/feature-300-hasa.sh" ]]; then
    pass "Case 30b: A-tier dispatcher NOT removed"
else
    fail "Case 30b: A-tier dispatcher was deleted — SKIP_DELETE gate failed"
fi

# Case 31: a B-tier (renamed) token blocks deletion.
if echo "$OUT29" | grep -q "^SKIP_DELETE_HAS_A_OR_B: tests/feature-400-hasb.sh$"; then
    pass "Case 31a: B-tier (renamed token) dispatcher reported as SKIP_DELETE_HAS_A_OR_B:"
else
    fail "Case 31a: expected 'SKIP_DELETE_HAS_A_OR_B: tests/feature-400-hasb.sh' (output: $OUT29)"
fi

if [[ -e "$REPO29/tests/feature-400-hasb.sh" ]]; then
    pass "Case 31b: B-tier dispatcher NOT removed"
else
    fail "Case 31b: B-tier dispatcher was deleted — rename detection failed"
fi

# ── Case 32: --dry-run over the same fixture removes nothing ─────────────────
# Same classification is still reported (all three stay CANDIDATE:); the
# DELETED: / SKIP_DELETE_HAS_A_OR_B: tokens are apply-only by design, so their
# ABSENCE under --dry-run is itself part of the contract being pinned.
STUB32=$(mktemp -d -p "$TMPDIR_BASE")
make_gh_stub "$STUB32" "closed"
REPO32=$(setup_delete_repo)
PORC32_BEFORE=$(git -C "$REPO32" status --porcelain)

EXIT32=0
OUT32=$(cd "$REPO32" && PATH="$STUB32:$PATH" run_with_timeout bash "$REPO32/bin/audit-tests.sh" --dry-run 2>&1) || EXIT32=$?

DRY_MISSING=""
for f in feature-100-allc.sh feature-300-hasa.sh feature-400-hasb.sh; do
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

DRY_UNCLASSIFIED=""
for f in feature-100-allc.sh feature-300-hasa.sh feature-400-hasb.sh; do
    echo "$OUT32" | grep -q "^CANDIDATE: tests/$f$" || DRY_UNCLASSIFIED="$DRY_UNCLASSIFIED $f"
done
if [[ -z "$DRY_UNCLASSIFIED" ]]; then
    pass "Case 32c: --dry-run still classifies all three as CANDIDATE:"
else
    fail "Case 32c: --dry-run lost candidates:$DRY_UNCLASSIFIED (output: $OUT32)"
fi

if ! echo "$OUT32" | grep -qE "^(DELETED|SKIP_DELETE_HAS_A_OR_B):"; then
    pass "Case 32d: --dry-run emits no DELETED:/SKIP_DELETE_HAS_A_OR_B: lines"
else
    fail "Case 32d: --dry-run emitted apply-only classification lines (output: $OUT32)"
fi

fi  # end [[ -f "$AUDIT_TESTS" ]]
