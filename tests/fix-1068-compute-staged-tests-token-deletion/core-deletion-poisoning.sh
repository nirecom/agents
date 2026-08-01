# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 1: Core deletion-poisoning bug (T1, T3, T4)
# Mixed case: one staged deletion + one staged modification under tests/.
# EXPECTED: FAIL pre-fix on all three (bug returns NULL for the whole staged
# set whenever any staged tests/ path is a deletion).
# ===========================================================================

echo "=== fix-1068: computeStagedTestsToken deletion-poisoning ==="

# ---------------------------------------------------------------------------
# T1 — Mixed case: one staged deletion + one staged modification under tests/.
# The non-deleted, modified file must still produce a valid non-null token.
# EXPECTED: FAIL pre-fix (bug returns NULL for the whole staged set).
# ---------------------------------------------------------------------------
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

TOKEN_MIXED_1=$(call_compute_token "$REPO_MIXED")
if is_valid_hex_token "$TOKEN_MIXED_1"; then
    pass "T1. mixed deletion+modification: non-deleted staged tests/ file still yields a non-null hex token"
else
    fail "T1. mixed deletion+modification: expected valid hex token, got: $TOKEN_MIXED_1 (deletion poisoned the whole staged set — issue #1068)"
fi

# ---------------------------------------------------------------------------
# T3 — Determinism on the mixed case: calling twice in a row returns the same
# non-null token (build on T1's repo state; require non-null so a trivial
# NULL==NULL coincidence pre-fix is not mistaken for real determinism).
# EXPECTED: FAIL pre-fix (root cause identical to T1 — token is NULL, not a
# stable hash).
# ---------------------------------------------------------------------------
TOKEN_MIXED_2=$(call_compute_token "$REPO_MIXED")
if is_valid_hex_token "$TOKEN_MIXED_1" && [ "$TOKEN_MIXED_1" = "$TOKEN_MIXED_2" ]; then
    pass "T3. mixed case is deterministic across repeated calls (non-null, stable)"
else
    fail "T3. mixed case determinism: first=$TOKEN_MIXED_1 second=$TOKEN_MIXED_2 (expected equal, non-null hex — see T1 root cause)"
fi

# ---------------------------------------------------------------------------
# T4 — Change detection on the mixed case: modifying the content of the
# non-deleted staged file (while the deletion is still staged) must change
# the token.
# EXPECTED: FAIL pre-fix (mixed-case token stays NULL regardless of content
# changes to the surviving file — same root cause as T1).
# ---------------------------------------------------------------------------
printf 'modify me v3 - changed again\n' > "$REPO_MIXED/tests/modified.sh"
git -C "$REPO_MIXED" add tests/modified.sh
TOKEN_MIXED_3=$(call_compute_token "$REPO_MIXED")
if is_valid_hex_token "$TOKEN_MIXED_3" && [ "$TOKEN_MIXED_3" != "$TOKEN_MIXED_1" ]; then
    pass "T4. mixed case: modifying the surviving staged file's content changes the token"
else
    fail "T4. mixed case change detection: before=$TOKEN_MIXED_1 after=$TOKEN_MIXED_3 (expected non-null and different — see T1 root cause)"
fi

# ---------------------------------------------------------------------------
# T21 — Concern C1 (HIGH): oracle test. Every case above (and throughout this
# suite) only checks RELATIVE properties of the token — non-null, stable
# across repeated calls, changes when content changes. None of them would
# catch an implementation with a wrong digest algorithm, wrong row ordering,
# wrong separator, or wrong path identity fed into the hash — such a bug
# would still satisfy every relative-property assertion in this suite. This
# case closes that gap: it independently computes the EXPECTED token from
# first principles (via expected_token_for — sorted "path\tblob-OID" rows,
# joined by "\n", sha256, hex, first 16 chars — see the dispatcher's helper
# for the exact algorithm) and asserts computeStagedTestsToken's ACTUAL
# return value equals it byte-for-byte.
#
# Fixture: deliberately reuses T15's shape (one staged deletion that poisons
# pre-fix + one M-status survivor + one A-status survivor under tests/) so
# the oracle also exercises the multi-survivor path, not just a trivial
# single-file case.
# EXPECTED: FAIL pre-fix — actual is NULL, expected is a real hex value
# (independently computed); they can never coincide while the bug excludes
# nothing. PASS post-fix, exactly (not just "both non-null").
# ---------------------------------------------------------------------------
REPO_ORACLE="$TMPDIR_BASE/repo-oracle"
init_repo "$REPO_ORACLE"
mkdir -p "$REPO_ORACLE/tests"
printf 'delete me\n' > "$REPO_ORACLE/tests/deleted.sh"
printf 'survivor A v1\n' > "$REPO_ORACLE/tests/survivorA.sh"
git -C "$REPO_ORACLE" add tests/deleted.sh tests/survivorA.sh
(cd "$REPO_ORACLE" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_ORACLE" rm -q tests/deleted.sh
# `git rm` removes the now-empty tests/ directory on this platform (Windows/MSYS
# git) — re-create it before staging the surviving files.
mkdir -p "$REPO_ORACLE/tests"
printf 'survivor A v2\n' > "$REPO_ORACLE/tests/survivorA.sh"
printf 'survivor B new\n' > "$REPO_ORACLE/tests/survivorB.sh"
git -C "$REPO_ORACLE" add tests/survivorA.sh tests/survivorB.sh

EXPECTED_ORACLE=$(expected_token_for "$REPO_ORACLE" tests/survivorA.sh tests/survivorB.sh)
ACTUAL_ORACLE=$(call_compute_token "$REPO_ORACLE")
if is_valid_hex_token "$EXPECTED_ORACLE" && [ "$ACTUAL_ORACLE" = "$EXPECTED_ORACLE" ]; then
    pass "T21. oracle: computeStagedTestsToken's actual output equals an independently-computed expected token (sorted path\\toid rows, sha256, first 16 hex chars)"
else
    fail "T21. oracle: expected=$EXPECTED_ORACLE (independently computed) actual=$ACTUAL_ORACLE — a wrong digest/ordering/separator/path-identity in the implementation would diverge here even if every other relative-property test in this suite passes"
fi
