#!/bin/bash
# Test suite for check-cross-platform.js PreToolUse hook
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/claude-global/hooks/check-cross-platform.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# --- Unit tests: non-commit commands (no git repo needed) ---

run_hook() {
    local json="$1"
    echo "$json" | node "$HOOK" 2>/dev/null
}

expect_approve() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

expect_block() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

echo "=== Non-commit commands (should approve) ==="
expect_approve "git status" '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
expect_approve "git push" '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
expect_approve "non-Bash tool" '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'

echo ""
echo "=== Edge cases: invalid input ==="
expect_approve "missing tool_input" '{"tool_name":"Bash"}'
expect_approve "empty command" '{"tool_name":"Bash","tool_input":{"command":""}}'
expect_approve "invalid JSON" 'NOT JSON'

# --- Integration tests: real git repo with staging ---

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo/install/win" "$repo/install/linux" "$repo/install/qnap"
    mkdir -p "$repo/src"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

run_hook_in_repo() {
    local repo="$1" json="$2"
    echo "$json" | HOOK_CWD="$repo" node "$HOOK" 2>/dev/null
}

expect_block_repo() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_hook_in_repo "$repo" "$json")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

expect_approve_repo() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_hook_in_repo "$repo" "$json")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"update\""}}'

# --- Normal cases (approve) ---

echo ""
echo "=== Normal: both platforms staged (install) ==="
REPO=$(setup_repo)
echo "win script" > "$REPO/install/win/starship.ps1"
echo "linux script" > "$REPO/install/linux/starship.sh"
git -C "$REPO" add install/win/starship.ps1 install/linux/starship.sh
expect_approve_repo "install/win + install/linux both staged" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Normal: non-platform files only ==="
REPO=$(setup_repo)
echo "code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_approve_repo "non-platform files only" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Normal: nothing staged ==="
REPO=$(setup_repo)
expect_approve_repo "nothing staged" "$REPO" "$COMMIT_JSON"

# --- Block cases ---

echo ""
echo "=== Block: install/win only, no skiplist ==="
REPO=$(setup_repo)
echo "win script" > "$REPO/install/win/starship.ps1"
git -C "$REPO" add install/win/starship.ps1
expect_block_repo "install/win only" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Block: install/linux only ==="
REPO=$(setup_repo)
echo "linux script" > "$REPO/install/linux/starship.sh"
git -C "$REPO" add install/linux/starship.sh
expect_block_repo "install/linux only" "$REPO" "$COMMIT_JSON"

# --- Edge: skiplist ---

echo ""
echo "=== Edge: skiplist exemption ==="
REPO=$(setup_repo)
echo "autohotkey" > "$REPO/.cross-platform-skiplist"
echo "ahk script" > "$REPO/install/win/autohotkey.ps1"
git -C "$REPO" add install/win/autohotkey.ps1 .cross-platform-skiplist
expect_approve_repo "skiplist exempts autohotkey" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Edge: skiplist with comments and blank lines ==="
REPO=$(setup_repo)
printf "# Windows-only tools\nautohotkey\n\npowertoys\n" > "$REPO/.cross-platform-skiplist"
echo "ahk" > "$REPO/install/win/autohotkey.ps1"
echo "pt" > "$REPO/install/win/powertoys.ps1"
git -C "$REPO" add install/win/autohotkey.ps1 install/win/powertoys.ps1 .cross-platform-skiplist
expect_approve_repo "skiplist with comments/blanks" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Edge: partial skiplist — some files exempted, some not ==="
REPO=$(setup_repo)
echo "autohotkey" > "$REPO/.cross-platform-skiplist"
echo "ahk" > "$REPO/install/win/autohotkey.ps1"
echo "starship" > "$REPO/install/win/starship.ps1"
git -C "$REPO" add install/win/autohotkey.ps1 install/win/starship.ps1 .cross-platform-skiplist
expect_block_repo "partial skiplist — starship not exempted" "$REPO" "$COMMIT_JSON"

# --- Edge: one-time marker ---

echo ""
echo "=== Edge: .cross-platform-reviewed marker with current hash ==="
REPO=$(setup_repo)
echo "win script" > "$REPO/install/win/starship.ps1"
git -C "$REPO" add install/win/starship.ps1
local_gitdir=$(git -C "$REPO" rev-parse --git-dir)
local_head=$(git -C "$REPO" rev-parse --short HEAD)
echo "$local_head" > "$REPO/$local_gitdir/.cross-platform-reviewed"
expect_approve_repo "marker with current HEAD hash" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Edge: stale marker (wrong hash) ==="
REPO=$(setup_repo)
echo "win script" > "$REPO/install/win/starship.ps1"
git -C "$REPO" add install/win/starship.ps1
local_gitdir=$(git -C "$REPO" rev-parse --git-dir)
echo "0000000" > "$REPO/$local_gitdir/.cross-platform-reviewed"
expect_block_repo "stale marker" "$REPO" "$COMMIT_JSON"

# --- Edge: qnap (no pair) ---

echo ""
echo "=== Edge: install/qnap only (no pair, should approve) ==="
REPO=$(setup_repo)
echo "qnap script" > "$REPO/install/qnap/setup.sh"
git -C "$REPO" add install/qnap/setup.sh
expect_approve_repo "qnap only — no pair" "$REPO" "$COMMIT_JSON"

# --- Edge: git -C path commit ---

echo ""
echo "=== Edge: git -C path commit ==="
REPO=$(setup_repo)
echo "win script" > "$REPO/install/win/starship.ps1"
git -C "$REPO" add install/win/starship.ps1
expect_block_repo "git -C commit" "$REPO" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO commit -m \\\"update\\\"\"}}"

# --- Idempotency ---

echo ""
echo "=== Idempotency: repeated hook calls produce same result ==="
REPO=$(setup_repo)
echo "win script" > "$REPO/install/win/starship.ps1"
git -C "$REPO" add install/win/starship.ps1
result1=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
result2=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
if [ "$result1" = "$result2" ]; then pass "idempotent block"
else fail "idempotent block — results differ: $result1 vs $result2"; fi

REPO=$(setup_repo)
echo "win" > "$REPO/install/win/starship.ps1"
echo "linux" > "$REPO/install/linux/starship.sh"
git -C "$REPO" add install/win/starship.ps1 install/linux/starship.sh
result1=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
result2=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
if [ "$result1" = "$result2" ]; then pass "idempotent approve"
else fail "idempotent approve — results differ: $result1 vs $result2"; fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
