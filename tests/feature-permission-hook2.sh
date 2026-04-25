#!/bin/bash
# ask-before-commit dialog test (permissions.ask test)
# Test suite for permission-hook2 feature
# Scanner + PermissionRequest hook tests for feature/permission-hook2
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

expect_detect() {
    local desc="$1" input="$2"
    if echo "$input" | "$SCANNER" --stdin test >/dev/null 2>&1; then
        fail "$desc — not detected"
    else
        pass "$desc"
    fi
}

expect_clean() {
    local desc="$1" input="$2"
    if echo "$input" | "$SCANNER" --stdin test >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — false positive"
    fi
}

echo "=== Scanner: Normal Cases ==="

expect_detect "IPv4 192.168.1.100" "addr=192.168.1.100"
expect_detect "IPv4 10.0.0.1" "server 10.0.0.1 up"
expect_detect "IPv4 172.16.0.1" "host 172.16.0.1"
expect_detect "IPv4 172.31.255.255" "host 172.31.255.255"
expect_detect "email address" "contact user@example.com"
expect_detect "MAC address" "hw aa:bb:cc:dd:ee:ff"
expect_detect "/Users/ path" "open /Users/someone/file"
expect_detect "/home/ path" "cat /home/someone/.bashrc"
expect_detect "C:\\Users\\ path" 'dir C:\Users\someone\docs'
expect_detect "C:/Users/ path" "open C:/Users/someone/docs"

echo ""
echo "=== Scanner: MSYS Paths ==="

expect_detect "MSYS /c/Users/nire" "ls /c/Users/nire"
expect_detect "MSYS /d/Work/project" "cd /d/Work/project"
expect_detect "MSYS /c/test at line start" "/c/test/file"
expect_detect "MSYS space-prefixed /c/test" "abc /c/test/file"

echo ""
echo "=== Scanner: WSL Paths ==="

expect_detect "WSL /mnt/c/Users/test" "cat /mnt/c/Users/test"
expect_detect "WSL /mnt/d/data" "ls /mnt/d/data/file.txt"
expect_detect "WSL embedded in string" "path=/mnt/c/Users/test"

echo ""
echo "=== Scanner: Error Cases ==="

if "$SCANNER" 2>/dev/null; then
    fail "no args — should exit 2"
elif [ $? -eq 2 ]; then
    pass "no args — exit 2"
else
    fail "no args — unexpected exit code $?"
fi

output=$("$SCANNER" /nonexistent/file/path 2>&1) || true
if echo "$output" | grep -qi "warning.*not found"; then
    pass "nonexistent file — warning printed"
else
    fail "nonexistent file — no warning"
fi

if echo "" | "$SCANNER" --stdin test >/dev/null 2>&1; then
    pass "empty input — no violations"
else
    fail "empty input — false positive"
fi

echo ""
echo "=== Scanner: Edge Cases ==="

expect_detect "multiple violations on one line" "user@example.com at 192.168.1.1"
expect_clean "/home/linuxbrew exception" "export PATH=/home/linuxbrew/.linuxbrew/bin"
expect_clean "allowlisted NVIDIA version 10.3.9.90" "cuda 10.3.9.90"
expect_clean "not token boundary abc/c/test" "abc/c/test"
expect_clean "/c alone (no subpath)" "mount /c"
expect_clean "/mnt/c alone (no subpath)" "mount /mnt/c"
expect_clean "/c/ trailing slash only" "ls /c/"
expect_clean "allowlisted /c/Windows" "dir /c/Windows/System32"
expect_clean "allowlisted /c/Program Files" "ls /c/Program Files/app"
expect_clean "allowlisted /c/ProgramData" "cat /c/ProgramData/config"
expect_clean "allowlisted /c/tools" "run /c/tools/bin/util"
expect_clean "whitespace only" "     "
expect_detect "IPv4 172.20.x (mid-range)" "host 172.20.5.5"
expect_clean "IPv4 172.15.x (out of RFC1918)" "host 172.15.0.1"
expect_clean "IPv4 172.32.x (out of RFC1918)" "host 172.32.0.1"

echo ""
echo "=== PermissionRequest Hook: Normal Cases ==="

HOOK="$DOTFILES_DIR/claude-global/hooks/permission-allow.js"
TMPALLOW=$(mktemp)
trap "rm -f $TMPALLOW" EXIT

cat > "$TMPALLOW" <<'CMDS'
# Group 1: git read-only
git status
git log --oneline -20

# Group 2: compound
find . -name "*.md" | head -5
CMDS

run_hook() {
    local cmd="$1"
    local json
    json=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(echo "$cmd" | sed 's/"/\\"/g')")
    echo "$json" | ALLOWED_COMMANDS_FILE="$TMPALLOW" node "$HOOK" 2>/dev/null
}

result=$(run_hook "git status")
if echo "$result" | grep -q '"allow"'; then pass "allowed command → allow"
else fail "allowed command did not return allow"; fi

result=$(run_hook "rm -rf /")
if [ -z "$result" ]; then pass "disallowed command → empty"
else fail "disallowed command returned: $result"; fi

result=$(run_hook 'find . -name "*.md" | head -5')
if echo "$result" | grep -q '"allow"'; then pass "compound command with pipe → allow"
else fail "compound command did not return allow"; fi

result=$(printf '{"tool_name":"Edit","tool_input":{"file":"/tmp/x"}}' | ALLOWED_COMMANDS_FILE="$TMPALLOW" node "$HOOK" 2>/dev/null)
if [ -z "$result" ]; then pass "non-Bash tool → empty (passthrough)"
else fail "non-Bash tool returned: $result"; fi

result=$(printf '{"tool_name":"Bash","tool_input":{"command":""}}' | ALLOWED_COMMANDS_FILE="$TMPALLOW" node "$HOOK" 2>/dev/null)
if [ -z "$result" ]; then pass "empty command → empty"
else fail "empty command returned: $result"; fi

echo ""
echo "=== PermissionRequest Hook: Error Cases ==="

result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | ALLOWED_COMMANDS_FILE="/nonexistent/file" node "$HOOK" 2>/dev/null)
if [ -z "$result" ]; then pass "missing allowlist file → empty (fail-safe)"
else fail "missing file returned: $result"; fi

result=$(echo 'NOT JSON' | ALLOWED_COMMANDS_FILE="$TMPALLOW" node "$HOOK" 2>/dev/null)
if [ -z "$result" ]; then pass "invalid JSON input → empty (fail-safe)"
else fail "invalid JSON returned: $result"; fi

result=$(printf '{"tool_name":"Bash","tool_input":{}}' | ALLOWED_COMMANDS_FILE="$TMPALLOW" node "$HOOK" 2>/dev/null)
if [ -z "$result" ]; then pass "missing command field → empty"
else fail "missing command field returned: $result"; fi

echo ""
echo "=== PermissionRequest Hook: Edge Cases ==="

result=$(run_hook "git  status")
if echo "$result" | grep -q '"allow"'; then pass "extra whitespace normalized → allow"
else fail "extra whitespace not normalized"; fi

result=$(run_hook "git status ")
if echo "$result" | grep -q '"allow"'; then pass "trailing whitespace → allow"
else fail "trailing whitespace not normalized"; fi

result=$(run_hook " git status")
if echo "$result" | grep -q '"allow"'; then pass "leading whitespace → allow"
else fail "leading whitespace not normalized"; fi

result=$(run_hook "git status --short")
if [ -z "$result" ]; then pass "partial match (suffix) → empty"
else fail "partial match (suffix) returned: $result"; fi

result=$(run_hook "git")
if [ -z "$result" ]; then pass "partial match (prefix) → empty"
else fail "partial match (prefix) returned: $result"; fi

result=$(run_hook "Git Status")
if [ -z "$result" ]; then pass "case sensitive — Git Status ≠ git status"
else fail "case sensitivity not enforced"; fi

printf -v crlf_cmd "git status\r\n"
result=$(run_hook "$crlf_cmd")
if echo "$result" | grep -q '"allow"'; then pass "CRLF normalized → allow"
else fail "CRLF not normalized"; fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
