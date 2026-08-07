# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 3: Status-combination coverage (T7, T8, T9, T15)
# Concern 1 (no-deletion comparison), Concern 2 (D+A, D+R combinations), and
# Concern 4/C4 (2+ surviving tests/ paths staged alongside a deletion — every
# surviving path must contribute to the hash, not just the first one seen).
# EXPECTED: FAIL pre-fix on T7, T8, T9, T15 (same root cause as T1).
#
# NOTE: an earlier revision of this file included a T10 case asserting that
# an unmerged/conflict (U-status) staged path is excluded from the fingerprint
# the same way a deletion is. That assertion was removed — the agreed fix
# scope (issue #1068 / intent.md) is limited to excluding D-status (deleted)
# paths; U-status handling is out of scope and must not be asserted here.
# ===========================================================================

# ---------------------------------------------------------------------------
# T7 — Concern 1 (HIGH): prove a staged deletion contributes NOTHING to the
# hash of surviving paths. Build an independent repo where tests/modified.sh
# is staged at v2 content with NO deletion staged at all (deleted.sh is never
# created/staged here). Once the fix excludes non-A/M/R paths, the row set
# fed into the hash for REPO_MIXED (T1: modified.sh survives, deleted.sh is
# filtered out) and REPO_NODEL (only modified.sh was ever staged) is
# identical -> the tokens MUST be equal.
# EXPECTED: FAIL pre-fix (TOKEN_MIXED_1 is NULL, TOKEN_NODEL is a real hex
# value — they can never coincide while the bug is present).
# ---------------------------------------------------------------------------
REPO_NODEL="$TMPDIR_BASE/repo-nodel"
init_repo "$REPO_NODEL"
mkdir -p "$REPO_NODEL/tests"
printf 'modify me v1\n' > "$REPO_NODEL/tests/modified.sh"
git -C "$REPO_NODEL" add tests/modified.sh
(cd "$REPO_NODEL" && git -c core.hooksPath="" commit -q -m "seed tests/")
printf 'modify me v2\n' > "$REPO_NODEL/tests/modified.sh"
git -C "$REPO_NODEL" add tests/modified.sh

TOKEN_NODEL=$(call_compute_token "$REPO_NODEL")
if is_valid_hex_token "$TOKEN_NODEL" && [ "$TOKEN_NODEL" = "$TOKEN_MIXED_1" ]; then
    pass "T7. deletion contributes nothing to the hash: no-deletion-at-all token equals the mixed-case token"
else
    fail "T7. deletion-contributes-nothing: no-deletion token=$TOKEN_NODEL mixed-case token(T1)=$TOKEN_MIXED_1 (expected equal, non-null hex once the deletion is excluded from the hash)"
fi

# ---------------------------------------------------------------------------
# T8 — Concern 2 (HIGH): D+A combination — a staged deletion alongside a
# brand-new (never-committed) staged addition under tests/. Distinct from T1
# (D+M) because the surviving path has A status, not M status.
# EXPECTED: FAIL pre-fix (same root cause as T1 — the deletion poisons the
# whole staged set, including the newly added file).
# ---------------------------------------------------------------------------
REPO_DA="$TMPDIR_BASE/repo-da"
init_repo "$REPO_DA"
mkdir -p "$REPO_DA/tests"
printf 'delete me\n' > "$REPO_DA/tests/deleted.sh"
git -C "$REPO_DA" add tests/deleted.sh
(cd "$REPO_DA" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_DA" rm -q tests/deleted.sh
# `git rm` removes the now-empty tests/ directory on this platform (Windows/MSYS
# git) — re-create it before writing the surviving added file.
mkdir -p "$REPO_DA/tests"
printf 'brand new file\n' > "$REPO_DA/tests/added.sh"
git -C "$REPO_DA" add tests/added.sh

TOKEN_DA=$(call_compute_token "$REPO_DA")
if is_valid_hex_token "$TOKEN_DA"; then
    pass "T8. deletion+addition (D+A): newly-added staged tests/ file still yields a non-null hex token"
else
    fail "T8. deletion+addition (D+A): expected valid hex token, got: $TOKEN_DA (deletion poisoned the addition — issue #1068)"
fi

# ---------------------------------------------------------------------------
# T9 — Concern 2 (HIGH): D+R combination — a staged deletion of an unrelated
# tests/ file alongside a genuinely-detected rename of another tests/ file.
# Rename detection is forced via an explicit `git config diff.renames true`
# on the repo (per skills/_shared/test-design.md "config-dependent branches"
# rule) rather than relying on the ambient/global git config default, so this
# case is not accidentally a plain D+A in disguise.
# EXPECTED: FAIL pre-fix (same root cause as T1 — the unrelated deletion
# poisons the whole staged set, including the renamed file's row).
# ---------------------------------------------------------------------------
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

# Concern 7 (LOW): assert the fixture is genuinely detected as R-status by
# git itself before calling computeStagedTestsToken — do not merely assume
# `git mv` produces a rename row (rename detection depends on content
# similarity and the diff.renames config forced above).
DR_STATUS_LINE=$(git -C "$REPO_DR" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*renamed\.sh$' || true)
if [[ -n "$DR_STATUS_LINE" ]]; then
    pass "T9pre. D+R fixture: renamed.sh is genuinely detected as R-status by git ($DR_STATUS_LINE)"
else
    fail "T9pre. D+R fixture: renamed.sh was NOT detected as R-status by git — fixture invalid (name-status: $(git -C "$REPO_DR" diff --cached --name-status))"
fi

TOKEN_DR=$(call_compute_token "$REPO_DR")
if is_valid_hex_token "$TOKEN_DR"; then
    pass "T9. deletion+rename (D+R, forced rename detection): renamed staged tests/ file still yields a non-null hex token"
else
    fail "T9. deletion+rename (D+R): expected valid hex token, got: $TOKEN_DR (unrelated deletion poisoned the renamed entry — issue #1068)"
fi

# ---------------------------------------------------------------------------
# T15 — Concern 4 (HIGH): a deletion staged alongside 2+ SURVIVING tests/
# paths (mixed A + M statuses) must have the resulting token depend on BOTH
# surviving files' content — not just the first one an implementation happens
# to hash. Guards against a fix that filters D-status correctly but only
# hashes a single surviving path (e.g. picks the first match and drops the
# rest).
# EXPECTED: FAIL pre-fix (same root cause as T1 — the whole staged set is
# poisoned to NULL by the deletion, regardless of how many survivors exist).
# ---------------------------------------------------------------------------
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

TOKEN_MULTI_BASE=$(call_compute_token "$REPO_MULTI")
if is_valid_hex_token "$TOKEN_MULTI_BASE"; then
    pass "T15a. deletion + 2 surviving tests/ paths (M+A): baseline yields a non-null hex token"
else
    fail "T15a. deletion + 2 surviving tests/ paths: expected valid hex token, got: $TOKEN_MULTI_BASE"
fi

# Change ONLY fileA (M-status survivor) — token must change if fileA's
# content is actually included in the hash.
printf 'file A v3 - changed\n' > "$REPO_MULTI/tests/fileA.sh"
git -C "$REPO_MULTI" add tests/fileA.sh
TOKEN_MULTI_A_CHANGED=$(call_compute_token "$REPO_MULTI")
if is_valid_hex_token "$TOKEN_MULTI_A_CHANGED" && [ "$TOKEN_MULTI_A_CHANGED" != "$TOKEN_MULTI_BASE" ]; then
    pass "T15b. changing the M-status survivor (fileA) alone changes the token"
else
    fail "T15b. changing fileA alone: base=$TOKEN_MULTI_BASE after=$TOKEN_MULTI_A_CHANGED (expected non-null and different — fileA may be dropped from the hash)"
fi

# Revert fileA, change ONLY fileB (A-status survivor) — token must change if
# fileB's content is actually included in the hash too (not just the first
# survivor an implementation happens to pick up).
printf 'file A v2\n' > "$REPO_MULTI/tests/fileA.sh"
printf 'file B changed\n' > "$REPO_MULTI/tests/fileB.sh"
git -C "$REPO_MULTI" add tests/fileA.sh tests/fileB.sh
TOKEN_MULTI_B_CHANGED=$(call_compute_token "$REPO_MULTI")
if is_valid_hex_token "$TOKEN_MULTI_B_CHANGED" && [ "$TOKEN_MULTI_B_CHANGED" != "$TOKEN_MULTI_BASE" ]; then
    pass "T15c. changing the A-status survivor (fileB) alone changes the token"
else
    fail "T15c. changing fileB alone: base=$TOKEN_MULTI_BASE after=$TOKEN_MULTI_B_CHANGED (expected non-null and different — fileB may be dropped from the hash)"
fi

# Revert both fileA and fileB back to their baseline content — token must
# reproduce the original baseline token exactly (determinism across both
# surviving paths, not just one).
printf 'file A v2\n' > "$REPO_MULTI/tests/fileA.sh"
printf 'file B new\n' > "$REPO_MULTI/tests/fileB.sh"
git -C "$REPO_MULTI" add tests/fileA.sh tests/fileB.sh
TOKEN_MULTI_REVERTED=$(call_compute_token "$REPO_MULTI")
# Concern C3 (MEDIUM): require is_valid_hex_token on both sides, not just
# equality — pre-fix, TOKEN_MULTI_BASE and TOKEN_MULTI_REVERTED are BOTH
# NULL, which would make a bare equality check trivially (and falsely) pass
# without proving anything about real determinism.
if is_valid_hex_token "$TOKEN_MULTI_REVERTED" && [ "$TOKEN_MULTI_REVERTED" = "$TOKEN_MULTI_BASE" ]; then
    pass "T15d. reverting both survivors to baseline content reproduces the original token"
else
    fail "T15d. reverted token=$TOKEN_MULTI_REVERTED expected to equal baseline=$TOKEN_MULTI_BASE (both non-null hex)"
fi

# ---------------------------------------------------------------------------
# T16 — Concern C1 (HIGH): prove deletions genuinely contribute NOTHING to
# the hash — not merely that an all-deletion set collapses to null (T2), nor
# that one incidental deletion happens to poison one particular set (T1/T7-
# T9). Build a mixed deletion+survivor repo, capture its token, then stage an
# ADDITIONAL deletion of a THIRD, distinct tests/ path (survivor content
# unchanged) — the token must not change, proving the deletion set's
# identity (which paths, how many) has zero influence on the hash once
# excluded, not just that "some deletions produce nothing".
# EXPECTED: FAIL pre-fix — both tokens are NULL (not valid hex), so the
# is_valid_hex_token guard fails before the equality comparison is even
# meaningful (same expected-FAIL convention as other bug-exercising cases).
# ---------------------------------------------------------------------------
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

TOKEN_ADDDEL_BEFORE=$(call_compute_token "$REPO_ADDDEL")

# Stage a SECOND, additional deletion of a distinct tests/ path. The
# survivor file's content is left untouched.
git -C "$REPO_ADDDEL" rm -q tests/deleted2.sh
TOKEN_ADDDEL_AFTER=$(call_compute_token "$REPO_ADDDEL")

if is_valid_hex_token "$TOKEN_ADDDEL_BEFORE" && is_valid_hex_token "$TOKEN_ADDDEL_AFTER" && [ "$TOKEN_ADDDEL_BEFORE" = "$TOKEN_ADDDEL_AFTER" ]; then
    pass "T16. adding an additional unrelated deletion (survivor unchanged) does not change the token — deletions contribute nothing"
else
    fail "T16. before=$TOKEN_ADDDEL_BEFORE after=$TOKEN_ADDDEL_AFTER (expected equal, non-null hex — deletions must never influence the hash)"
fi

# ---------------------------------------------------------------------------
# T17 — Concern C2 (HIGH): deletion+survivor combination using the SINGULAR
# `test/` prefix. Every prior deletion+survivor case (T1, T7, T8, T9, T15,
# T16) only ever used the plural `tests/` prefix — this closes the
# orthogonality gap between the two accepted prefixes (CPR-ORTH: symmetric
# class members require symmetric treatment).
# EXPECTED: FAIL pre-fix (same root cause as T1 — the deletion poisons the
# whole staged set regardless of which accepted prefix is used).
# ---------------------------------------------------------------------------
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

TOKEN_SINGULAR=$(call_compute_token "$REPO_SINGULAR")
if is_valid_hex_token "$TOKEN_SINGULAR"; then
    pass "T17. deletion+modification combination under the singular test/ prefix yields a non-null hex token"
else
    fail "T17. test/ (singular) deletion+modification: expected valid hex token, got: $TOKEN_SINGULAR (deletion poisoned the whole staged set — issue #1068, test/ prefix)"
fi

# ---------------------------------------------------------------------------
# Concern C8 (LOW): Copy (C) and Type-change (T) git statuses.
# The agreed fix scope (intent.md) is `--diff-filter=AM` or `AMR` (A/M/R
# only) — it does not mention C or T statuses. Verified empirically (see
# review-tests round-3 investigation) that neither can be exercised as a
# genuine test fixture in this suite:
#   - C (copy): `git diff --cached --name-status` never emits a C-status row
#     unless copy detection is explicitly requested (`-C`/`--find-copies`),
#     which computeStagedTestsToken's `git diff --cached --name-only -z`
#     invocation does not pass. A copied file is therefore always reported
#     as a plain A-status add by the code path under test — C-status is
#     structurally unreachable here, not merely untested.
#   - T (type-change, e.g. file<->symlink): requires creating a symlink in
#     the working tree. Confirmed on this Windows/MSYS environment that
#     symlink creation fails (`ln -s` errors "No such type of file or
#     directory") without elevated privilege/Developer Mode, so a T-status
#     fixture cannot be constructed reliably cross-platform. Documented gap
#     — not a fabricated/flaky test.
# Once the AM/AMR filter is implemented, both C and T rows (should they ever
# occur through some other git invocation) fall outside A/M/R and would be
# excluded the same as D — consistent with, not contradicting, this note.
# ---------------------------------------------------------------------------

# ===========================================================================
# Group 6: Rename DIRECTION coverage (T25, T26) — review-tests round 5,
# Concern C3 (MEDIUM).
#
# T5 (regression-unaffected.sh) and T9 (above, this file) both only cover a
# tests/ -> tests/ rename (a file already under tests/ renamed to another
# tests/ path). Neither exercises the direction of the rename relative to the
# tests/ boundary itself:
#   T25 — a rename INTO tests/ (old path OUTSIDE tests/, new path INSIDE).
#   T26 — a rename OUT OF tests/ (old path INSIDE tests/, new path OUTSIDE).
#
# `git diff --cached --name-only` already collapses a staged rename into a
# single row for the NEW path only (no separate old-path row — see T5's
# note), so which side of the tests/ boundary a rename crosses is decided
# entirely by the pre-existing `tests/`/`test/` prefix filter on the NEW
# path — the same filter exercised by the P1-P5 table. Neither case touches
# the D-status exclusion (no deletion is staged in either fixture), so
# BOTH are unaffected by the #1068 bug.
# EXPECTED: PASS both before and after the fix.
# ===========================================================================

# ---------------------------------------------------------------------------
# T25 — rename INTO tests/: old path is OUTSIDE tests/ (repo-root
# `scratch.sh`), new path is INSIDE tests/ (`tests/imported.sh`). Once
# renamed, the new path must be treated exactly like a fresh addition under
# tests/ (contributes to the token) — the file's history predating the
# rename (living outside tests/) must not matter.
# ---------------------------------------------------------------------------
REPO_RENAME_IN="$TMPDIR_BASE/repo-rename-into-tests"
init_repo "$REPO_RENAME_IN"
printf 'rename me into tests, this has enough content to be detected as a rename\nsecond line\nthird line\n' > "$REPO_RENAME_IN/scratch.sh"
git -C "$REPO_RENAME_IN" add scratch.sh
(cd "$REPO_RENAME_IN" && git -c core.hooksPath="" commit -q -m "seed root-level scratch.sh")
git -C "$REPO_RENAME_IN" config diff.renames true
mkdir -p "$REPO_RENAME_IN/tests"
git -C "$REPO_RENAME_IN" mv scratch.sh tests/imported.sh

# Precheck (same pattern as T5pre/T9pre): assert the fixture is genuinely
# detected as R-status by git itself, with the new path landing under
# tests/, before calling computeStagedTestsToken.
RENAME_IN_STATUS_LINE=$(git -C "$REPO_RENAME_IN" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*tests/imported\.sh$' || true)
if [[ -n "$RENAME_IN_STATUS_LINE" ]]; then
    pass "T25pre. rename-into-tests fixture: tests/imported.sh is genuinely detected as R-status by git ($RENAME_IN_STATUS_LINE)"
else
    fail "T25pre. rename-into-tests fixture: tests/imported.sh was NOT detected as R-status by git — fixture invalid (name-status: $(git -C "$REPO_RENAME_IN" diff --cached --name-status))"
fi

TOKEN_RENAME_IN=$(call_compute_token "$REPO_RENAME_IN")
if is_valid_hex_token "$TOKEN_RENAME_IN"; then
    pass "T25. rename INTO tests/ (old path outside tests/, new path inside): yields a non-null hex token, same as a fresh addition"
else
    fail "T25. rename INTO tests/: expected valid hex token, got: $TOKEN_RENAME_IN"
fi

# ---------------------------------------------------------------------------
# T26 — rename OUT OF tests/: old path is INSIDE tests/ (`tests/toBeMoved.sh`),
# new path is OUTSIDE tests/ (repo-root `moved-out.sh`). The renamed-out file
# must NOT appear in the token computation at all — the resulting token must
# equal an independent baseline repo where the survivor file is the ONLY
# thing ever staged under tests/ (the moved file never existed there), same
# comparison technique as T7 (deletion-contributes-nothing).
# ---------------------------------------------------------------------------
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

# Precheck: assert the fixture is genuinely detected as R-status by git, with
# the new path landing OUTSIDE tests/ (not merely assumed).
RENAME_OUT_STATUS_LINE=$(git -C "$REPO_RENAME_OUT" diff --cached --name-status | grep -E '^R[0-9]*[[:space:]].*moved-out\.sh$' || true)
if [[ -n "$RENAME_OUT_STATUS_LINE" ]]; then
    pass "T26pre. rename-out-of-tests fixture: moved-out.sh is genuinely detected as R-status by git ($RENAME_OUT_STATUS_LINE)"
else
    fail "T26pre. rename-out-of-tests fixture: moved-out.sh was NOT detected as R-status by git — fixture invalid (name-status: $(git -C "$REPO_RENAME_OUT" diff --cached --name-status))"
fi

TOKEN_RENAME_OUT=$(call_compute_token "$REPO_RENAME_OUT")

# Independent baseline: a separate repo where tests/survivor.sh is the ONLY
# file ever staged under tests/ (the renamed-out file never existed there at
# all) — content matches REPO_RENAME_OUT's final survivor.sh state exactly.
REPO_RENAME_OUT_BASELINE="$TMPDIR_BASE/repo-rename-out-baseline"
init_repo "$REPO_RENAME_OUT_BASELINE"
mkdir -p "$REPO_RENAME_OUT_BASELINE/tests"
printf 'survivor content v1\n' > "$REPO_RENAME_OUT_BASELINE/tests/survivor.sh"
git -C "$REPO_RENAME_OUT_BASELINE" add tests/survivor.sh
(cd "$REPO_RENAME_OUT_BASELINE" && git -c core.hooksPath="" commit -q -m "seed tests/")
printf 'survivor content v2\n' > "$REPO_RENAME_OUT_BASELINE/tests/survivor.sh"
git -C "$REPO_RENAME_OUT_BASELINE" add tests/survivor.sh
TOKEN_RENAME_OUT_BASELINE=$(call_compute_token "$REPO_RENAME_OUT_BASELINE")

if is_valid_hex_token "$TOKEN_RENAME_OUT" && [ "$TOKEN_RENAME_OUT" = "$TOKEN_RENAME_OUT_BASELINE" ]; then
    pass "T26. rename OUT OF tests/ (old path inside tests/, new path outside): token equals the survivor-only baseline — the renamed-out file contributes nothing"
else
    fail "T26. rename-out-of-tests: token=$TOKEN_RENAME_OUT baseline(survivor-only)=$TOKEN_RENAME_OUT_BASELINE (expected equal, non-null hex — the renamed-out file must not appear in the computation at all)"
fi
# ---------------------------------------------------------------------------
