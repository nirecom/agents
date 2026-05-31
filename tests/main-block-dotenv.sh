#!/bin/bash
# Tests: bin/cat, hooks/block-dotenv.js
# Tags: dotenv, secrets, hook, bin, env
# Test suite for block-dotenv.js PreToolUse hook
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/hooks/block-dotenv.js"
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
echo "=== Edit tool ==="

expect_block "Edit /project/.env" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/.env","old_string":"a","new_string":"b"}}'

expect_block "Edit /project/.env.local" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/.env.local","old_string":"a","new_string":"b"}}'

expect_block "Edit nested .env.production" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/deep/nested/.env.production","old_string":"a","new_string":"b"}}'

expect_block "Edit Windows .env" \
    '{"tool_name":"Edit","tool_input":{"file_path":"C:\\project\\.env","old_string":"a","new_string":"b"}}'

expect_approve "Edit .env.example" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/.env.example","old_string":"a","new_string":"b"}}'

expect_approve "Edit .env.template" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/.env.template","old_string":"a","new_string":"b"}}'

expect_approve "Edit normal file" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/src/app.js","old_string":"a","new_string":"b"}}'

expect_approve "Edit .envrc (false positive prevention)" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/.envrc","old_string":"a","new_string":"b"}}'

echo ""
echo "=== Write tool ==="

expect_block "Write /project/.env" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/.env","content":"SECRET=x"}}'

expect_block "Write /project/.env.production" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/.env.production","content":"SECRET=x"}}'

expect_approve "Write .env.example" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/.env.example","content":"KEY=value"}}'

expect_approve "Write normal file" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/src/app.js","content":"console.log(1)"}}'

echo ""
echo "=== MultiEdit tool ==="

expect_block "MultiEdit /project/.env" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"/project/.env","edits":[]}}'

expect_block "MultiEdit /project/.env.local" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"/project/.env.local","edits":[]}}'

expect_approve "MultiEdit .env.example" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"/project/.env.example","edits":[]}}'

expect_approve "MultiEdit normal file" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"/project/src/app.js","edits":[]}}'

echo ""
echo "=== Edge cases ==="

expect_approve "missing tool_input" \
    '{"tool_name":"Bash"}'

expect_approve "missing tool_name" \
    '{"tool_input":{"command":"cat .env"}}'

expect_approve "unknown tool (Task)" \
    '{"tool_name":"Task","tool_input":{"description":"do something"}}'

expect_approve "empty command" \
    '{"tool_name":"Bash","tool_input":{"command":""}}'

expect_approve "invalid JSON" \
    'NOT JSON'

expect_approve "Edit with missing file_path" \
    '{"tool_name":"Edit","tool_input":{"old_string":"a","new_string":"b"}}'

expect_approve "Write with missing file_path" \
    '{"tool_name":"Write","tool_input":{"content":"x"}}'

expect_approve "MultiEdit with missing file_path" \
    '{"tool_name":"MultiEdit","tool_input":{"edits":[]}}'

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
echo "=== Bash: gh pr/issue body mentioning .env (should approve) ==="

expect_approve "gh pr create --body mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \"Fix: block .env access\""}}'

expect_approve "gh issue create --title and --body mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"gh issue create --title Bug --body \"The .env file is blocked\""}}'

expect_approve "gh pr comment --body mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr comment 1 --body \"Updated .env hook\""}}'

echo ""
echo "=== Bash: command substitution recursion (should block) ==="

# $() and backticks are NOT inert text — they execute as shell commands.
# The parser recurses into substitution bodies before stripping.
expect_block 'gh pr create --body $(cat .env)' \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \"$(cat .env)\""}}'

expect_block 'echo $(grep KEY .env)' \
    '{"tool_name":"Bash","tool_input":{"command":"echo \"$(grep KEY .env)\""}}'

expect_block "backtick command substitution touching .env" \
    '{"tool_name":"Bash","tool_input":{"command":"echo `cat .env`"}}'

echo ""
echo "=== Bash: redirect-to-.env via echo/printf (should block) ==="

# echo/printf positional args are text, but redirect operators are syntax.
# Redirect-target check runs BEFORE the TEXT_CMDS short-circuit.
expect_block "echo SECRET > .env" \
    '{"tool_name":"Bash","tool_input":{"command":"echo SECRET > .env"}}'

expect_block "printf x >> .env.production" \
    '{"tool_name":"Bash","tool_input":{"command":"printf x >> .env.production"}}'

expect_block "echo > .env (truncate)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo > .env"}}'

echo ""
echo "=== Bash: shell wrapper combined flags (should block) ==="

# bash -lc, -ic, -Oc, etc. — combined login/interactive/option flags must
# also trigger script recursion.
expect_block "bash -lc cat .env" \
    '{"tool_name":"Bash","tool_input":{"command":"bash -lc \"cat .env\""}}'

expect_block "sh -ic cat .env" \
    '{"tool_name":"Bash","tool_input":{"command":"sh -ic \"cat .env\""}}'

echo ""
echo "=== Bash: short Unix flags should not bypass .env detection ==="

# -l, -a, -r are NOT in TEXT_FLAGS (they collide with common Unix flags like
# wc -l, ls -a, cp -r) so .env in the next positional must block.
expect_block "wc -l .env (line count leak)" \
    '{"tool_name":"Bash","tool_input":{"command":"wc -l .env"}}'

expect_block "ls -l .env (metadata leak)" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -l .env"}}'

expect_block "cp -r .env /tmp" \
    '{"tool_name":"Bash","tool_input":{"command":"cp -r .env /tmp/x"}}'

echo ""
echo "=== Bash: git commit message containing .env (should approve) ==="

expect_approve "git commit -m mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Add hook to block .env access\""}}'

expect_approve "git commit heredoc mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<'"'"'EOF'"'"'\nBlock .env file access\nEOF\n)\""}}'

expect_approve "git -C path commit -m mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"git -C /some/path commit -m \"block .env access\""}}'

expect_approve "git -C path commit heredoc mentioning .env" \
    '{"tool_name":"Bash","tool_input":{"command":"git -C /some/path commit -m \"$(cat <<'"'"'EOF'"'"'\nBlock .env file access\nEOF\n)\""}}'

echo ""
echo "=== Attached-redirect / attached-flag bypass coverage ==="

expect_block "echo x >.env (attached redirect, no space)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo x >.env"}}'

expect_block "cat <.env (attached stdin redirect)" \
    '{"tool_name":"Bash","tool_input":{"command":"cat <.env"}}'

expect_block "cmd 2>.env (attached stderr redirect)" \
    '{"tool_name":"Bash","tool_input":{"command":"cmd 2>.env"}}'

expect_block "cmd --file=.env (--flag=value path form)" \
    '{"tool_name":"Bash","tool_input":{"command":"cmd --file=.env"}}'

expect_approve "cmd --body=.env (text-flag = form, no path access)" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body=.env"}}'

echo ""
echo "=== IDE tools (runInTerminal/runCommands/editFiles) ==="

expect_block "runInTerminal cat .env" \
    '{"tool_name":"runInTerminal","tool_input":{"command":"cat .env"}}'

expect_block "runCommands cat .env" \
    '{"tool_name":"runCommands","tool_input":{"command":"cat .env"}}'

expect_block "editFiles .env" \
    '{"tool_name":"editFiles","tool_input":{"file_path":".env"}}'

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
