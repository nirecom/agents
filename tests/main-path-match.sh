#!/bin/bash
# Tests: hooks/lib/path-match.js
# Tags: hook, bin, macos, tests
# Unit tests for new functions in hooks/lib/path-match.js:
#   - expandHomeAndEnvVars(p)
#   - isUnderAnyRoot(p, roots, extraLiteralRoots)
#   - globMatchesUnder(pattern, roots)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DOTFILES_DIR/hooks/lib/path-match.js"
ERRORS=0

# Portable timeout wrapper (macOS-compatible).
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

assert_true() {
    local desc="$1" result="$2"
    if [ "$result" = "true" ]; then
        pass "$desc"
    else
        fail "$desc — expected true, got: $result"
    fi
}

assert_false() {
    local desc="$1" result="$2"
    if [ "$result" = "false" ]; then
        pass "$desc"
    else
        fail "$desc — expected false, got: $result"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — expected '$expected', got '$actual'"
    fi
}

# Helpers that invoke a JS expression. The script loads path-match.js, evaluates
# the expression, and prints the result.
# Pass LIB as process.argv[2] so bash converts the POSIX path to a Windows path
# before Node.js receives it (avoids /c/git/... vs C:/git/... mismatch on Windows).
js_eval() {
    local expr="$1"
    run_with_timeout node - "$LIB" <<EOF
const pm = require(process.argv[2]);
const os = require('os');
const HOME = os.homedir().replace(/\\\\/g, '/');
const out = ($expr);
process.stdout.write(String(out));
EOF
}

echo "=== expandHomeAndEnvVars ==="

# 1. tilde alone
result=$(js_eval "pm.expandHomeAndEnvVars('~') === HOME")
assert_true "tilde alone expands to OS homedir" "$result"

# 2. tilde slash
result=$(js_eval "pm.expandHomeAndEnvVars('~/.ssh/id_rsa') === (HOME + '/.ssh/id_rsa')")
assert_true "'~/.ssh/id_rsa' expands to home/.ssh/id_rsa" "$result"

# 3. $HOME prefix
result=$(js_eval "pm.expandHomeAndEnvVars('\$HOME/.ssh/id_rsa') === (HOME + '/.ssh/id_rsa')")
assert_true "\$HOME prefix expands to home" "$result"

# 4. ${HOME} prefix
result=$(js_eval "pm.expandHomeAndEnvVars('\${HOME}/.ssh/id_rsa') === (HOME + '/.ssh/id_rsa')")
assert_true "\${HOME} prefix expands to home" "$result"

# 5. absolute path unchanged
result=$(js_eval "pm.expandHomeAndEnvVars('/etc/passwd')")
assert_eq "absolute path unchanged" "/etc/passwd" "$result"

# 6. empty string
result=$(js_eval "pm.expandHomeAndEnvVars('') === ''")
assert_true "empty string returns empty string" "$result"

# 7. $HOMEX not expanded (regex anchoring — $HOME must not greedily match $HOMEX)
result=$(js_eval "pm.expandHomeAndEnvVars('\$HOMEX/foo')")
assert_eq "\$HOMEX is not expanded (anchoring)" '$HOMEX/foo' "$result"

echo ""
echo "=== isUnderAnyRoot ==="

# 1. $HOME form, root ~/.ssh → true
result=$(js_eval "pm.isUnderAnyRoot('\$HOME/.ssh/id_rsa', ['~/.ssh'])")
assert_true "\$HOME form is under ~/.ssh" "$result"

# 2. ${HOME} form, root ~/.ssh → true
result=$(js_eval "pm.isUnderAnyRoot('\${HOME}/.ssh/id_rsa', ['~/.ssh'])")
assert_true "\${HOME} form is under ~/.ssh" "$result"

# 3. /root/.ssh with extraLiteralRoots → true
result=$(js_eval "pm.isUnderAnyRoot('/root/.ssh/id_rsa', ['~/.ssh'], ['/root/.ssh'])")
assert_true "/root/.ssh with extraLiteralRoots matches" "$result"

# 4. /root/.ssh WITHOUT extras → false (security: extra roots matter)
result=$(js_eval "pm.isUnderAnyRoot('/root/.ssh/id_rsa', ['~/.ssh'])")
assert_false "/root/.ssh WITHOUT extras does not match" "$result"

# 5. dot-segment '~/./.ssh/id_rsa' → true (path.posix.normalize resolves /./)
result=$(js_eval "pm.isUnderAnyRoot('~/./.ssh/id_rsa', ['~/.ssh'])")
assert_true "'~/./.ssh/id_rsa' normalizes to root" "$result"

# 6. ..-traversal SECURITY-CRITICAL — '~/x/../.ssh/id_rsa' normalizes to '~/.ssh/id_rsa' → TRUE
result=$(js_eval "pm.isUnderAnyRoot('~/x/../.ssh/id_rsa', ['~/.ssh'])")
assert_true "'~/x/../.ssh/id_rsa' normalizes into root (SECURITY-CRITICAL)" "$result"

# 7. ..-traversal escaping root '~/.ssh/../other/file' → FALSE
result=$(js_eval "pm.isUnderAnyRoot('~/.ssh/../other/file', ['~/.ssh'])")
assert_false "'~/.ssh/../other/file' normalizes away from root" "$result"

# 8. exact-match single-file root '~/.git-credentials' vs ['~/.git-credentials'] → true
result=$(js_eval "pm.isUnderAnyRoot('~/.git-credentials', ['~/.git-credentials'])")
assert_true "exact-match single-file root" "$result"

# 9. sibling '~/.ssh2/id_rsa' vs ['~/.ssh'] → false (no prefix match)
result=$(js_eval "pm.isUnderAnyRoot('~/.ssh2/id_rsa', ['~/.ssh'])")
assert_false "sibling '~/.ssh2' is not under '~/.ssh'" "$result"

echo ""
echo "=== globMatchesUnder ==="

# 1. '~/.ssh/**' vs ['~/.ssh'] → true
result=$(js_eval "pm.globMatchesUnder('~/.ssh/**', ['~/.ssh'])")
assert_true "'~/.ssh/**' matches root '~/.ssh'" "$result"

# 2. '**/.ssh/id_rsa' vs ['~/.ssh'] → true
result=$(js_eval "pm.globMatchesUnder('**/.ssh/id_rsa', ['~/.ssh'])")
assert_true "'**/.ssh/id_rsa' matches root '~/.ssh' via tail" "$result"

# 3. '~/x/../.ssh/**' vs ['~/.ssh'] → true (literal /.ssh/ substring present)
result=$(js_eval "pm.globMatchesUnder('~/x/../.ssh/**', ['~/.ssh'])")
assert_true "'~/x/../.ssh/**' matches via literal /.ssh/ substring" "$result"

# 4. '**/*.js' vs ['~/.ssh', '~/.aws'] → false
result=$(js_eval "pm.globMatchesUnder('**/*.js', ['~/.ssh', '~/.aws'])")
assert_false "'**/*.js' does not match credential roots" "$result"

# 5. empty pattern → false
result=$(js_eval "pm.globMatchesUnder('', ['~/.ssh'])")
assert_false "empty pattern does not match" "$result"

# Two-component needle behavior for multi-level roots (#536/#537/#539):
# Roots like '~/.config/gh' must use '.config/gh' as needle (not '.config'),
# so '~/.config/nvim/**' does NOT falsely match '~/.config/gh'.

# 6. false-positive regression: ~/.config/nvim/init.lua vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('~/.config/nvim/init.lua', ['~/.config/gh'])")
assert_false "'~/.config/nvim/init.lua' does NOT match '~/.config/gh'" "$result"

# 7. false-positive regression: ~/.config/nvim/** vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('~/.config/nvim/**', ['~/.config/gh'])")
assert_false "'~/.config/nvim/**' does NOT match '~/.config/gh'" "$result"

# 8. false-positive regression: ~/.config/htop/htoprc vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('~/.config/htop/htoprc', ['~/.config/gh'])")
assert_false "'~/.config/htop/htoprc' does NOT match '~/.config/gh'" "$result"

# 9. false-positive regression: **/.config/nvim/init.lua vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('**/.config/nvim/init.lua', ['~/.config/gh'])")
assert_false "'**/.config/nvim/init.lua' does NOT match '~/.config/gh'" "$result"

# 10. positive: ~/.config/gh/hosts.yml vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('~/.config/gh/hosts.yml', ['~/.config/gh'])")
assert_true "'~/.config/gh/hosts.yml' matches root '~/.config/gh'" "$result"

# 11. positive: ~/.config/gh/** vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('~/.config/gh/**', ['~/.config/gh'])")
assert_true "'~/.config/gh/**' matches root '~/.config/gh'" "$result"

# 12. positive: **/.config/gh/hosts.yml vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('**/.config/gh/hosts.yml', ['~/.config/gh'])")
assert_true "'**/.config/gh/hosts.yml' matches root '~/.config/gh' via tail" "$result"

# 13. positive: ~/.config/gcloud/credentials.db vs ['~/.config/gcloud']
result=$(js_eval "pm.globMatchesUnder('~/.config/gcloud/credentials.db', ['~/.config/gcloud'])")
assert_true "'~/.config/gcloud/credentials.db' matches root '~/.config/gcloud'" "$result"

# 14. positive: ~/.config/op/config vs ['~/.config/op']
result=$(js_eval "pm.globMatchesUnder('~/.config/op/config', ['~/.config/op'])")
assert_true "'~/.config/op/config' matches root '~/.config/op'" "$result"

# 15. cross-root isolation: ~/.config/gcloud/credentials.db vs ['~/.config/gh']
result=$(js_eval "pm.globMatchesUnder('~/.config/gcloud/credentials.db', ['~/.config/gh'])")
assert_false "'~/.config/gcloud/credentials.db' does NOT match '~/.config/gh'" "$result"

# 16. extraLiteralRoots /root/ coverage (positive via two-component needle)
result=$(js_eval "pm.globMatchesUnder('/root/.config/gh/hosts.yml', ['/root/.config/gh'])")
assert_true "'/root/.config/gh/hosts.yml' matches literal root '/root/.config/gh'" "$result"

# 17. extraLiteralRoots /root/ isolation (negative)
result=$(js_eval "pm.globMatchesUnder('/root/.config/nvim/init.lua', ['/root/.config/gh'])")
assert_false "'/root/.config/nvim/init.lua' does NOT match '/root/.config/gh'" "$result"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
