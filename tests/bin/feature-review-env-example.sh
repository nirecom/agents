#!/bin/bash
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, scope:common
# Verifies: SKIPPED/PERFORMED labels, HARD/WARN classification, _archived/ and
# node_modules/ exclusion, --base and --all flags, merge-base failure handling,
# the legacy-prefix and wrapped-continuation HARD checks, and that the real
# .env.example stays compliant with rules/docs/env-example.md.
# L3 gap: the --all scan runs the checker as a subprocess, never through the
# real pre-commit hook — that needs a live hook-registration test.
# Dispatcher: fixtures + helpers, then sources the case files in
# feature-review-env-example/.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-env-example"
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

TMPDIR_BASE=$(mktemp -d)
[[ -n "$TMPDIR_BASE" && -d "$TMPDIR_BASE" ]] || { echo "FAIL: mktemp -d gave no directory" >&2; exit 2; }
readonly TMPDIR_BASE
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# A fixture git call must never reach the real checkout: an inherited GIT_DIR (e.g. from a
# git hook) redirects `git -C <fixture>`, and an empty repo path makes `git -C ""` act on the
# CWD. So drop the GIT_* redirects, leave the checkout, and stop discovery above the temp root.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CEILING_DIRECTORIES
GIT_CEILING_DIRECTORIES="$(dirname "$TMPDIR_BASE")"
cd "$TMPDIR_BASE"

# ---------------------------------------------------------------------------
# Helper: create a fresh isolated temp git repo with a main branch + initial commit
# Uses an empty hooksPath to avoid inheriting global git hooks (e.g. ENFORCE_WORKTREE).
# ---------------------------------------------------------------------------
EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"
EMPTY_EXCLUDES="$TMPDIR_BASE/empty-excludes"
: > "$EMPTY_EXCLUDES"

# Runs inside $(...), where set -e does not apply: every step checks itself and the
# function returns non-zero, so the caller's `REPO=$(make_repo)` stops the script instead
# of handing an empty path to `git -C`.
make_repo() {
    local repo
    repo=$(mktemp -d -p "$TMPDIR_BASE") || return 1
    [[ -n "$repo" && -d "$repo" && "$repo" == "$TMPDIR_BASE"/* ]] || return 1
    git -C "$repo" init -q || return 1
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR" || return 1
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES" || return 1
    git -C "$repo" config core.autocrlf false || return 1
    git -C "$repo" checkout -q -b main || return 1
    git -C "$repo" config user.email "test@example.com" || return 1
    git -C "$repo" config user.name "Test" || return 1
    echo "init" > "$repo/README.md" || return 1
    git -C "$repo" add README.md || return 1
    git -C "$repo" commit -q -m "initial" || return 1
    echo "$repo"
}

# Helper: write a compliant .env.example entry (3 comment lines within 1-5 cap, no banned content)
write_compliant_entry() {
    local path="$1"
    cat > "$path" <<'EOF'
MYVAR=default
# Control widget display.
# You can't do: does not affect server-side behavior.
# Format: 0 (off) | 1 (on). Default: 0.
EOF
}

CASE_DIR="$AGENTS_ROOT/tests/bin/feature-review-env-example"

# shellcheck source=./feature-review-env-example/hard-violation-cases.sh
. "$CASE_DIR/hard-violation-cases.sh"
# shellcheck source=./feature-review-env-example/warn-and-clean-cases.sh
. "$CASE_DIR/warn-and-clean-cases.sh"
# The same checker seen from the scoping side: which files it reads at all, and
# which flags decide that. Uses write_compliant_entry from the dispatcher.
# shellcheck source=./feature-review-env-example/scope-and-flag-cases.sh
. "$CASE_DIR/scope-and-flag-cases.sh"
# The shipped-file regression guards, run against AGENTS_ROOT rather than a fixture.
# shellcheck source=./feature-review-env-example/real-env-example-cases.sh
. "$CASE_DIR/real-env-example-cases.sh"
# shellcheck source=./feature-review-env-example/endif-blank-line-cases.sh
. "$CASE_DIR/endif-blank-line-cases.sh"
# shellcheck source=./feature-review-env-example/legacy-prefix-continuation-cases.sh
. "$CASE_DIR/legacy-prefix-continuation-cases.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ $ERRORS -gt 0 ]]; then echo ""; echo "FAILED: $ERRORS test(s) failed"; exit 1; else echo ""; echo "All tests passed"; fi
