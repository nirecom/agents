#!/bin/bash
# Tests: hooks/block-shell-config.js
# Tags: hook, bin, shell, tests
# Integration tests for hooks/block-shell-config.js PreToolUse hook.
# Blocks direct Write/Edit/MultiEdit/editFiles on user shell config files
# (~/.bashrc, ~/.zshrc, ~/.profile, ~/.bash_profile, ~/.profile_common).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/block-shell-config.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_hook() {
    local json="$1"
    echo "$json" | node "$HOOK" 2>/dev/null
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

echo "=== block-shell-config: protected file writes (should block) ==="

# S1: Edit ~/.bashrc → block
expect_block "S1: Edit ~/.bashrc" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.bashrc","old_string":"a","new_string":"b"}}'

# S2: Edit ~/.zshrc → block
expect_block "S2: Edit ~/.zshrc" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.zshrc","old_string":"a","new_string":"b"}}'

# S3: Edit ~/.profile → block
expect_block "S3: Edit ~/.profile" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.profile","old_string":"a","new_string":"b"}}'

# S4: Edit ~/.bash_profile → block
expect_block "S4: Edit ~/.bash_profile" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.bash_profile","old_string":"a","new_string":"b"}}'

# S5: Edit ~/.profile_common → block
expect_block "S5: Edit ~/.profile_common" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.profile_common","old_string":"a","new_string":"b"}}'

# S6: Write $HOME/.bashrc (env-var form) → block
expect_block "S6: Write \$HOME/.bashrc" \
    '{"tool_name":"Write","tool_input":{"file_path":"$HOME/.bashrc","content":"x"}}'

# S7: Edit $USERPROFILE/.bashrc (Windows env-var) → block
expect_block "S7: Edit \$USERPROFILE/.bashrc" \
    '{"tool_name":"Edit","tool_input":{"file_path":"$USERPROFILE/.bashrc","old_string":"a","new_string":"b"}}'

# S8: Edit absolute path to .bashrc (computed from process.env.HOME) → block
# Use node to resolve HOME so the test is OS-portable.
ABS_BASHRC=$(node -e "console.log(require('os').homedir().replace(/\\\\/g,'/') + '/.bashrc')")
expect_block "S8: Edit absolute $ABS_BASHRC" \
    "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$ABS_BASHRC")"

# S15: MultiEdit ~/.bashrc → block
expect_block "S15: MultiEdit ~/.bashrc" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"~/.bashrc","edits":[]}}'

# S16: editFiles on ~/.bashrc → block
expect_block "S16: editFiles ~/.bashrc" \
    '{"tool_name":"editFiles","tool_input":{"file_path":"~/.bashrc"}}'

echo ""
echo "=== block-shell-config: allowed cases (should approve) ==="

# S9: Edit ~/.config/bashrc → approve (not in protected list)
expect_approve "S9: Edit ~/.config/bashrc" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.config/bashrc","old_string":"a","new_string":"b"}}'

# S10: Edit ~/.bashrc.bak → approve (basename differs)
expect_approve "S10: Edit ~/.bashrc.bak" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/.bashrc.bak","old_string":"a","new_string":"b"}}'

# S11: Edit ~/bashrc → approve (no dot prefix)
expect_approve "S11: Edit ~/bashrc" \
    '{"tool_name":"Edit","tool_input":{"file_path":"~/bashrc","old_string":"a","new_string":"b"}}'

# S12: Edit tests/fixtures/.bashrc → approve (not under $HOME)
expect_approve "S12: Edit tests/fixtures/.bashrc" \
    '{"tool_name":"Edit","tool_input":{"file_path":"tests/fixtures/.bashrc","old_string":"a","new_string":"b"}}'

# S13: Read ~/.bashrc → approve (hook scoped to write tools)
expect_approve "S13: Read ~/.bashrc" \
    '{"tool_name":"Read","tool_input":{"file_path":"~/.bashrc"}}'

# S14: Bash tool reading ~/.bashrc → approve (no write target)
expect_approve "S14: Bash cat ~/.bashrc" \
    '{"tool_name":"Bash","tool_input":{"command":"cat ~/.bashrc"}}'

# S14a: Bash redirect into ~/.bashrc → block
expect_block "S14a: Bash echo >> ~/.bashrc" \
    '{"tool_name":"Bash","tool_input":{"command":"echo export FOO=1 >> ~/.bashrc"}}'

# S14b: Bash tee -a ~/.zshrc → block
expect_block "S14b: Bash tee -a ~/.zshrc" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo | tee -a ~/.zshrc"}}'

# S14c: Bash cp src ~/.profile → block (cp destination)
expect_block "S14c: Bash cp src ~/.profile" \
    '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/profile ~/.profile"}}'

# S14d: Bash redirect to unrelated file → approve
expect_approve "S14d: Bash echo >> ~/notes.md" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> ~/notes.md"}}'

# S17: Malformed JSON → approve (fail-open)
expect_approve "S17: malformed JSON" \
    'NOT JSON AT ALL'

# S17a: JSON null → approve (null-input guard)
expect_approve "S17a: JSON null" \
    'null'

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
