#!/bin/bash
# Tests: hooks/workflow-gate/review-tests-evidence.js
# Tags: workflow, review-tests, token, fingerprint, deletion, staged-tests, bugfix, scope:issue-specific
#
# #1068 — computeReviewScopeFingerprint(repoDir) must not return {ok:false} when a
# staged deletion exists alongside surviving in-scope paths: filter D-status before OID
# lookup so a single deletion no longer poisons the whole result.
# Renamed from fix-1068-compute-staged-tests-token-deletion after the fingerprint refactor.
# Part files live in fix-1068-review-scope-fingerprint-deletion/.
# TL3 gap: hook registration checked at WORKFLOW_USER_VERIFIED preflight.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REVIEW_TESTS_EVIDENCE="$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js"
SCRIPT_DIR="$(dirname "$0")/fix-1068-review-scope-fingerprint-deletion"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

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
        git config core.hooksPath /dev/null
        git config user.email test@example.com
        git config user.name Test
        echo "initial" > README.md
        git -c core.hooksPath="" add README.md
        git -c core.hooksPath="" commit -q -m initial
    )
}

# call_compute_fingerprint <repoDir> — invoke computeReviewScopeFingerprint(repoDir) via node.
# Returns the fingerprint hex string, "EMPTY" (ok:true, no in-scope files),
# "ERR" ({ok:false}), or "NOT_IMPLEMENTED".
call_compute_fingerprint() {
    local repo="$1"
    run_with_timeout node -e "
        try {
            const m = require(process.argv[1]);
            if (typeof m.computeReviewScopeFingerprint !== 'function') {
                process.stdout.write('NOT_IMPLEMENTED');
                process.exit(0);
            }
            const result = m.computeReviewScopeFingerprint(process.argv[2]);
            if (!result.ok) {
                process.stdout.write('ERR');
            } else if (!result.fingerprint) {
                process.stdout.write('EMPTY');
            } else {
                process.stdout.write(String(result.fingerprint));
            }
        } catch (e) {
            process.stdout.write('ERROR: ' + e.message);
        }
    " -- "$REVIEW_TESTS_EVIDENCE" "$repo" 2>/dev/null || echo "ERROR"
}

# Legacy alias used in sub-files that have not yet been updated.
call_compute_token() { call_compute_fingerprint "$@"; }

is_valid_hex_token() {
    [[ "$1" =~ ^[0-9a-f]{16}$ ]]
}

# sha256_hex_prefix16 <string> — cross-platform sha256 of <string>, first 16 hex chars.
# Mirrors fingerprintOfManifest's crypto.createHash("sha256").update(content).digest("hex").slice(0,16).
sha256_hex_prefix16() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}' | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}' | cut -c1-16
    else
        printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-16
    fi
}

# expected_fingerprint_for <repoDir> <survivorPath> [<survivorPath> ...] — oracle:
# independently compute the fingerprint computeReviewScopeFingerprint is expected
# to return (post-fix), from first principles, WITHOUT calling the function itself.
# blob OID of each surviving path via `git rev-parse :<path>`, rows "<path>\t<oid>"
# sorted byte-wise (LC_ALL=C), joined by "\n", then sha256_hex_prefix16.
# Caller passes only paths expected to SURVIVE D-status exclusion.
expected_fingerprint_for() {
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

# Legacy alias used in sub-files that have not yet been updated.
expected_token_for() { expected_fingerprint_for "$@"; }

# ---------------------------------------------------------------------------
# Test-body groups
# ---------------------------------------------------------------------------

# shellcheck source=./fix-1068-review-scope-fingerprint-deletion/core-deletion-poisoning.sh
. "$SCRIPT_DIR/core-deletion-poisoning.sh"
# shellcheck source=./fix-1068-review-scope-fingerprint-deletion/regression-unaffected.sh
. "$SCRIPT_DIR/regression-unaffected.sh"
# shellcheck source=./fix-1068-review-scope-fingerprint-deletion/status-combinations.sh
. "$SCRIPT_DIR/status-combinations.sh"
# shellcheck source=./fix-1068-review-scope-fingerprint-deletion/error-and-edge-paths.sh
. "$SCRIPT_DIR/error-and-edge-paths.sh"
# shellcheck source=./fix-1068-review-scope-fingerprint-deletion/path-prefix-table.sh
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
