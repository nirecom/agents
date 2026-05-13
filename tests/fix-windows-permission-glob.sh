#!/bin/bash
# tests/fix-windows-permission-glob.sh
#
# Tests for:
#   - hooks/lib/path-match.js (path utility library)
#   - hooks/approve-plan-writes.js (PreToolUse hook approving writes to ~/.claude/plans/)
#   - settings.json registration / ordering of approve-plan-writes.js

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
HOOK="${_AGENTS_DIR_NODE}/hooks/approve-plan-writes.js"
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
    r="$(is_under "${NODE_HOME}/.claude/plans/foo.md" "${NODE_HOME}/.claude/plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: file directly under plans -> true"
    else
        fail "isUnderPath file under plans: expected 'true', got '$r'"
    fi
}

test_isunder_deeply_nested() {
    local r
    r="$(is_under "${NODE_HOME}/.claude/plans/drafts/sub/x.md" "${NODE_HOME}/.claude/plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: deeply nested -> true"
    else
        fail "isUnderPath nested: expected 'true', got '$r'"
    fi
}

test_isunder_exact_match() {
    local r
    r="$(is_under "${NODE_HOME}/.claude/plans" "${NODE_HOME}/.claude/plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: exact match -> true"
    else
        fail "isUnderPath exact: expected 'true', got '$r'"
    fi
}

test_isunder_both_tilde() {
    local r
    r="$(is_under "~/.claude/plans/foo.md" "~/.claude/plans")"
    if [ "$r" = "true" ]; then
        pass "isUnderPath: both tilde-form -> true"
    else
        fail "isUnderPath both tilde: expected 'true', got '$r'"
    fi
}

test_isunder_not_under() {
    local r
    r="$(is_under "${NODE_HOME}/.claude/settings.json" "${NODE_HOME}/.claude/plans")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: not under plans -> false"
    else
        fail "isUnderPath not under: expected 'false', got '$r'"
    fi
}

test_isunder_sibling_dir() {
    # ~/.claude/plans-archive is NOT under ~/.claude/plans (must require trailing slash boundary)
    local r
    r="$(is_under "${NODE_HOME}/.claude/plans-archive/x.md" "${NODE_HOME}/.claude/plans")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: sibling dir (plans-archive) -> false"
    else
        fail "isUnderPath sibling: expected 'false', got '$r'"
    fi
}

test_isunder_empty_p() {
    local r
    r="$(is_under "" "${NODE_HOME}/.claude/plans")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: empty p -> false"
    else
        fail "isUnderPath empty p: expected 'false', got '$r'"
    fi
}

test_isunder_empty_prefix() {
    local r
    r="$(is_under "${NODE_HOME}/.claude/plans/foo.md" "")"
    if [ "$r" = "false" ]; then
        pass "isUnderPath: empty prefix -> false"
    else
        fail "isUnderPath empty prefix: expected 'false', got '$r'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# approve-plan-writes.js integration tests
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== approve-plan-writes.js: integration ==="

PLANS_DIR="${NODE_HOME}/.claude/plans"

run_hook() {
    echo "$1" | run_with_timeout node "$HOOK" 2>/dev/null
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

expect_approve "Write to ${PLANS_DIR}/foo.md" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}/foo.md\",\"content\":\"x\"}}"

expect_approve "Write to ${PLANS_DIR}/drafts/bar.md" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}/drafts/bar.md\",\"content\":\"x\"}}"

expect_approve "Edit to ${PLANS_DIR}/foo.md" \
    "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}/foo.md\",\"old_string\":\"a\",\"new_string\":\"b\"}}"

expect_approve "MultiEdit to ${PLANS_DIR}/foo.md" \
    "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}/foo.md\",\"edits\":[]}}"

expect_approve "Write to non-plans path (fallthrough)" \
    '{"tool_name":"Write","tool_input":{"file_path":"/tmp/somefile.txt","content":"x"}}'

expect_approve "Edit to home dir but NOT under plans" \
    "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${NODE_HOME}/.claude/settings.json\",\"old_string\":\"a\",\"new_string\":\"b\"}}"

expect_approve "Bash tool (unmatched)" \
    '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

expect_approve "Read tool (unmatched)" \
    '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}'

expect_approve "malformed JSON (fail-open)" \
    'NOT JSON AT ALL'

expect_approve "missing tool_input" \
    '{"tool_name":"Write"}'

expect_approve "missing file_path" \
    '{"tool_name":"Write","tool_input":{"content":"x"}}'

expect_approve "path-traversal through plans dir (documented behavior)" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${PLANS_DIR}/../../etc/passwd\",\"content\":\"x\"}}"

# ─────────────────────────────────────────────────────────────────────────────
# settings.json static tests
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== settings.json: registration & ordering ==="

test_registered() {
    if grep -q "approve-plan-writes.js" "$SETTINGS_FILE"; then
        pass "approve-plan-writes.js is registered in settings.json"
    else
        fail "approve-plan-writes.js NOT registered in settings.json"
    fi
}

test_matcher_includes_write() {
    # Find the hook block containing approve-plan-writes.js and inspect matcher.
    local r
    r="$(run_with_timeout node -e "
        const fs=require('fs');
        const j=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
        const pre=(j.hooks && j.hooks.PreToolUse) || [];
        let found=null;
        for (const block of pre) {
            for (const h of (block.hooks||[])) {
                if (h.command && h.command.includes('approve-plan-writes.js')) { found=block.matcher; break; }
            }
            if (found) break;
        }
        process.stdout.write(found || '');
    " -- "$SETTINGS_FILE")"
    if echo "$r" | grep -q "Write"; then
        pass "matcher includes Write: '$r'"
    else
        fail "matcher missing Write: '$r'"
    fi
}

test_ordering() {
    local show_diff_line approve_line block_tests_line
    show_diff_line="$(grep -n "show-diff.js" "$SETTINGS_FILE" | head -1 | cut -d: -f1)"
    approve_line="$(grep -n "approve-plan-writes.js" "$SETTINGS_FILE" | head -1 | cut -d: -f1)"
    block_tests_line="$(grep -n "block-tests-direct.js" "$SETTINGS_FILE" | head -1 | cut -d: -f1)"

    if [ -z "$show_diff_line" ] || [ -z "$approve_line" ] || [ -z "$block_tests_line" ]; then
        fail "ordering: missing one of the hook entries (show-diff=$show_diff_line, approve=$approve_line, block-tests=$block_tests_line)"
        return
    fi

    if [ "$approve_line" -gt "$show_diff_line" ] && [ "$approve_line" -lt "$block_tests_line" ]; then
        pass "ordering: show-diff($show_diff_line) < approve-plan-writes($approve_line) < block-tests-direct($block_tests_line)"
    else
        fail "ordering wrong: show-diff=$show_diff_line, approve=$approve_line, block-tests=$block_tests_line"
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

test_registered
test_matcher_includes_write
test_ordering

echo ""
echo "─────────────────────────────────────────"
echo "Platform: $NODE_PLATFORM"
echo "NODE_HOME: $NODE_HOME"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
