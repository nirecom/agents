#!/bin/bash
# Test suite for pre-commit hook .env file blocking.
# Tests that claude-global/hooks/pre-commit refuses to allow .env files to be
# committed, while allowing .env.example / .env.sample / .env.template.
#
# NOTE: Block cases will FAIL until the hook is extended with .env detection.
# Allow cases and the empty-commit edge case should pass earlier.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SRC="$DOTFILES_DIR/claude-global/hooks/pre-commit"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (macOS lacks `timeout`). Whole-script budget is
# enforced by the caller; per-invocation budget is short to avoid hangs.
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# --- Setup: temp git repo we re-init for each case ---
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# Init a git repo with the pre-commit hook installed and a HEAD commit.
# The hook references DOTFILES_DIR=$(cd hook-dir/../.. && pwd), so we stage
# it inside <repo>/claude-global/hooks/pre-commit and let the script also
# find a real bin/scan-outbound.sh sibling for safety.
init_repo() {
    local repo="$1"
    rm -rf "$repo"
    mkdir -p "$repo/claude-global/hooks"
    mkdir -p "$repo/bin"

    # Copy the real hook
    cp "$HOOK_SRC" "$repo/claude-global/hooks/pre-commit"
    chmod +x "$repo/claude-global/hooks/pre-commit"

    # Copy the scanner so the hook can invoke it
    cp "$DOTFILES_DIR/bin/scan-outbound.sh" "$repo/bin/scan-outbound.sh"
    chmod +x "$repo/bin/scan-outbound.sh"

    # Empty local allowlist (scanner expects it)
    : > "$repo/.private-info-allowlist"

    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    # Honor the on-disk +x bit even on filesystems that don't store it
    git -C "$repo" config core.fileMode true
    # Silence cosmetic LF/CRLF warnings on Windows
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config core.safecrlf false
    # Avoid hitting GitHub API in the hook
    git -C "$repo" remote remove origin 2>/dev/null || true

    # Need a HEAD commit so `git diff-index --cached HEAD` works.
    # Ensure .sh files are staged with the executable bit set so the hook's
    # exec-perm check passes (Windows git doesn't preserve +x from `cp`).
    : > "$repo/README.md"
    git -C "$repo" add README.md .private-info-allowlist
    git -C "$repo" add --chmod=+x bin/scan-outbound.sh
    git -C "$repo" add --chmod=+x claude-global/hooks/pre-commit
    git -C "$repo" commit -q -m "init"
}

# Run the pre-commit hook from inside the repo. Returns its exit code.
run_hook() {
    local repo="$1"
    (
        cd "$repo"
        run_with_timeout ./claude-global/hooks/pre-commit
    )
}

# Stage given files (relative paths inside repo) with placeholder content.
stage_file() {
    local repo="$1" relpath="$2" content="${3:-placeholder=value}"
    mkdir -p "$repo/$(dirname "$relpath")"
    printf '%s\n' "$content" > "$repo/$relpath"
    git -C "$repo" add -- "$relpath"
}

# Assert that running the hook in $repo exits non-zero (commit blocked)
expect_block() {
    local desc="$1" repo="$2"
    if run_hook "$repo" >/dev/null 2>&1; then
        fail "$desc — hook allowed (expected block)"
    else
        pass "$desc"
    fi
}

# Assert that running the hook in $repo exits zero (commit allowed)
expect_allow() {
    local desc="$1" repo="$2"
    if run_hook "$repo" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — hook blocked (expected allow)"
    fi
}

REPO="$TMPBASE/repo"

echo "=== Normal Cases (block) ==="

init_repo "$REPO"
stage_file "$REPO" ".env" "SECRET=abc"
expect_block ".env at repo root is blocked" "$REPO"

init_repo "$REPO"
stage_file "$REPO" "subdir/.env" "SECRET=abc"
expect_block "subdir/.env is blocked" "$REPO"

init_repo "$REPO"
stage_file "$REPO" "some/path/.env" "SECRET=abc"
expect_block "nested some/path/.env is blocked" "$REPO"

echo ""
echo "=== Normal Cases (allow) ==="

init_repo "$REPO"
stage_file "$REPO" ".env.example" "PLACEHOLDER=value"
expect_allow ".env.example is allowed" "$REPO"

init_repo "$REPO"
stage_file "$REPO" ".env.sample" "PLACEHOLDER=value"
expect_allow ".env.sample is allowed" "$REPO"

init_repo "$REPO"
stage_file "$REPO" ".env.template" "PLACEHOLDER=value"
expect_allow ".env.template is allowed" "$REPO"

init_repo "$REPO"
stage_file "$REPO" "env" "PLACEHOLDER=value"
expect_allow "env (no leading dot) is allowed" "$REPO"

init_repo "$REPO"
stage_file "$REPO" ".environment.md" "# notes"
expect_allow ".environment.md is allowed (not the .env pattern)" "$REPO"

echo ""
echo "=== Edge Cases ==="

init_repo "$REPO"
# No additional files staged
expect_allow "empty commit (no .env file) — hook allows" "$REPO"

init_repo "$REPO"
# Empty .env file — must still be blocked
mkdir -p "$REPO"
: > "$REPO/.env"
git -C "$REPO" add -- .env
expect_block ".env with empty content is still blocked" "$REPO"

echo ""
echo "=== Idempotency Cases ==="

init_repo "$REPO"
stage_file "$REPO" ".env" "SECRET=abc"
out1_code=0
run_hook "$REPO" >/dev/null 2>&1 || out1_code=$?
out2_code=0
run_hook "$REPO" >/dev/null 2>&1 || out2_code=$?
if [ "$out1_code" = "$out2_code" ]; then
    pass "idempotent: hook returns same exit code on repeated runs ($out1_code)"
else
    fail "idempotent: exit codes differ ($out1_code vs $out2_code)"
fi

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
