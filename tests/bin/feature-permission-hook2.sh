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
# #2992 item 3: a <name> placeholder right before a one-letter dir is not a drive path; real ones around it still are.
# PH_X is assembled at runtime so this file itself carries no placeholder-then-path literal.
PH_X="/x"
expect_clean "MSYS placeholder <dir> before a one-letter dir" "see <dir>${PH_X}/y.txt"
expect_detect "MSYS right after a redirect" "cat >/c/Users/nire/out.txt" "[msys-path]"
expect_detect "MSYS after a placeholder and a space" "<x> /c/Users/nire" "[msys-path]"
expect_detect "MSYS with a placeholder elsewhere on the line" "ls /c/Users/y; echo <x>" "[msys-path]"
expect_detect "MSYS after <b > (a space inside is no placeholder)" "a <b >/c/Users/x" "[msys-path]"
expect_detect "MSYS after a real HTML tag <code>" "see <code>/c/Users/nire" "[msys-path]"
expect_detect "MSYS after an upper-case HTML tag <DIV>" "see <DIV>/c/Users/x" "[msys-path]"
expect_detect "MSYS after a real HTML tag <p>" "see <p>/c/Users/x" "[msys-path]"
expect_detect "MSYS after a real HTML tag <h1>" "see <h1>/c/Users/x" "[msys-path]"
expect_clean "MSYS placeholder <path> is not the tag <p>" "see <path>${PH_X}/y.txt"
expect_clean "MSYS placeholder <bx> is not the tag <b>" "see <bx>${PH_X}/y.txt"
expect_clean "MSYS placeholder <h7> is not the tag <h1>" "see <h7>${PH_X}/y.txt"
expect_clean "MSYS placeholder <my-dir>" "see <my-dir>${PH_X}/y.txt"
expect_clean "MSYS placeholder <a.b>" "see <a.b>${PH_X}/y.txt"
expect_clean "MSYS placeholder <DIR>" "see <DIR>${PH_X}/y.txt"
# Every allowlisted HTML tag keeps the path after it reported (MSYS and WSL); dropping one tag from the allowlist fails here.
for tag in div br code span p a b i em pre li ul ol td tr th table h1 h2 h3 h4 h5 h6 img hr; do
    expect_detect "MSYS after HTML tag <${tag}>" "see <${tag}>/c/Users/x" "[msys-path]"
    expect_detect "WSL after HTML tag <${tag}>" "see <${tag}>/mnt/c/Users/x" "[wsl-path]"
done
# Regex boundary: a name must start with a letter or underscore, and a closing tag is no placeholder.
expect_detect "MSYS after <1x> (digit start is no placeholder)" "see <1x>/c/Users/x" "[msys-path]"
expect_detect "MSYS after <> (empty is no placeholder)" "see <>/c/Users/x" "[msys-path]"
expect_detect "MSYS after </div> (closing tag)" "see </div>/c/Users/x" "[msys-path]"
expect_clean "MSYS placeholder <_x> (underscore start)" "see <_x>${PH_X}/y.txt"
expect_clean "WSL placeholder <path>" "see <path>/mnt/c/data.txt"

echo ""
echo "=== Scanner: WSL Paths ==="

expect_detect "WSL /mnt/c/Users/test" "cat /mnt/c/Users/test" "[wsl-path]"
expect_detect "WSL /mnt/d/data" "ls /mnt/d/data/file.txt" "[wsl-path]"
expect_detect "WSL embedded in string" "path=/mnt/c/Users/test" "[wsl-path]"
expect_clean "WSL placeholder <dir>/mnt/c/data.txt" "see <dir>/mnt/c/data.txt"
expect_detect "WSL right after a redirect" "cat >/mnt/c/Users/test" "[wsl-path]"
expect_detect "WSL after a placeholder and a space" "<x> /mnt/c/Users/test" "[wsl-path]"
expect_detect "WSL with a placeholder elsewhere on the line" "ls /mnt/c/Users/y; echo <x>" "[wsl-path]"
expect_detect "WSL after <b > (a space inside is no placeholder)" "a <b >/mnt/c/Users/x" "[wsl-path]"
expect_detect "WSL after a real HTML tag <div>" "x <div>/mnt/c/Users/test" "[wsl-path]"
expect_detect "WSL after a real HTML tag <code>" "x <code>/mnt/c/Users/test" "[wsl-path]"
expect_detect "WSL after an upper-case HTML tag <DIV>" "x <DIV>/mnt/c/Users/test" "[wsl-path]"

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
