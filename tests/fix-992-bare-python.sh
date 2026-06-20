#!/bin/bash
# Tests: bin/review-bare-python
# Tags: scope:issue-specific
# Tests for bin/review-bare-python (#992)
# Verifies: SKIPPED/PERFORMED status labels, HARD violation detection,
# uv run python exemption, fixture/probe exclusion list, --base / --all modes,
# .sh-only scope (extensionless bin/ files not flagged).
#
# L3 gap (what this test does NOT catch):
# - Real Windows App Execution Aliases Store popup: only observable on a real Windows host with the stub active
# - Real uv availability: test fixtures mock uv; a missing uv binary would not be caught
# - git diff stderr failure path (source lines 136-139): requires git object corruption to trigger; not reproducible at L2
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: pwsh-required (Windows-host popup not exercisable at L2)
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-bare-python"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (from rules/test/macos-timeout.md)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
    echo "NOTE: $SCRIPT does not exist yet — TDD: tests will fail until script is implemented"
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a fresh isolated temp git repo with a main branch + initial commit
# Empty hooksPath avoids inheriting global git hooks (e.g. ENFORCE_WORKTREE).
EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"
EMPTY_EXCLUDES="$TMPDIR_BASE/empty-excludes"
: > "$EMPTY_EXCLUDES"

make_repo() {
    local repo
    repo=$(mktemp -d -p "$TMPDIR_BASE")
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

SCRIPT_DIR="$(dirname "$0")/fix-992-bare-python"

# shellcheck source=./fix-992-bare-python/normal.sh
. "$SCRIPT_DIR/normal.sh"
# shellcheck source=./fix-992-bare-python/violations.sh
. "$SCRIPT_DIR/violations.sh"
# shellcheck source=./fix-992-bare-python/skipped.sh
. "$SCRIPT_DIR/skipped.sh"
# shellcheck source=./fix-992-bare-python/exclusions.sh
. "$SCRIPT_DIR/exclusions.sh"
# shellcheck source=./fix-992-bare-python/output.sh
. "$SCRIPT_DIR/output.sh"
# shellcheck source=./fix-992-bare-python/regression.sh
. "$SCRIPT_DIR/regression.sh"

if [[ $ERRORS -gt 0 ]]; then echo ""; echo "FAILED: $ERRORS test(s) failed"; exit 1; else echo ""; echo "All tests passed"; fi
