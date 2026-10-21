#!/bin/bash
# Tests: bin/scan-outbound.sh
# Tags: scan, filter, outbound, hook, permissions, scope:issue-specific
# ask-before-commit dialog test (permissions.ask test)
# Test suite for permission-hook2 feature
# Scanner tests for feature/permission-hook2 (PermissionRequest hook section removed: permission-allow.js deleted in 27018f87, no successor)
set -euo pipefail

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

DOTFILES_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="$DOTFILES_DIR/bin/scan-outbound.sh"
DETECT_LOCAL_PART=someone
DETECT_DOMAIN=corp-mail.org
DETECT_EMAIL="${DETECT_LOCAL_PART}@${DETECT_DOMAIN}"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

expect_detect() {
    local desc="$1" input="$2" expected_tag="${3:-}" rc=0 out
    out=$(echo "$input" | "$SCANNER" --stdin test 2>&1) || rc=$?
    if [ "$rc" -ne 1 ]; then
        fail "$desc — expected detection exit 1, got $rc"
    elif ! echo "$out" | grep -q "^test:1:" || ! echo "$out" | grep -q "hard violation"; then
        fail "$desc — detection output missing"
    elif [ -n "$expected_tag" ] && ! echo "$out" | grep -qF "$expected_tag"; then
        fail "$desc — expected label $expected_tag not in output"
    else
        pass "$desc"
    fi
}

expect_clean() {
    local desc="$1" input="$2" rc=0
    echo "$input" | "$SCANNER" --stdin test >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc — expected exit 0, got $rc"
    fi
}

echo "=== Scanner: Normal Cases ==="

expect_detect "IPv4 192.168.1.100" "addr=192.168.1.100"
expect_detect "IPv4 10.0.0.1" "server 10.0.0.1 up"
expect_detect "IPv4 172.16.0.1" "host 172.16.0.1"
expect_detect "IPv4 172.31.255.255" "host 172.31.255.255"
expect_detect "email address" "contact ${DETECT_EMAIL}"
expect_clean "example.com test email is allowlisted" "contact user@example.com"
expect_detect "MAC address" "hw aa:bb:cc:dd:ee:ff"
expect_detect "/Users/ path" "open /Users/someone/file"
expect_detect "/home/ path" "cat /home/someone/.bashrc"
expect_detect "C:\\Users\\ path" 'dir C:\Users\someone\docs'
expect_detect "C:/Users/ path" "open C:/Users/someone/docs"

echo ""
echo "=== Scanner: MSYS Paths ==="

expect_detect "MSYS /c/Users/nire" "ls /c/Users/nire" "[msys-path]"
expect_detect "MSYS /d/Work/project" "cd /d/Work/project" "[msys-path]"
expect_detect "MSYS /c/test at line start" "/c/test/file" "[msys-path]"
expect_detect "MSYS space-prefixed /c/test" "abc /c/test/file" "[msys-path]"

echo ""
echo "=== Scanner: WSL Paths ==="

expect_detect "WSL /mnt/c/Users/test" "cat /mnt/c/Users/test" "[wsl-path]"
expect_detect "WSL /mnt/d/data" "ls /mnt/d/data/file.txt" "[wsl-path]"
expect_detect "WSL embedded in string" "path=/mnt/c/Users/test" "[wsl-path]"

echo ""
echo "=== Scanner: Error Cases ==="

rc=0
"$SCANNER" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 3 ]; then
    pass "no args — exit 3 (usage error; exit 2 is warn-only)"
else
    fail "no args — expected exit 3, got $rc"
fi

output=$("$SCANNER" /nonexistent/file/path 2>&1) || true
if echo "$output" | grep -qi "warning.*not found"; then
    pass "nonexistent file — warning printed"
else
    fail "nonexistent file — no warning"
fi

if printf '' | "$SCANNER" --stdin test >/dev/null 2>&1; then
    pass "empty input — no violations"
else
    fail "empty input — false positive"
fi

echo ""
echo "=== Scanner: Edge Cases ==="

expect_detect "multiple violations on one line" "${DETECT_EMAIL} at 192.168.1.1"
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
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
