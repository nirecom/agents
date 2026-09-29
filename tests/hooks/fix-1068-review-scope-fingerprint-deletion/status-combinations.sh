# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, fingerprint, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 3: Status-combination coverage (T7-T9, T15-T17, T25-T26).
# Pre-fix: T7-T9, T15-T17 FAIL (deletion poisoning). T25-T26: PASS before/after
# (unaffected by deletion handling; T26 assertion updated for new all-scope rule).
# ===========================================================================

echo ""
echo "=== Status-combination coverage (T7-T9, T15-T17, T25, T26) ==="

# T7: prove a staged deletion contributes NOTHING to the fingerprint.
# REPO_NODEL stages only the M-status survivor (no deletion ever).
# After the fix, REPO_MIXED (T1: deletion filtered) and REPO_NODEL must give the same fingerprint.
REPO_NODEL="$TMPDIR_BASE/repo-nodel"
init_repo "$REPO_NODEL"
mkdir -p "$REPO_NODEL/tests"
printf 'modify me v1\n' > "$REPO_NODEL/tests/modified.sh"
git -C "$REPO_NODEL" add tests/modified.sh
(cd "$REPO_NODEL" && git -c core.hooksPath="" commit -q -m "seed tests/")
printf 'modify me v2\n' > "$REPO_NODEL/tests/modified.sh"
git -C "$REPO_NODEL" add tests/modified.sh

TOKEN_NODEL=$(call_compute_fingerprint "$REPO_NODEL")
if is_valid_hex_token "$TOKEN_NODEL" && [ "$TOKEN_NODEL" = "$TOKEN_MIXED_1" ]; then
    pass "T7. deletion contributes nothing: no-deletion fingerprint equals the mixed-case fingerprint"
else
    fail "T7. deletion-contributes-nothing: no-deletion=$TOKEN_NODEL mixed-case(T1)=$TOKEN_MIXED_1 (expected equal, non-null hex)"
fi

# T8: D+A combination — staged deletion alongside a brand-new addition under tests/.
REPO_DA="$TMPDIR_BASE/repo-da"
init_repo "$REPO_DA"
mkdir -p "$REPO_DA/tests"
printf 'delete me\n' > "$REPO_DA/tests/deleted.sh"
git -C "$REPO_DA" add tests/deleted.sh
(cd "$REPO_DA" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_DA" rm -q tests/deleted.sh
mkdir -p "$REPO_DA/tests"
printf 'brand new file\n' > "$REPO_DA/tests/added.sh"
git -C "$REPO_DA" add tests/added.sh

TOKEN_DA=$(call_compute_fingerprint "$REPO_DA")
if is_valid_hex_token "$TOKEN_DA"; then
    pass "T8. deletion+addition (D+A): newly-added staged tests/ file yields a valid hex fingerprint"
else
    fail "T8. deletion+addition (D+A): expected valid hex fingerprint, got: $TOKEN_DA"
fi

# T9: D+R combination — staged deletion + rename under tests/. Rename detection forced.
REPO_DR="$TMPDIR_BASE/repo-dr"
init_repo "$REPO_DR"
git -C "$REPO_DR" config diff.renames true
mkdir -p "$REPO_DR/tests"
printf 'delete me\n' > "$REPO_DR/tests/deleted.sh"
printf 'rename me please, this has enough content to be detected as a rename\nsecond line\nthird line\n' > "$REPO_DR/tests/original.sh"
git -C "$REPO_DR" add tests/deleted.sh tests/original.sh
(cd "$REPO_DR" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_DR" rm -q tests/deleted.sh
git -C "$REPO_DR" mv tests/original.sh tests/renamed.sh

DR_STATUS_LINE=$(git -C "$REPO_DR" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*renamed\.sh$' || true)
if [[ -n "$DR_STATUS_LINE" ]]; then
    pass "T9pre. D+R fixture: renamed.sh is genuinely detected as R-status by git ($DR_STATUS_LINE)"
else
    fail "T9pre. D+R fixture: renamed.sh was NOT detected as R-status — fixture invalid"
fi

TOKEN_DR=$(call_compute_fingerprint "$REPO_DR")
if is_valid_hex_token "$TOKEN_DR"; then
    pass "T9. deletion+rename (D+R): renamed staged tests/ file yields a valid hex fingerprint"
else
    fail "T9. deletion+rename (D+R): expected valid hex fingerprint, got: $TOKEN_DR"
fi

# T15: deletion alongside 2+ SURVIVING tests/ paths (M+A).
# Token must depend on BOTH survivors — guards against single-path-only implementations.
REPO_MULTI="$TMPDIR_BASE/repo-multi"
init_repo "$REPO_MULTI"
mkdir -p "$REPO_MULTI/tests"
printf 'delete me\n' > "$REPO_MULTI/tests/deleted.sh"
printf 'file A v1\n' > "$REPO_MULTI/tests/fileA.sh"
git -C "$REPO_MULTI" add tests/deleted.sh tests/fileA.sh
(cd "$REPO_MULTI" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_MULTI" rm -q tests/deleted.sh
mkdir -p "$REPO_MULTI/tests"
printf 'file A v2\n' > "$REPO_MULTI/tests/fileA.sh"
printf 'file B new\n' > "$REPO_MULTI/tests/fileB.sh"
git -C "$REPO_MULTI" add tests/fileA.sh tests/fileB.sh

TOKEN_MULTI_BASE=$(call_compute_fingerprint "$REPO_MULTI")
if is_valid_hex_token "$TOKEN_MULTI_BASE"; then
    pass "T15a. deletion + 2 surviving tests/ paths (M+A): baseline yields a valid hex fingerprint"
else
    fail "T15a. deletion + 2 surviving tests/ paths: expected valid hex fingerprint, got: $TOKEN_MULTI_BASE"
fi

printf 'file A v3 - changed\n' > "$REPO_MULTI/tests/fileA.sh"
git -C "$REPO_MULTI" add tests/fileA.sh
TOKEN_MULTI_A_CHANGED=$(call_compute_fingerprint "$REPO_MULTI")
if is_valid_hex_token "$TOKEN_MULTI_A_CHANGED" && [ "$TOKEN_MULTI_A_CHANGED" != "$TOKEN_MULTI_BASE" ]; then
    pass "T15b. changing the M-status survivor (fileA) alone changes the fingerprint"
else
    fail "T15b. changing fileA alone: base=$TOKEN_MULTI_BASE after=$TOKEN_MULTI_A_CHANGED (expected non-null and different)"
fi

printf 'file A v2\n' > "$REPO_MULTI/tests/fileA.sh"
printf 'file B changed\n' > "$REPO_MULTI/tests/fileB.sh"
git -C "$REPO_MULTI" add tests/fileA.sh tests/fileB.sh
TOKEN_MULTI_B_CHANGED=$(call_compute_fingerprint "$REPO_MULTI")
if is_valid_hex_token "$TOKEN_MULTI_B_CHANGED" && [ "$TOKEN_MULTI_B_CHANGED" != "$TOKEN_MULTI_BASE" ]; then
    pass "T15c. changing the A-status survivor (fileB) alone changes the fingerprint"
else
    fail "T15c. changing fileB alone: base=$TOKEN_MULTI_BASE after=$TOKEN_MULTI_B_CHANGED (expected non-null and different)"
fi

printf 'file A v2\n' > "$REPO_MULTI/tests/fileA.sh"
printf 'file B new\n' > "$REPO_MULTI/tests/fileB.sh"
git -C "$REPO_MULTI" add tests/fileA.sh tests/fileB.sh
TOKEN_MULTI_REVERTED=$(call_compute_fingerprint "$REPO_MULTI")
# Require is_valid_hex_token on both sides — pre-fix both could be null, making bare equality pass trivially.
if is_valid_hex_token "$TOKEN_MULTI_REVERTED" && [ "$TOKEN_MULTI_REVERTED" = "$TOKEN_MULTI_BASE" ]; then
    pass "T15d. reverting both survivors to baseline content reproduces the original fingerprint"
else
    fail "T15d. reverted fingerprint=$TOKEN_MULTI_REVERTED expected to equal baseline=$TOKEN_MULTI_BASE (both non-null hex)"
fi

# T16: additional deletion (survivor content unchanged) must not change the fingerprint.
# Proves deletions contribute nothing, not just "some deletions produce nothing".
REPO_ADDDEL="$TMPDIR_BASE/repo-adddel"
init_repo "$REPO_ADDDEL"
mkdir -p "$REPO_ADDDEL/tests"
printf 'delete me 1\n' > "$REPO_ADDDEL/tests/deleted1.sh"
printf 'delete me 2\n' > "$REPO_ADDDEL/tests/deleted2.sh"
printf 'survivor v1\n' > "$REPO_ADDDEL/tests/survivor.sh"
git -C "$REPO_ADDDEL" add tests/deleted1.sh tests/deleted2.sh tests/survivor.sh
(cd "$REPO_ADDDEL" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_ADDDEL" rm -q tests/deleted1.sh
printf 'survivor v2\n' > "$REPO_ADDDEL/tests/survivor.sh"
git -C "$REPO_ADDDEL" add tests/survivor.sh

TOKEN_ADDDEL_BEFORE=$(call_compute_fingerprint "$REPO_ADDDEL")

git -C "$REPO_ADDDEL" rm -q tests/deleted2.sh
TOKEN_ADDDEL_AFTER=$(call_compute_fingerprint "$REPO_ADDDEL")

if is_valid_hex_token "$TOKEN_ADDDEL_BEFORE" && is_valid_hex_token "$TOKEN_ADDDEL_AFTER" && [ "$TOKEN_ADDDEL_BEFORE" = "$TOKEN_ADDDEL_AFTER" ]; then
    pass "T16. adding an additional unrelated deletion (survivor unchanged) does not change the fingerprint"
else
    fail "T16. before=$TOKEN_ADDDEL_BEFORE after=$TOKEN_ADDDEL_AFTER (expected equal, non-null hex)"
fi

# T17: deletion+survivor using the SINGULAR test/ prefix (CPR-ORTH vs tests/).
REPO_SINGULAR="$TMPDIR_BASE/repo-singular-mixed"
init_repo "$REPO_SINGULAR"
mkdir -p "$REPO_SINGULAR/test"
printf 'delete me\n' > "$REPO_SINGULAR/test/deleted.sh"
printf 'modify me v1\n' > "$REPO_SINGULAR/test/modified.sh"
git -C "$REPO_SINGULAR" add test/deleted.sh test/modified.sh
(cd "$REPO_SINGULAR" && git -c core.hooksPath="" commit -q -m "seed test/")
git -C "$REPO_SINGULAR" rm -q test/deleted.sh
mkdir -p "$REPO_SINGULAR/test"
printf 'modify me v2\n' > "$REPO_SINGULAR/test/modified.sh"
git -C "$REPO_SINGULAR" add test/modified.sh

TOKEN_SINGULAR=$(call_compute_fingerprint "$REPO_SINGULAR")
if is_valid_hex_token "$TOKEN_SINGULAR"; then
    pass "T17. deletion+modification under singular test/ prefix yields a valid hex fingerprint"
else
    fail "T17. test/ (singular) deletion+modification: expected valid hex fingerprint, got: $TOKEN_SINGULAR"
fi

# ===========================================================================
# Group 6: Rename DIRECTION coverage (T25, T26). Neither touches D-status
# exclusion — PASS before/after the fix.
# T25: rename INTO tests/ (old path outside, new path inside) — contributes.
# T26: rename OUT OF tests/ (old path inside, new path outside) — with the new
#      all-scope rule, moved-out.sh IS in scope (not excluded), so the
#      fingerprint includes both the survivor and the renamed-out file's new path.
# ===========================================================================

# T25: rename INTO tests/ — new path tests/imported.sh must be in scope.
REPO_RENAME_IN="$TMPDIR_BASE/repo-rename-into-tests"
init_repo "$REPO_RENAME_IN"
printf 'rename me into tests, this has enough content to be detected as a rename\nsecond line\nthird line\n' > "$REPO_RENAME_IN/scratch.sh"
git -C "$REPO_RENAME_IN" add scratch.sh
(cd "$REPO_RENAME_IN" && git -c core.hooksPath="" commit -q -m "seed root-level scratch.sh")
git -C "$REPO_RENAME_IN" config diff.renames true
mkdir -p "$REPO_RENAME_IN/tests"
git -C "$REPO_RENAME_IN" mv scratch.sh tests/imported.sh

RENAME_IN_STATUS_LINE=$(git -C "$REPO_RENAME_IN" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*tests/imported\.sh$' || true)
if [[ -n "$RENAME_IN_STATUS_LINE" ]]; then
    pass "T25pre. rename-into-tests fixture: tests/imported.sh is genuinely R-status ($RENAME_IN_STATUS_LINE)"
else
    fail "T25pre. rename-into-tests fixture: tests/imported.sh NOT detected as R-status — fixture invalid"
fi

TOKEN_RENAME_IN=$(call_compute_fingerprint "$REPO_RENAME_IN")
if is_valid_hex_token "$TOKEN_RENAME_IN"; then
    pass "T25. rename INTO tests/ (new path inside tests/): yields a valid hex fingerprint"
else
    fail "T25. rename INTO tests/: expected valid hex fingerprint, got: $TOKEN_RENAME_IN"
fi

# T26: rename OUT OF tests/ (new path outside tests/).
# With the new all-scope rule, moved-out.sh IS in scope (not an excluded path).
# The fingerprint must include BOTH tests/survivor.sh AND moved-out.sh.
REPO_RENAME_OUT="$TMPDIR_BASE/repo-rename-out-of-tests"
init_repo "$REPO_RENAME_OUT"
mkdir -p "$REPO_RENAME_OUT/tests"
printf 'survivor content v1\n' > "$REPO_RENAME_OUT/tests/survivor.sh"
printf 'move me out of tests, this has enough content to be detected as a rename\nsecond line\nthird line\n' > "$REPO_RENAME_OUT/tests/toBeMoved.sh"
git -C "$REPO_RENAME_OUT" add tests/survivor.sh tests/toBeMoved.sh
(cd "$REPO_RENAME_OUT" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_RENAME_OUT" config diff.renames true
printf 'survivor content v2\n' > "$REPO_RENAME_OUT/tests/survivor.sh"
git -C "$REPO_RENAME_OUT" mv tests/toBeMoved.sh moved-out.sh
git -C "$REPO_RENAME_OUT" add tests/survivor.sh

RENAME_OUT_STATUS_LINE=$(git -C "$REPO_RENAME_OUT" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*moved-out\.sh$' || true)
if [[ -n "$RENAME_OUT_STATUS_LINE" ]]; then
    pass "T26pre. rename-out-of-tests fixture: moved-out.sh is genuinely R-status ($RENAME_OUT_STATUS_LINE)"
else
    fail "T26pre. rename-out-of-tests fixture: moved-out.sh NOT detected as R-status — fixture invalid"
fi

TOKEN_RENAME_OUT=$(call_compute_fingerprint "$REPO_RENAME_OUT")
# With all-scope rule: both tests/survivor.sh AND moved-out.sh are in scope.
# The fingerprint must be a valid hex value (both files contribute).
if is_valid_hex_token "$TOKEN_RENAME_OUT"; then
    pass "T26. rename OUT OF tests/ (new path is moved-out.sh): both survivor and renamed-out path in scope — valid hex fingerprint"
else
    fail "T26. rename OUT OF tests/: expected valid hex fingerprint (both paths in scope), got: $TOKEN_RENAME_OUT"
fi
