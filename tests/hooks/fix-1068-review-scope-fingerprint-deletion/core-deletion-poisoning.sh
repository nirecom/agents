# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, fingerprint, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 1: Core deletion-poisoning bug (T1, T3, T4, T21).
# Mixed case: one staged deletion + one staged modification under tests/.
# Pre-fix: all FAIL (bug returns null for any deletion in staged set).
# ===========================================================================

echo "=== fix-1068: computeReviewScopeFingerprint deletion-poisoning ==="

# T1: mixed deletion+modification — non-deleted file must still produce a valid fingerprint.
REPO_MIXED="$TMPDIR_BASE/repo-mixed"
init_repo "$REPO_MIXED"
mkdir -p "$REPO_MIXED/tests"
printf 'delete me\n' > "$REPO_MIXED/tests/deleted.sh"
printf 'modify me v1\n' > "$REPO_MIXED/tests/modified.sh"
git -C "$REPO_MIXED" add tests/deleted.sh tests/modified.sh
(cd "$REPO_MIXED" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_MIXED" rm -q tests/deleted.sh
printf 'modify me v2\n' > "$REPO_MIXED/tests/modified.sh"
git -C "$REPO_MIXED" add tests/modified.sh

TOKEN_MIXED_1=$(call_compute_fingerprint "$REPO_MIXED")
if is_valid_hex_token "$TOKEN_MIXED_1"; then
    pass "T1. mixed deletion+modification: non-deleted staged tests/ file still yields a valid hex fingerprint"
else
    fail "T1. mixed deletion+modification: expected valid hex fingerprint, got: $TOKEN_MIXED_1 (deletion poisoned the staged set — issue #1068)"
fi

# T3: determinism on the mixed case — two calls return the same non-null fingerprint.
TOKEN_MIXED_2=$(call_compute_fingerprint "$REPO_MIXED")
if is_valid_hex_token "$TOKEN_MIXED_1" && [ "$TOKEN_MIXED_1" = "$TOKEN_MIXED_2" ]; then
    pass "T3. mixed case is deterministic across repeated calls (non-null, stable)"
else
    fail "T3. mixed case determinism: first=$TOKEN_MIXED_1 second=$TOKEN_MIXED_2 (expected equal, non-null hex)"
fi

# T4: change detection — modifying the surviving staged file must change the fingerprint.
printf 'modify me v3 - changed again\n' > "$REPO_MIXED/tests/modified.sh"
git -C "$REPO_MIXED" add tests/modified.sh
TOKEN_MIXED_3=$(call_compute_fingerprint "$REPO_MIXED")
if is_valid_hex_token "$TOKEN_MIXED_3" && [ "$TOKEN_MIXED_3" != "$TOKEN_MIXED_1" ]; then
    pass "T4. mixed case: modifying the surviving staged file changes the fingerprint"
else
    fail "T4. mixed case change detection: before=$TOKEN_MIXED_1 after=$TOKEN_MIXED_3 (expected non-null and different)"
fi

# T21: oracle — independently compute the expected fingerprint from first principles
# (sorted "path\tblob-OID" rows, joined by "\n", sha256, first 16 hex chars) and assert
# the actual output equals it byte-for-byte, closing relative-property gaps.
REPO_ORACLE="$TMPDIR_BASE/repo-oracle"
init_repo "$REPO_ORACLE"
mkdir -p "$REPO_ORACLE/tests"
printf 'delete me\n' > "$REPO_ORACLE/tests/deleted.sh"
printf 'survivor A v1\n' > "$REPO_ORACLE/tests/survivorA.sh"
git -C "$REPO_ORACLE" add tests/deleted.sh tests/survivorA.sh
(cd "$REPO_ORACLE" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_ORACLE" rm -q tests/deleted.sh
mkdir -p "$REPO_ORACLE/tests"
printf 'survivor A v2\n' > "$REPO_ORACLE/tests/survivorA.sh"
printf 'survivor B new\n' > "$REPO_ORACLE/tests/survivorB.sh"
git -C "$REPO_ORACLE" add tests/survivorA.sh tests/survivorB.sh

EXPECTED_ORACLE=$(expected_fingerprint_for "$REPO_ORACLE" tests/survivorA.sh tests/survivorB.sh)
ACTUAL_ORACLE=$(call_compute_fingerprint "$REPO_ORACLE")
if is_valid_hex_token "$EXPECTED_ORACLE" && [ "$ACTUAL_ORACLE" = "$EXPECTED_ORACLE" ]; then
    pass "T21. oracle: computeReviewScopeFingerprint actual output equals independently-computed expected fingerprint (sorted path\\toid rows, sha256, first 16 hex chars)"
else
    fail "T21. oracle: expected=$EXPECTED_ORACLE (independently computed) actual=$ACTUAL_ORACLE"
fi
