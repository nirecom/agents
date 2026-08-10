#!/bin/bash
# Tests: hooks/lib/is-private-repo.js, hooks/lib/parse-remote-url.js, hooks/scan-outbound.js
# Tags: scan, filter, outbound, hook, tests, scope:common
# Test suite for private repo dynamic detection (is-private-repo.js + hook integration)
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Convert MSYS paths to mixed paths (C:/...) for Node.js on Windows
if command -v cygpath >/dev/null 2>&1; then
  AGENTS_DIR="$(cygpath -m "$AGENTS_DIR")"
fi
# Hooks live at <repo>/hooks/ since the dotfiles→agents split; the stale
# claude-global/ prefix this file used to carry made every case here abort on a
# MODULE_NOT_FOUND before a single assertion ran.
LIB="$AGENTS_DIR/hooks/lib/is-private-repo.js"
HOOK_PRIVATE="$AGENTS_DIR/hooks/scan-outbound.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- Mock gh CLI ---
# Create mock gh that returns configurable responses
# On Windows, Node.js execSync uses cmd.exe, so we need .cmd files
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"

GH_CALL_LOG="$MOCK_BIN/gh-calls.log"
if command -v cygpath >/dev/null 2>&1; then
  GH_CALL_LOG_WIN="$(cygpath -w "$GH_CALL_LOG")"
else
  GH_CALL_LOG_WIN="$GH_CALL_LOG"
fi

# Default mock: repo is public (returns "false")
setup_mock_gh_public() {
    rm -f "$GH_CALL_LOG"
    printf '@echo off\r\necho false\r\n' > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "false"\n' > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

# Mock: repo is private (returns "true")
setup_mock_gh_private() {
    rm -f "$GH_CALL_LOG"
    printf '@echo off\r\necho true\r\n' > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "true"\n' > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

# Mock: gh fails (network error, auth error, etc.)
setup_mock_gh_error() {
    rm -f "$GH_CALL_LOG"
    printf '@echo off\r\necho gh: Not Found (HTTP 404) 1>&2\r\nexit /b 1\r\n' > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "gh: Not Found (HTTP 404)" >&2\nexit 1\n' > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

# Mock: gh not found (remove from PATH)
setup_mock_gh_missing() {
    rm -f "$GH_CALL_LOG" "$MOCK_BIN/gh" "$MOCK_BIN/gh.cmd"
}

# Mock: records one line per invocation, then answers "true" (private).
# "true" is the deliberate answer: it means an unwanted gh call cannot go
# unnoticed — it would flip the returned value as well as the call log.
setup_mock_gh_recording() {
    rm -f "$GH_CALL_LOG"
    printf '@echo off\r\necho call 1>>"%s"\r\necho true\r\n' "$GH_CALL_LOG_WIN" > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho call >> "%s"\necho "true"\n' "$GH_CALL_LOG" > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

gh_call_count() {
    if [ -f "$GH_CALL_LOG" ]; then
        awk 'END { print NR }' "$GH_CALL_LOG"
    else
        echo 0
    fi
}

# Invoke isPrivateRepo() with the mock gh ahead of the real one on PATH.
# repoDir is passed as argv, never interpolated into the -e source.
run_is_private_repo() {
    PATH="$MOCK_BIN:$PATH" node -e "
const { isPrivateRepo } = require('$LIB');
console.log(isPrivateRepo(process.argv[1]));
" "$1"
}

# Helper: create a git repo with a remote
# Returns mixed path (C:/...) on Windows for Node.js compatibility
setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo/src" "$repo/docs" "$repo/tests"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote add origin "git@github.com:testowner/testrepo.git"
    echo "init" > "$repo/README.md"
    echo "# docs" > "$repo/docs/history.md"
    echo "# test" > "$repo/tests/test.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "initial" 2>/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Helper: bare git repo whose only interesting property is its origin URL.
# No commit is made — every consumer here reads `remote get-url origin` only.
setup_repo_with_origin() {
    local url="$1"
    local repo="$TMPDIR_BASE/repo-origin-$RANDOM$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote add origin "$url"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

run_hook() {
    local hook="$1" json="$2" repo="$3"
    echo "$json" | PATH="$MOCK_BIN:$PATH" CLAUDE_PROJECT_DIR="$repo" HOOK_CWD="$repo" node "$hook" 2>/dev/null || true
}

expect_approve() {
    local desc="$1" hook="$2" json="$3" repo="$4"
    local result
    result=$(run_hook "$hook" "$json" "$repo")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

expect_block() {
    local desc="$1" hook="$2" json="$3" repo="$4"
    local result
    result=$(run_hook "$hook" "$json" "$repo")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

SCRIPT_DIR="$(dirname "$0")/main-private-repo-detection"

# shellcheck source=./main-private-repo-detection/unit-parsing.sh
. "$SCRIPT_DIR/unit-parsing.sh"
# shellcheck source=./main-private-repo-detection/unit-is-private-repo.sh
. "$SCRIPT_DIR/unit-is-private-repo.sh"
# shellcheck source=./main-private-repo-detection/parse-failure-fail-open.sh
. "$SCRIPT_DIR/parse-failure-fail-open.sh"
# shellcheck source=./main-private-repo-detection/gh-target-and-injection.sh
. "$SCRIPT_DIR/gh-target-and-injection.sh"
# shellcheck source=./main-private-repo-detection/integration-scan-outbound.sh
. "$SCRIPT_DIR/integration-scan-outbound.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
