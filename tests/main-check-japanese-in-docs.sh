#!/bin/bash
# Test suite for check-japanese-in-docs.js PreToolUse hook
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/claude-global/hooks/check-japanese-in-docs.js"
ERRORS=0

# Set CLAUDE_PROJECT_DIR to dotfiles repo so resolveRepoDir is deterministic
# (dotfiles is a public repo → isPrivateRepo returns false → block path is reachable)
export CLAUDE_PROJECT_DIR="$DOTFILES_DIR"

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# Run hook with JSON input, return stdout
run_hook() {
    local json="$1"
    echo "$json" | run_with_timeout node "$HOOK" 2>/dev/null
}

expect_block() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"block"'; then
        pass "$desc"
    else
        fail "$desc — expected block, got: $result"
    fi
}

expect_approve() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"approve"'; then
        pass "$desc"
    else
        fail "$desc — expected approve, got: $result"
    fi
}

# --- Normal cases: should block ---
echo "=== Normal cases: should block ==="

expect_block "--subject arg contains hiragana (テスト)" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py docs/history.md --category FEATURE --subject テスト --background ok --changes done"}}'

expect_block "--background arg contains katakana (カタカナ)" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py docs/history.md --category FEATURE --subject test --background カタカナ --changes done"}}'

expect_block "--changes arg contains kanji (変更)" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py docs/history.md --category FEATURE --subject test --background ok --changes 変更した"}}'

expect_block "full-width characters (ＡＢＣ)" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py docs/history.md --category FEATURE --subject ＡＢＣ --background ok --changes done"}}'

expect_block "English + single Japanese character mixed (testあtest)" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py docs/history.md --category FEATURE --subject testあtest --background ok --changes done"}}'

echo ""
echo "=== Normal cases: should approve ==="

expect_approve "English-only doc-append command" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py docs/history.md --category FEATURE --subject Test --background Background --changes Changes"}}'

expect_approve "Bash command with Japanese but no doc-append.py" \
    '{"tool_name":"Bash","tool_input":{"command":"echo テスト"}}'

expect_approve "Edit tool with Japanese (not Bash)" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/some/history.md","old_string":"old","new_string":"テスト"}}'

echo ""
echo "=== Edge cases: should approve ==="

expect_approve "empty command string" \
    '{"tool_name":"Bash","tool_input":{"command":""}}'

expect_approve "doc-append.py with no arguments (no Japanese)" \
    '{"tool_name":"Bash","tool_input":{"command":"uv run bin/doc-append.py"}}'

echo ""
echo "=== Wrapper form: should block ==="

expect_block "doc-append wrapper with Japanese subject" \
    '{"tool_name":"Bash","tool_input":{"command":"doc-append docs/history.md --subject テスト --date 2026-01-01 --commits abc1234 --category FEATURE --background テスト --changes テスト"}}'

echo ""
echo "=== Wrapper form: should approve ==="

expect_approve "doc-append wrapper with English-only content" \
    '{"tool_name":"Bash","tool_input":{"command":"doc-append docs/history.md --subject Test --date 2026-01-01 --commits abc1234 --category FEATURE --background English --changes English"}}'

expect_approve "word-boundary: some-other-command with Japanese (not doc-append)" \
    '{"tool_name":"Bash","tool_input":{"command":"some-other-command --background テスト"}}'

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
