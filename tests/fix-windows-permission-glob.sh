#!/bin/bash
# tests/fix-windows-permission-glob.sh
# Tests: bin/node, hooks/lib/path-match.js
# Tags: settings, config, hook, bin, windows
#
# Tests for:
#   - hooks/lib/path-match.js (path utility library)

set -u

# Disable MSYS/Git-Bash argv & env path conversion. Without this, POSIX-looking
# argv (e.g., "/usr/local/bin") and env values are auto-rewritten to Windows
# paths before reaching the native node.exe binary.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
PM_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/path-match.js"
SETTINGS_FILE="${_AGENTS_DIR_NODE}/settings.json"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Get the node-visible home directory (forward slashes)
NODE_HOME="$(run_with_timeout node -e "process.stdout.write(require('os').homedir().replace(/\\\\/g,'/'))")"
NODE_PLATFORM="$(run_with_timeout node -e "process.stdout.write(process.platform)")"

# ─────────────────────────────────────────────────────────────────────────────
# path-match.js unit tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== path-match.js: normalizeSlashes ==="

test_normalize_posix_unchanged() {
    # NOTE: MSYS/Git-Bash converts POSIX-looking argv to Windows paths.
    # Pass via env to bypass argv path conversion.
    local r
    r="$(TEST_INPUT="/usr/local/bin" run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.normalizeSlashes(process.env.TEST_INPUT))")"
    if [ "$r" = "/usr/local/bin" ]; then
        pass "normalizeSlashes: POSIX unchanged"
    else
        fail "normalizeSlashes POSIX: expected '/usr/local/bin', got '$r'"
    fi
}

test_normalize_windows_to_forward() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.normalizeSlashes(process.argv[1]))" -- "C:\\Users\\test\\file.txt")"
    if [ "$r" = "C:/Users/test/file.txt" ]; then
        pass "normalizeSlashes: Windows backslashes -> forward"
    else
        fail "normalizeSlashes Windows: expected 'C:/Users/test/file.txt', got '$r'"
    fi
}

test_normalize_mixed() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.normalizeSlashes(process.argv[1]))" -- "C:/Users\\mix/path")"
    if [ "$r" = "C:/Users/mix/path" ]; then
        pass "normalizeSlashes: mixed separators normalized"
    else
        fail "normalizeSlashes mixed: expected 'C:/Users/mix/path', got '$r'"
    fi
}

test_normalize_empty() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.normalizeSlashes(''))")"
    if [ "$r" = "" ]; then
        pass "normalizeSlashes: empty string -> empty"
    else
        fail "normalizeSlashes empty: expected '', got '$r'"
    fi
}

test_normalize_null() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); try { process.stdout.write(String(m.normalizeSlashes(null))); } catch(e) { process.stdout.write('THREW:'+e.message); }")"
    if [ "$r" = "" ]; then
        pass "normalizeSlashes: null -> '' (no throw)"
    else
        fail "normalizeSlashes null: expected '', got '$r'"
    fi
}

echo ""
echo "=== path-match.js: getBasename ==="

test_basename_posix() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.getBasename(process.argv[1]))" -- "/usr/local/file.txt")"
    if [ "$r" = "file.txt" ]; then
        pass "getBasename: POSIX file"
    else
        fail "getBasename POSIX: expected 'file.txt', got '$r'"
    fi
}

test_basename_windows() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.getBasename(process.argv[1]))" -- "C:\\Users\\test\\file.txt")"
    if [ "$r" = "file.txt" ]; then
        pass "getBasename: Windows path"
    else
        fail "getBasename Windows: expected 'file.txt', got '$r'"
    fi
}

test_basename_no_dirs() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.getBasename(process.argv[1]))" -- "file.txt")"
    if [ "$r" = "file.txt" ]; then
        pass "getBasename: no dirs"
    else
        fail "getBasename no-dirs: expected 'file.txt', got '$r'"
    fi
}

test_basename_empty() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.getBasename(''))")"
    if [ "$r" = "" ]; then
        pass "getBasename: empty -> empty"
    else
        fail "getBasename empty: expected '', got '$r'"
    fi
}

echo ""
echo "=== path-match.js: getPathSegments ==="

test_segments_posix_count() {
    # Use env to bypass MSYS argv path conversion.
    local r
    r="$(TEST_INPUT="/usr/local/bin/node" run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(String(m.getPathSegments(process.env.TEST_INPUT).length))")"
    if [ "$r" = "4" ]; then
        pass "getPathSegments: POSIX count 4"
    else
        fail "getPathSegments count: expected '4', got '$r'"
    fi
}

test_segments_last_element() {
    local r
    r="$(TEST_INPUT="/a/b/c" run_with_timeout node -e "const m=require('$PM_MODULE'); const s=m.getPathSegments(process.env.TEST_INPUT); process.stdout.write(s[s.length-1] || '')")"
    if [ "$r" = "c" ]; then
        pass "getPathSegments: last element"
    else
        fail "getPathSegments last: expected 'c', got '$r'"
    fi
}

test_segments_empty() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(String(m.getPathSegments('').length))")"
    if [ "$r" = "0" ]; then
        pass "getPathSegments: empty -> length 0"
    else
        fail "getPathSegments empty: expected '0', got '$r'"
    fi
}

echo ""
echo "=== path-match.js: expandHome ==="

test_expand_tilde_forward() {
    local r expected
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.expandHome(process.argv[1]))" -- "~/foo")"
    expected="${NODE_HOME}/foo"
    if [ "$r" = "$expected" ]; then
        pass "expandHome: ~/foo -> ${expected}"
    else
        fail "expandHome ~/foo: expected '$expected', got '$r'"
    fi
}

test_expand_tilde_backslash() {
    local r expected
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.expandHome(process.argv[1]))" -- "~\\foo")"
    expected="${NODE_HOME}/foo"
    if [ "$r" = "$expected" ]; then
        pass "expandHome: ~\\foo -> ${expected}"
    else
        fail "expandHome ~\\foo: expected '$expected', got '$r'"
    fi
}

test_expand_tilde_alone() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.expandHome(process.argv[1]))" -- "~")"
    if [ "$r" = "$NODE_HOME" ]; then
        pass "expandHome: '~' alone -> home"
    else
        fail "expandHome '~': expected '$NODE_HOME', got '$r'"
    fi
}

test_expand_absolute_unchanged() {
    local r
    r="$(TEST_INPUT="/etc/hosts" run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.expandHome(process.env.TEST_INPUT))")"
    if [ "$r" = "/etc/hosts" ]; then
        pass "expandHome: absolute path unchanged"
    else
        fail "expandHome absolute: expected '/etc/hosts', got '$r'"
    fi
}

test_expand_empty() {
    local r
    r="$(run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(m.expandHome(''))")"
    if [ "$r" = "" ]; then
        pass "expandHome: empty -> empty"
    else
        fail "expandHome empty: expected '', got '$r'"
    fi
}

echo ""
echo "=== path-match.js: isUnderPath ==="

is_under() {
    run_with_timeout node -e "const m=require('$PM_MODULE'); process.stdout.write(String(m.isUnderPath(process.argv[1],process.argv[2])))" -- "$1" "$2"
}

test_isunder_file_under_plans() {
    local r
    r="$(is_under "${NODE_HOME}/.workflow-plans/foo.md" "${NODE_HOME}/.workflow-plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: file directly under plans -> true"
    else
        fail "isUnderPath file under plans: expected 'true', got '$r'"
    fi
}

test_isunder_deeply_nested() {
    local r
    r="$(is_under "${NODE_HOME}/.workflow-plans/drafts/sub/x.md" "${NODE_HOME}/.workflow-plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: deeply nested -> true"
    else
        fail "isUnderPath nested: expected 'true', got '$r'"
    fi
}

test_isunder_exact_match() {
    local r
    r="$(is_under "${NODE_HOME}/.workflow-plans" "${NODE_HOME}/.workflow-plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: exact match -> true"
    else
        fail "isUnderPath exact: expected 'true', got '$r'"
    fi
}

test_isunder_both_tilde() {
    local r
    r="$(is_under "~/.workflow-plans/foo.md" "~/.workflow-plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: both tilde-form -> true"
    else
        fail "isUnderPath both tilde: expected 'true', got '$r'"
    fi
}

test_isunder_not_under() {
    local r
    r="$(is_under "${NODE_HOME}/.claude/settings.json" "${NODE_HOME}/.workflow-plans")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: not under plans -> false"
    else
        fail "isUnderPath not under: expected 'false', got '$r'"
    fi
}

test_isunder_sibling_dir() {
    # ~/.workflow-plans-archive is NOT under ~/.workflow-plans (must require trailing slash boundary)
    local r
    r="$(is_under "${NODE_HOME}/.workflow-plans-archive/x.md" "${NODE_HOME}/.workflow-plans")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: sibling dir (plans-archive) -> false"
    else
        fail "isUnderPath sibling: expected 'false', got '$r'"
    fi
}

test_isunder_empty_p() {
    local r
    r="$(is_under "" "${NODE_HOME}/.workflow-plans")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: empty p -> false"
    else
        fail "isUnderPath empty p: expected 'false', got '$r'"
    fi
}

test_isunder_empty_prefix() {
    local r
    r="$(is_under "${NODE_HOME}/.workflow-plans/foo.md" "")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: empty prefix -> false"
    else
        fail "isUnderPath empty prefix: expected 'false', got '$r'"
    fi
}


# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_normalize_posix_unchanged
test_normalize_windows_to_forward
test_normalize_mixed
test_normalize_empty
test_normalize_null

test_basename_posix
test_basename_windows
test_basename_no_dirs
test_basename_empty

test_segments_posix_count
test_segments_last_element
test_segments_empty

test_expand_tilde_forward
test_expand_tilde_backslash
test_expand_tilde_alone
test_expand_absolute_unchanged
test_expand_empty

test_isunder_file_under_plans
test_isunder_deeply_nested
test_isunder_exact_match
test_isunder_both_tilde
test_isunder_not_under
test_isunder_sibling_dir
test_isunder_empty_p
test_isunder_empty_prefix

echo ""
echo "─────────────────────────────────────────"
echo "Platform: $NODE_PLATFORM"
echo "NODE_HOME: $NODE_HOME"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
