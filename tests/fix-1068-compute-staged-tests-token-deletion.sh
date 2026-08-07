#!/bin/bash
# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, deletion, staged-tests, bugfix, scope:issue-specific
#
# Issue #1068 — computeStagedTestsToken(repoDir) returns null whenever ANY
# staged tests/* path is a deletion, because it collects ALL staged paths via
# `git diff --cached --name-only -z` without filtering by status, then calls
# `git rev-parse :<path>` per path — which exits non-zero for a deleted path —
# and the catch block bails the ENTIRE function to null on that single
# failure. A single unrelated deletion under tests/ therefore blanks out the
# token for every OTHER staged tests/ file too (fail-open masks real evidence).
#
# Planned fix (NOT implemented by this test file): filter the staged path list
# to A/M/R status only (cf. hooks/pre-commit:273 `--diff-filter=AM` precedent)
# before computing per-path blob OIDs, so a staged deletion (or an unmerged
# conflict, status U) no longer poisons the token for the rest of the staged
# tests/ set.
#
# Pre-implementation expectation: T1 (mixed deletion+modification), T3
# (determinism on the mixed case), T4 (change-detection on the mixed case),
# T7 (deletion-contributes-nothing comparison), T8 (deletion+addition), T9
# (deletion+rename), T15a-d (deletion + 2 surviving tests/ paths), T16
# (additional-deletion-doesn't-change-token), T17 (test/ singular prefix
# deletion+survivor combination), T21 (oracle — independently-computed
# expected token) and T24 (space-named DELETED path) FAIL until the fix
# lands, because the affected token is NULL instead of a real hex value. T2
# (all-deletions), T5/T5pre (rename-only), T6 (addition-only regression), T9pre
# (D+R rename-status precheck), T11/T11b (error paths: nonexistent repoDir /
# non-git directory), T12-T14 (empty file / whitespace filename /
# shell-metachar filename, each staged alongside the deletion in the same
# staging set), T18 (empty-string repoDir), T19 (omitted/undefined repoDir —
# documented latent gap, unrelated to #1068), T22 (poisoned-GIT_DIR
# fault-injection), T23 (explicit repoDir=null — same documented latent gap
# as T19), T25/T25pre/T26/T26pre (rename direction into/out of tests/) and
# the P1-P5 path-prefix table are unaffected by the bug and PASS both before
# and after the fix.
#
# Scope note: the agreed fix (intent.md) excludes D-status (deleted) paths
# only. No case in this suite asserts behavior for U-status (unmerged/
# conflict) paths — that is out of scope for issue #1068. Copy (C) and
# type-change (T) statuses are addressed in a documentation-only note in
# status-combinations.sh (Concern C8) — see that file for why neither is
# constructible as a genuine test fixture here.
#
# review-tests follow-up (round 4, 5 concerns, resolved in this revision):
#   C1 HIGH   — T21 (core-deletion-poisoning.sh): oracle test —
#               independently computes the expected token from first
#               principles (expected_token_for helper, below) and asserts
#               computeStagedTestsToken's actual output equals it
#               byte-for-byte, closing the gap where every other case only
#               checked relative properties (non-null/stable/changes).
#   C2 HIGH   — T19 (error-and-edge-paths.sh) rewritten to explicitly control
#               the CWD (dedicated throwaway repo, `cd` inside the `$(...)`
#               subshell) instead of relying on the ambient CWD's staged
#               tests/ set at test-run time.
#   C3 MEDIUM — T22 (error-and-edge-paths.sh): deterministic git-subprocess
#               fault injection via a poisoned GIT_DIR env var — found to be
#               reliably reproducible on this platform (unlike the
#               permission/EACCES mechanism, which remains a documented gap
#               — see the merged C6/C3 note in error-and-edge-paths.sh).
#   C4 MEDIUM — T23 (error-and-edge-paths.sh): explicit repoDir=null,
#               verified empirically distinct from "" (T18) and equivalent
#               to omitted/undefined (T19).
#   C5 LOW    — T24 (error-and-edge-paths.sh): space-named DELETED path
#               (mirrors T13's space-named SURVIVOR path).
#
# review-tests follow-up (round 5, 4 concerns, C3 resolved in this revision;
# C1/C2 accepted as-is via WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED — both
# conflict with the approved intent.md scope; C4 left as a documented gap,
# already investigated in round 4/T13's C4 note):
#   C3 MEDIUM — T25/T26 (status-combinations.sh): rename DIRECTION coverage.
#               T5/T9 only cover a tests/ -> tests/ rename; T25 adds a rename
#               INTO tests/ (old path outside, new path inside — must
#               contribute like a fresh addition) and T26 adds a rename OUT
#               OF tests/ (old path inside, new path outside — must
#               contribute nothing, verified against a survivor-only
#               baseline).
#
# review-tests follow-up (round 3, 8 concerns, resolved in that revision):
#   C1 HIGH   — T16 (status-combinations.sh): an additional, unrelated
#               deletion staged alongside an unchanged mixed deletion+
#               survivor set must not change the token (proves deletions
#               contribute nothing, not just "some deletions produce
#               nothing").
#   C2 HIGH   — T17 (status-combinations.sh): deletion+survivor combination
#               using the singular test/ prefix (prior cases only used
#               tests/), closing the CPR-ORTH orthogonality gap.
#   C3 MEDIUM — T15d now also asserts is_valid_hex_token, so it can no
#               longer trivially pass on a NULL==NULL coincidence pre-fix.
#   C4 MEDIUM — T13 documented: an embedded-newline filename (the ideal -z
#               differentiator) is confirmed empirically unconstructible on
#               any platform (both raw fs writes and git's own path
#               validation reject control characters in filenames); the
#               space-named fixture remains the strongest reproducible
#               proxy.
#   C5 MEDIUM — T18 (empty-string repoDir: returns null, safe) and T19
#               (omitted/undefined repoDir: silently defaults to
#               process.cwd() — documented latent gap, out of #1068 scope)
#               added to error-and-edge-paths.sh.
#   C6 MEDIUM — permission-denied git-subprocess case documented as a
#               non-reproducible cross-platform gap in
#               error-and-edge-paths.sh (Windows ACL/chmod unreliability) —
#               not fabricated as a flaky test.
#   C7 LOW    — T5 (regression-unaffected.sh) now forces
#               `git config diff.renames true` explicitly, matching T9,
#               instead of relying on ambient git config.
#   C8 LOW    — status-combinations.sh documents why Copy (C) and
#               Type-change (T) git statuses are out of the agreed AM/AMR
#               fix scope and cannot be fixtured as genuine test cases here.
#
# review-tests follow-up (round 2, concerns resolved in that revision):
#   C1  HIGH   — T12/T13 (empty file / space-named file) now stage the
#                survivor as a brand-new A-status addition in the SAME
#                staging set as the deletion (not committed beforehand and
#                left untouched), so it genuinely reaches `git rev-parse
#                :<path>` at call time.
#   C2  HIGH   — T14 (shell-metachar filename) likewise stages the survivor
#                fresh alongside the deletion, so the no-injection assertion
#                is no longer vacuous.
#   C3  HIGH   — removed the former T10 (U-status exclusion) assertion, which
#                exceeded the agreed D-status-only fix scope.
#   C4  HIGH   — T15a-d stage a deletion alongside 2 surviving tests/ paths
#                (M + A) and assert the token depends on BOTH survivors'
#                content, not just the first one an implementation hashes.
#   C5  MEDIUM — NUL-delimited (-z) parsing is now genuinely exercised via
#                the C1/C2 fixes (space- and shell-metacharacter-named
#                survivors staged live alongside the deletion).
#   C6  MEDIUM — T11b adds coverage for a non-git directory (exists on disk,
#                not a git repo at all) distinct from T11's ENOENT case.
#   C7  LOW    — T5pre and T9pre assert the rename fixtures are genuinely
#                detected as R-status by `git diff --cached --name-status`
#                before computeStagedTestsToken is called.
#   C8  HIGH   — all 5 sourced body files now carry `# Tests:` / `# Tags:`
#                frontmatter in their first 10 lines (bin/check-test-frontmatter.sh
#                --staged matches sibling-folder .sh paths too).
#
# Prior revision's follow-up (7 concerns, retained):
#   1. HIGH   — T7 proves a staged deletion contributes nothing to the hash of
#               surviving paths (independent no-deletion-at-all fixture).
#   2. HIGH   — T8 (D+A) and T9 (D+R, rename detection forced via explicit
#               `git config diff.renames true` rather than relying on ambient
#               git config) add the missing status-combination coverage.
#   3. HIGH   — P1-P5 (table-driven) cover the `test/` singular prefix and
#               no-match lookalike paths (`src/example.js`,
#               `tests-prefix/example.sh`).
#   4. MEDIUM — T11 (nonexistent repoDir) covers the ENOENT error path.
#   5. MEDIUM — T12 (empty staged file) and T13 (filename with spaces) mixed
#               with a deletion verify NUL-delimited (`-z`) parsing.
#   6. MEDIUM — T14 stages a shell-metacharacter filename alongside a deletion
#               and asserts no injection side effect occurs.
#   7. MEDIUM — the P1-P5 path-prefix cases use the table-driven
#               `while IFS='|' read` pattern per skills/_shared/test-design.md
#               and tests/feature-833-review-tests-sentinel-ssot.sh precedent.
#
# TL3 gap (what this test does NOT catch):
# - Whether workflow-gate.js's caller correctly treats a non-null mixed-case
#   token as valid evidence end-to-end (this file only exercises
#   computeStagedTestsToken() directly via `require()`, not the gate's full
#   sentinel-comparison flow).
# - Real hook registration (PreToolUse wiring) is not exercised here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.
#
# File-split note (rules/coding/file-split.md Pattern A): this dispatcher
# holds shared setup/helpers only; test bodies live in the sibling
# fix-1068-compute-staged-tests-token-deletion/ folder (grouped by concern).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_TESTS_EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"
SCRIPT_DIR="$(dirname "$0")/fix-1068-compute-staged-tests-token-deletion"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Windows-compatible tmpdir
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/fix1068.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Shared helpers (used by every sourced test-body group below)
# ---------------------------------------------------------------------------

# init_repo <dir> — bare git repo with an initial commit (bypasses global
# enforce-worktree hook via core.hooksPath="").
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (
        cd "$repo" || exit 1
        git init -q
        git config user.email test@example.com
        git config user.name Test
        echo "initial" > README.md
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
    )
}

# call_compute_token <repoDir> — invoke computeStagedTestsToken(repoDir) via node.
call_compute_token() {
    local repo="$1"
    run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            if (typeof m.computeStagedTestsToken !== 'function') {
                process.stdout.write('NOT_IMPLEMENTED');
                process.exit(0);
            }
            const out = m.computeStagedTestsToken(process.argv[2]);
            process.stdout.write(out == null ? 'NULL' : String(out));
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo" 2>/dev/null || echo "ERROR"
}

is_valid_hex_token() {
    [[ "$1" =~ ^[0-9a-f]{16}$ ]]
}

# sha256_hex_prefix16 <string> — cross-platform sha256 hex digest of <string>,
# first 16 hex chars. Mirrors computeStagedTestsToken's
# crypto.createHash("sha256").update(content).digest("hex").slice(0, 16).
# Precedent: tests/feature-issue-283-label-bootstrap.sh sha256_of() (file-based
# variant); this is the stdin/string variant since the oracle hashes an
# in-memory joined string, not a file.
sha256_hex_prefix16() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}' | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}' | cut -c1-16
    else
        printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-16
    fi
}

# expected_token_for <repoDir> <survivorPath> [<survivorPath> ...] — Concern
# C1 oracle: independently compute the token computeStagedTestsToken is
# expected to return, from first principles, WITHOUT calling
# computeStagedTestsToken itself: blob OID of each given surviving path via
# `git rev-parse :<path>`, rows "<path>\t<oid>" sorted byte-wise (LC_ALL=C,
# matching JS's default Array.prototype.sort() UTF-16-code-unit order for
# plain-ASCII paths), joined by "\n" (no trailing newline — matches
# rows.join("\n")), then sha256_hex_prefix16. Caller passes only the paths
# expected to SURVIVE the D-status exclusion (deleted paths are never passed
# in) — this oracle models the post-fix behavior, which is intentional: it is
# meant to prove the actual output equals the correct answer once the fix
# lands, not to reproduce the pre-fix bug.
expected_token_for() {
    local repo="$1"; shift
    local rows=()
    local p oid
    for p in "$@"; do
        oid=$(git -C "$repo" rev-parse ":$p")
        rows+=("$(printf '%s\t%s' "$p" "$oid")")
    done
    local sorted
    sorted=$(printf '%s\n' "${rows[@]}" | LC_ALL=C sort)
    sha256_hex_prefix16 "$sorted"
}

# ---------------------------------------------------------------------------
# Test-body groups
# ---------------------------------------------------------------------------

# shellcheck source=./fix-1068-compute-staged-tests-token-deletion/core-deletion-poisoning.sh
. "$SCRIPT_DIR/core-deletion-poisoning.sh"
# shellcheck source=./fix-1068-compute-staged-tests-token-deletion/regression-unaffected.sh
. "$SCRIPT_DIR/regression-unaffected.sh"
# shellcheck source=./fix-1068-compute-staged-tests-token-deletion/status-combinations.sh
. "$SCRIPT_DIR/status-combinations.sh"
# shellcheck source=./fix-1068-compute-staged-tests-token-deletion/error-and-edge-paths.sh
. "$SCRIPT_DIR/error-and-edge-paths.sh"
# shellcheck source=./fix-1068-compute-staged-tests-token-deletion/path-prefix-table.sh
. "$SCRIPT_DIR/path-prefix-table.sh"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    exit 1
fi
