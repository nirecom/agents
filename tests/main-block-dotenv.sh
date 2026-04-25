#!/bin/bash
# Test suite for block-dotenv.js PreToolUse hook
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/claude-global/hooks/block-dotenv.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Run hook with JSON input, return stdout
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

# --- Bash tool: Normal cases ---
echo "=== Bash: Normal Cases (should block) ==="

expect_block "cat .env" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'

expect_block "cat .env.local" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env.local"}}'

expect_block "cat .env.production" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env.production"}}'

expect_block "head .env" \
    '{"tool_name":"Bash","tool_input":{"command":"head .env"}}'

expect_block "tail -f .env" \
    '{"tool_name":"Bash","tool_input":{"command":"tail -f .env"}}'

expect_block "less .env" \
    '{"tool_name":"Bash","tool_input":{"command":"less .env"}}'

expect_block "source .env" \
    '{"tool_name":"Bash","tool_input":{"command":"source .env"}}'

expect_block "dot-source . .env" \
    '{"tool_name":"Bash","tool_input":{"command":". .env"}}'

expect_block "grep pattern .env" \
    '{"tool_name":"Bash","tool_input":{"command":"grep PASSWORD .env"}}'

expect_block "absolute path /app/.env" \
    '{"tool_name":"Bash","tool_input":{"command":"cat /app/.env"}}'

expect_block "relative path ./subdir/.env" \
    '{"tool_name":"Bash","tool_input":{"command":"cat ./subdir/.env"}}'

echo ""
echo "=== Bash: Bypass patterns (should block) ==="

expect_block "bash -c cat .env" \
    '{"tool_name":"Bash","tool_input":{"command":"bash -c \"cat .env\""}}'

expect_block "sh -c cat .env" \
    '{"tool_name":"Bash","tool_input":{"command":"sh -c '\''cat .env'\''"}}'

expect_block "/bin/cat .env" \
    '{"tool_name":"Bash","tool_input":{"command":"/bin/cat .env"}}'

expect_block "pipe through .env" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env | grep KEY"}}'

expect_block "redirect from .env" \
    '{"tool_name":"Bash","tool_input":{"command":"wc -l < .env"}}'

expect_block "cp .env to tmp" \
    '{"tool_name":"Bash","tool_input":{"command":"cp .env /tmp/secrets"}}'

expect_block "mv .env" \
    '{"tool_name":"Bash","tool_input":{"command":"mv .env .env.bak"}}'

echo ""
echo "=== Bash: Allowed patterns (should approve) ==="

expect_approve "cat .env.example" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env.example"}}'

expect_approve "cat .env.sample" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env.sample"}}'

expect_approve "cat .env.template" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env.template"}}'

expect_approve "cat .env.dist" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env.dist"}}'

expect_approve "echo .env in string" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"copy .env.example to .env\""}}'

expect_approve "git status" \
    '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

expect_approve "ls -la" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

expect_approve "no .env reference" \
    '{"tool_name":"Bash","tool_input":{"command":"cat README.md"}}'

echo ""
echo "=== Read tool ==="

expect_block "Read .env" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.env"}}'

expect_block "Read .env.local" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.env.local"}}'

expect_block "Read nested .env" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/deep/nested/.env"}}'

expect_approve "Read .env.example" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.env.example"}}'

expect_approve "Read .env.template" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.env.template"}}'

expect_approve "Read normal file" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/src/app.js"}}'

expect_approve "Read envconfig.js (not .env)" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/envconfig.js"}}'

echo ""
echo "=== Grep tool ==="

expect_block "Grep in .env" \
    '{"tool_name":"Grep","tool_input":{"pattern":"SECRET","path":"/project/.env"}}'

expect_block "Grep in .env.local" \
    '{"tool_name":"Grep","tool_input":{"pattern":"KEY","path":"/project/.env.local"}}'

expect_approve "Grep in .env.example" \
    '{"tool_name":"Grep","tool_input":{"pattern":"KEY","path":"/project/.env.example"}}'

expect_approve "Grep normal path" \
    '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"/project/src"}}'

expect_approve "Grep no path" \
    '{"tool_name":"Grep","tool_input":{"pattern":"TODO"}}'

echo ""
echo "=== Glob tool ==="

expect_block "Glob **/.env" \
    '{"tool_name":"Glob","tool_input":{"pattern":"**/.env"}}'

expect_block "Glob **/.env.*" \
    '{"tool_name":"Glob","tool_input":{"pattern":"**/.env.*"}}'

expect_block "Glob .env*" \
    '{"tool_name":"Glob","tool_input":{"pattern":".env*"}}'

expect_approve "Glob **/.env.example" \
    '{"tool_name":"Glob","tool_input":{"pattern":"**/.env.example"}}'

expect_approve "Glob *.js" \
    '{"tool_name":"Glob","tool_input":{"pattern":"**/*.js"}}'

echo ""
echo "=== Edge cases ==="

expect_approve "missing tool_input" \
    '{"tool_name":"Bash"}'

expect_approve "missing tool_name" \
    '{"tool_input":{"command":"cat .env"}}'

expect_approve "unknown tool" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/.env","new_string":"x"}}'

expect_approve "empty command" \
    '{"tool_name":"Bash","tool_input":{"command":""}}'

expect_approve "invalid JSON" \
    'NOT JSON'

echo ""
echo "=== Edge: False positive prevention ==="

expect_approve "Read .envrc (not .env)" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.envrc"}}'

expect_approve "Read .environment (not .env)" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.environment"}}'

expect_approve "Read env.json (not .env)" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/env.json"}}'

expect_approve "Bash cat .envrc" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .envrc"}}'

echo ""
echo "=== Edge: Windows paths ==="

expect_block "Read Windows .env" \
    '{"tool_name":"Read","tool_input":{"file_path":"C:\\project\\.env"}}'

expect_block "Read Windows .env.local" \
    '{"tool_name":"Read","tool_input":{"file_path":"C:\\project\\.env.local"}}'

echo ""
echo "=== Edge: Grep glob parameter ==="

expect_block "Grep glob targets .env" \
    '{"tool_name":"Grep","tool_input":{"pattern":"KEY","glob":"**/.env"}}'

expect_block "Grep glob targets .env.*" \
    '{"tool_name":"Grep","tool_input":{"pattern":"KEY","glob":".env.*"}}'

expect_approve "Grep glob targets .env.example" \
    '{"tool_name":"Grep","tool_input":{"pattern":"KEY","glob":"**/.env.example"}}'

echo ""
echo "=== Bash: .env in echo/print context (should approve) ==="

expect_approve "echo mentions .env" \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"Remember to create .env from .env.example\""}}'

expect_approve "printf mentions .env" \
    '{"tool_name":"Bash","tool_input":{"command":"printf \"Setup: cp .env.example .env\\n\""}}'

echo ""
echo "=== Bash: git commit message containing .env (should approve) ==="

expect_approve "git commit -m mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Add hook to block .env access\""}}'

expect_approve "git commit heredoc mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<'"'"'EOF'"'"'\nBlock .env file access\nEOF\n)\""}}'

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
