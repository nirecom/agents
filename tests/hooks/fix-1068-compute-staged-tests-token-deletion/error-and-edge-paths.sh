# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, deletion, staged-tests, bugfix, scope:issue-specific
# ===========================================================================
# Group 4: Error paths and edge-case input shapes (T11, T11b, T12, T13,
# T14/T14b)
# Concern 4 (error paths), Concern 5 (empty file / whitespace filename),
# Concern 6 (shell-metacharacter filename / injection guard).
# ===========================================================================

# ---------------------------------------------------------------------------
# T11 — Concern 4 (MEDIUM): nonexistent repoDir argument (not merely a
# non-git directory — the path itself does not exist on disk). Distinct
# failure mode: execFileSync's cwd option throws ENOENT synchronously.
# EXPECTED: PASS both before and after the fix (fail-open unaffected by the
# deletion-poisoning bug).
# ---------------------------------------------------------------------------
REPO_NONEXISTENT="$TMPDIR_BASE/this-path-does-not-exist-at-all"
TOKEN_NONEXISTENT=$(call_compute_token "$REPO_NONEXISTENT")
if [ "$TOKEN_NONEXISTENT" = "NULL" ]; then
    pass "T11. nonexistent repoDir argument: returns null (fail-open)"
else
    fail "T11. nonexistent repoDir argument: expected NULL, got: $TOKEN_NONEXISTENT"
fi

# ---------------------------------------------------------------------------
# T11b — Concern 6 (MEDIUM): non-git directory (the path exists on disk, but
# is not (inside) a git repository — distinct from T11's ENOENT: here `git
# diff --cached` itself fails with "not a git repository").
# EXPECTED: PASS both before and after the fix (fail-open unaffected by the
# deletion-poisoning bug).
# ---------------------------------------------------------------------------
REPO_NOTGIT="$TMPDIR_BASE/repo-not-a-git-repo"
mkdir -p "$REPO_NOTGIT"
printf 'just a plain directory, not a git repo\n' > "$REPO_NOTGIT/placeholder.txt"
TOKEN_NOTGIT=$(call_compute_token "$REPO_NOTGIT")
if [ "$TOKEN_NOTGIT" = "NULL" ]; then
    pass "T11b. non-git directory (exists on disk, no .git): returns null (fail-open)"
else
    fail "T11b. non-git directory: expected NULL, got: $TOKEN_NOTGIT"
fi

# ---------------------------------------------------------------------------
# T12 — Concern 5 (MEDIUM): empty staged file mixed with an unrelated
# deletion. Verifies the well-known empty-blob OID round-trips correctly
# through the NUL-delimited (-z) parsing once the deletion is excluded.
# The empty file is staged as a brand-new addition (A-status) in the SAME
# staging set as the deletion (not merely committed beforehand and left
# untouched) so it genuinely goes through `git rev-parse :<path>` at call
# time — a fix that only ever sees the deletion row would not be exercised
# otherwise.
# EXPECTED: FAIL pre-fix (same root cause as T1).
# ---------------------------------------------------------------------------
REPO_EMPTY="$TMPDIR_BASE/repo-empty"
init_repo "$REPO_EMPTY"
mkdir -p "$REPO_EMPTY/tests"
printf 'delete me\n' > "$REPO_EMPTY/tests/deleted.sh"
git -C "$REPO_EMPTY" add tests/deleted.sh
(cd "$REPO_EMPTY" && git -c core.hooksPath="" commit -q -m "seed tests/")
git -C "$REPO_EMPTY" rm -q tests/deleted.sh
# `git rm` removes the now-empty tests/ directory on this platform (Windows/MSYS
# git) — re-create it before staging the surviving empty file.
mkdir -p "$REPO_EMPTY/tests"
: > "$REPO_EMPTY/tests/empty.sh"
git -C "$REPO_EMPTY" add tests/empty.sh

TOKEN_EMPTY=$(call_compute_token "$REPO_EMPTY")
if is_valid_hex_token "$TOKEN_EMPTY"; then
    pass "T12. empty staged file survives alongside an unrelated deletion, yields a non-null hex token"
else
    fail "T12. empty staged file + unrelated deletion: expected valid hex token, got: $TOKEN_EMPTY"
fi

# ---------------------------------------------------------------------------
# T13 — Concern 5 (MEDIUM) / Concern C4 (MEDIUM): filename containing spaces,
# mixed with a deletion. Verifies -z NUL-delimited parsing handles
# space-containing filenames correctly. The space-named file is staged as a
# brand-new addition in the SAME staging set as the deletion (not committed
# beforehand) so it genuinely reaches `git rev-parse :<path>`.
#
# C4 note (why this is not an embedded-NEWLINE filename): a genuine
# differentiator between NUL-delimited (-z) and naive newline-based parsing
# requires a filename that itself contains a literal newline byte — a plain
# space does not break newline-splitting. This was attempted and confirmed
# empirically NOT constructible on this platform:
#   - `fs.writeFileSync()` with a raw `\n`/`\t` byte in the filename fails
#     with ENOENT (Windows/Win32 file API rejects control characters in
#     path components — this is an OS-level restriction, not a shell or git
#     quoting artifact).
#   - `git update-index --add --cacheinfo` (pure plumbing, bypasses the
#     working tree and shell entirely) independently rejects the same path
#     with "error: Invalid path" — modern git validates and refuses control
#     characters in tracked paths regardless of platform.
# Since no reachable technique (working-tree write, or direct index
# manipulation) can produce a control-character filename, the space-named
# fixture below remains the strongest reproducible proxy for -z parsing in
# this suite. Documented gap — not a fabricated/flaky test.
# EXPECTED: FAIL pre-fix (same root cause as T1).
# ---------------------------------------------------------------------------
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

TOKEN_SPACE=$(call_compute_token "$REPO_SPACE")
if is_valid_hex_token "$TOKEN_SPACE"; then
    pass "T13. space-containing filename survives alongside an unrelated deletion, yields a non-null hex token"
else
    fail "T13. space-containing filename + unrelated deletion: expected valid hex token, got: $TOKEN_SPACE"
fi

# ---------------------------------------------------------------------------
# T14 — Concern 6 (MEDIUM): shell-metacharacter filename staged alongside a
# deletion. computeStagedTestsToken uses execFileSync with an argv array (no
# shell interpolation), so a filename literally containing `$(touch ...)`
# must never execute as a subshell. Assert the marker file is never created
# anywhere under the test tmpdir. The metachar-named file is staged as a
# brand-new addition in the SAME staging set as the deletion (not committed
# beforehand) so it genuinely reaches the `git rev-parse :<path>` code path
# under test — otherwise the no-injection assertion would trivially pass even
# against a badly broken implementation, since the path is never touched.
# EXPECTED: FAIL pre-fix on the token check (same root cause as T1); the
# no-injection assertion must PASS regardless (security invariant, not tied
# to the deletion-poisoning bug).
# ---------------------------------------------------------------------------
REPO_META="$TMPDIR_BASE/repo-meta"
# Marker filename deliberately has NO embedded path separators — a marker
# value containing "/" would make the crafted filename itself a multi-level
# path (parent dirs like "$(touch " don't exist), which fails for a mundane
# reason unrelated to the injection question this case is testing.
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

TOKEN_META=$(call_compute_token "$REPO_META")
if is_valid_hex_token "$TOKEN_META"; then
    pass "T14. shell-metacharacter filename survives alongside an unrelated deletion, yields a non-null hex token"
else
    fail "T14. shell-metacharacter filename + unrelated deletion: expected valid hex token, got: $TOKEN_META"
fi

if [ ! -e "$TMPDIR_BASE/$MARKER_NAME" ] && [ ! -e "$REPO_META/$MARKER_NAME" ] && [ ! -e "$AGENTS_DIR/$MARKER_NAME" ]; then
    pass "T14b. shell-metacharacter filename does not trigger command injection (marker file never created)"
else
    fail "T14b. shell-metacharacter filename triggered command injection — marker file was created (checked \$TMPDIR_BASE, repo root, \$AGENTS_DIR)"
fi

# ---------------------------------------------------------------------------
# T18 — Concern C5 (MEDIUM): empty-string repoDir argument. Verifies this
# does NOT silently fall back to process.cwd() and fingerprint the wrong
# repo. Verified empirically (direct `node -e` reproduction against this
# exact source file) that execFileSync's `cwd: ""` option throws
# synchronously — Node treats an empty-string cwd as invalid — so the catch
# block returns null exactly like the ENOENT/non-git-directory cases (T11,
# T11b). Safe: an empty repoDir cannot silently succeed against the wrong
# directory.
# EXPECTED: PASS both before and after the fix (fail-open unaffected by the
# deletion-poisoning bug).
# ---------------------------------------------------------------------------
TOKEN_EMPTY_REPODIR=$(call_compute_token "")
if [ "$TOKEN_EMPTY_REPODIR" = "NULL" ]; then
    pass "T18. empty-string repoDir argument: returns null (does not silently default to process.cwd())"
else
    fail "T18. empty-string repoDir argument: expected NULL, got: $TOKEN_EMPTY_REPODIR"
fi

# ---------------------------------------------------------------------------
# T19 — Concern C5 (MEDIUM): omitted/undefined repoDir argument. Verified
# empirically (direct `node -e` reproduction against this exact source
# file) that, UNLIKE the empty-string case, this DOES silently default to
# process.cwd(): Node's child_process `cwd: undefined` option falls back to
# the current process's working directory rather than throwing, so
# computeStagedTestsToken(undefined) / computeStagedTestsToken() (no arg at
# all) both return a real, non-null hex token computed against whatever
# directory the caller happened to be running in — not an error, and not
# the repo the caller probably intended. This is a genuine latent input-
# validation gap, out of scope for issue #1068's D-status fix and NOT
# remediated here (this task edits tests only). This case documents the
# ACTUAL current behavior — a future source fix that makes this throw/
# return null instead would need this assertion updated too; it is
# deliberately not asserting a safer behavior that does not exist (that
# would be a false-green in the opposite direction).
#
# Concern C2 (HIGH, review-tests round 4): this case used to rely on the
# ambient CWD at test-run time already having a staged tests/ set of its
# own — fragile, since it would behave differently in a clean checkout, a
# different invocation directory, or CI. Fixed to explicitly control the
# CWD for the duration of the assertion: build a dedicated throwaway repo
# with a KNOWN staged tests/ file, `cd` into it inside the `$(...)` command
# substitution (which already runs in a subshell, so the original CWD of
# this script is untouched — no explicit restore needed), then call
# computeStagedTestsToken() with no repoDir argument at all. The expected
# token is additionally cross-checked against expected_token_for (the C1
# oracle helper) so this case proves not merely "returns a hex token" but
# "returns the CORRECT token for the CWD-resident repo".
# EXPECTED: PASS both before and after the #1068 D-status fix (this
# behavior is unrelated to deletion handling — tracked as a separate
# follow-up concern, not fixed here).
# ---------------------------------------------------------------------------
REPO_UNDEFINED_CWD="$TMPDIR_BASE/repo-undefined-cwd"
init_repo "$REPO_UNDEFINED_CWD"
mkdir -p "$REPO_UNDEFINED_CWD/tests"
printf 'undefined-repoDir cwd fixture\n' > "$REPO_UNDEFINED_CWD/tests/fixture.sh"
git -C "$REPO_UNDEFINED_CWD" add tests/fixture.sh

EXPECTED_UNDEFINED_CWD=$(expected_token_for "$REPO_UNDEFINED_CWD" tests/fixture.sh)
UNDEFINED_REPODIR_RESULT=$(
    cd "$REPO_UNDEFINED_CWD" && run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            const out = m.computeStagedTestsToken();
            process.stdout.write(out == null ? 'NULL' : String(out));
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" 2>/dev/null || echo "ERROR"
)
if [ "$UNDEFINED_REPODIR_RESULT" = "$EXPECTED_UNDEFINED_CWD" ]; then
    pass "T19. omitted/undefined repoDir argument: silently defaults to process.cwd() and returns the correct hex token for the CWD-resident repo (documented latent gap, not fixed here — see comment above)"
else
    fail "T19. omitted/undefined repoDir argument: expected=$EXPECTED_UNDEFINED_CWD (independently computed for the deliberately-CWD'd repo) got=$UNDEFINED_REPODIR_RESULT — behavior has changed, update this assertion"
fi

# ---------------------------------------------------------------------------
# T22 — Concern C3 (MEDIUM): deterministic git-subprocess fault injection.
# Review-tests round 4 asked whether a reliable, reproducible fault-injection
# case (distinct from T11's ENOENT and T11b's non-git-directory) is possible
# on this Windows/MSYS environment before accepting a documented gap.
# Verified empirically: pointing the `GIT_DIR` environment variable at a
# bogus, nonexistent path (which computeStagedTestsToken's execFileSync calls
# inherit, since it does not pass an explicit `env` override) makes git's
# OWN internal path resolution fail deterministically — `fatal: Invalid path
# '<cwd>': No such file or directory` — inside a perfectly valid, existing
# git repository with a real staged tests/ set. This is a genuine
# git-subprocess failure (git itself errors out on a bad -C/GIT_DIR
# combination), not a filesystem-permission mechanism, so it sidesteps the
# Windows ACL unreliability that makes chmod-based fault injection flaky
# (see the note below). Reproduced consistently across repeated runs on this
# platform.
# EXPECTED: PASS both before and after the #1068 D-status fix (fail-open on
# git-subprocess failure is pre-existing, unrelated-to-deletion behavior).
# ---------------------------------------------------------------------------
REPO_GITDIR_FAULT="$TMPDIR_BASE/repo-gitdir-fault"
init_repo "$REPO_GITDIR_FAULT"
mkdir -p "$REPO_GITDIR_FAULT/tests"
printf 'staged under a repo whose GIT_DIR is about to be poisoned\n' > "$REPO_GITDIR_FAULT/tests/fixture.sh"
git -C "$REPO_GITDIR_FAULT" add tests/fixture.sh

TOKEN_GITDIR_FAULT=$(GIT_DIR="$REPO_GITDIR_FAULT/.git-bogus-nonexistent" call_compute_token "$REPO_GITDIR_FAULT")
if [ "$TOKEN_GITDIR_FAULT" = "NULL" ]; then
    pass "T22. git subprocess fault injection (bogus GIT_DIR env var): returns null (fail-open) instead of crashing or hanging"
else
    fail "T22. git subprocess fault injection: expected NULL, got: $TOKEN_GITDIR_FAULT"
fi

# ---------------------------------------------------------------------------
# T23 — Concern C4 (MEDIUM): explicit `repoDir = null` (not omitted/
# undefined like T19, not empty-string like T18). Verified empirically
# (direct `node -e` reproduction against this exact source file) that Node's
# child_process `cwd: null` option behaves like `cwd: undefined` — it falls
# back to process.cwd() rather than throwing — so
# computeStagedTestsToken(null) does NOT behave like the empty-string case
# (T18, which throws inside execFileSync and is caught, returning null); it
# behaves like the omitted/undefined case (T19): a real, non-null hex token
# computed against whatever directory the caller happened to be running in.
# This is the same documented latent gap as T19, just for a third distinct
# input shape (null vs undefined vs ""), confirming null and undefined are
# NOT distinguished by the current implementation even though JS treats them
# as distinct values. Same CWD-control technique as the fixed T19 (dedicated
# repo, `cd` inside the `$(...)` subshell) so this case is not fragile to
# ambient CWD state either.
# EXPECTED: PASS both before and after the #1068 D-status fix (unrelated to
# deletion handling).
# ---------------------------------------------------------------------------
REPO_NULL_CWD="$TMPDIR_BASE/repo-null-cwd"
init_repo "$REPO_NULL_CWD"
mkdir -p "$REPO_NULL_CWD/tests"
printf 'null-repoDir cwd fixture\n' > "$REPO_NULL_CWD/tests/fixture.sh"
git -C "$REPO_NULL_CWD" add tests/fixture.sh

EXPECTED_NULL_CWD=$(expected_token_for "$REPO_NULL_CWD" tests/fixture.sh)
NULL_REPODIR_RESULT=$(
    cd "$REPO_NULL_CWD" && run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            const out = m.computeStagedTestsToken(null);
            process.stdout.write(out == null ? 'NULL' : String(out));
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" 2>/dev/null || echo "ERROR"
)
if [ "$NULL_REPODIR_RESULT" = "$EXPECTED_NULL_CWD" ]; then
    pass "T23. explicit repoDir=null: silently defaults to process.cwd() and returns the correct hex token, same as omitted/undefined (T19) — documented latent gap, not fixed here"
else
    fail "T23. explicit repoDir=null: expected=$EXPECTED_NULL_CWD (independently computed for the deliberately-CWD'd repo) got=$NULL_REPODIR_RESULT — behavior has changed, update this assertion"
fi

# ---------------------------------------------------------------------------
# T24 — Concern C5 (LOW): deletion entry whose OWN filename contains a
# space (distinct from T13/T14, where the special-character filename
# belongs to the SURVIVING path — here it belongs to the DELETED path).
# Verifies the D-status exclusion (once the fix lands) correctly identifies
# and drops a deleted path even when NUL-delimited parsing has to split it
# out from a space-containing name, and that nothing crashes/hangs in the
# meantime. A plain M-status survivor is staged alongside so the case still
# has a non-trivial expected post-fix token (not just "returns null").
# EXPECTED: FAIL pre-fix (same root cause as T1 — the deletion poisons the
# whole staged set regardless of the deleted path's own filename shape).
# ---------------------------------------------------------------------------
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

TOKEN_DEL_SPACE=$(call_compute_token "$REPO_DEL_SPACE")
if is_valid_hex_token "$TOKEN_DEL_SPACE"; then
    pass "T24. space-named DELETED path alongside a surviving modification: yields a non-null hex token, no crash/hang"
else
    fail "T24. space-named deleted path: expected valid hex token, got: $TOKEN_DEL_SPACE (deletion poisoned the whole staged set — issue #1068)"
fi

# ---------------------------------------------------------------------------
# Concern C6 (MEDIUM, review-tests round 3) / Concern C3 (MEDIUM, round 4):
# permission-denied / access-error for the underlying git subprocess call
# (e.g. a repo directory whose permissions block git from reading .git
# internals). NOT added as a test case in that specific EACCES/permission
# form: reliably forcing a permission-denied error from `git diff --cached`
# is not portable across this suite's target platforms. On Windows/MSYS (the
# primary dev environment for this repo — see the Windows-specific tmpdir
# handling at the top of the dispatcher file), `chmod`-based permission
# revocation on files/directories is unreliable: Windows ACLs do not map
# cleanly onto POSIX mode bits, and the MSYS git process frequently runs
# with owner privileges that bypass the intended restriction, producing a
# flaky pass/fail split that depends on the host's ACL defaults rather than
# a deterministic repro of the error path. Fabricating a test that only
# incidentally works on one platform would violate the "no fabricated flaky
# test" rule.
#
# Round 4 re-examined this gap and found a DIFFERENT, genuinely reliable
# git-subprocess fault-injection technique that does not depend on
# filesystem permissions at all: T22 above poisons the `GIT_DIR` environment
# variable so git's own path resolution fails deterministically. That covers
# the broader "git subprocess fails" class this note originally worried
# about; only the specific permission/EACCES trigger mechanism remains an
# accepted, documented gap. T11 (ENOENT), T11b (non-git directory), and T22
# (poisoned GIT_DIR) together cover the error paths that ARE reliably
# reproducible cross-platform in this suite.
# ---------------------------------------------------------------------------
