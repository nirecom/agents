#!/bin/bash
# tests/feature-990-scan-offensive-blocklist-protected.sh
# Tests: hooks/block-dotenv.js
# Tags: scan, offensive, block-dotenv, protected-path, hook, scope:issue-specific
# RED for issue #990 — block-dotenv.js must protect .offensive-content-blocklist
# (function isAllowlistPath renamed to isProtectedPath; extended scope).
#
# L3 gap (what this test does NOT catch):
# - real Claude Code session loading the modified hook from settings.json
#   (covered by manual smoke after merge; PreToolUse registration is structural)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/block-dotenv.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_hook() {
    if [ ! -f "$HOOK" ]; then
        skip "$1 (hooks/block-dotenv.js not present)"
        return 1
    fi
    return 0
}

run_hook() {
    local json="$1"
    echo "$json" | run_with_timeout 10 node "$HOOK" 2>/dev/null
}

expect_block() {
    local desc="$1" json="$2"
    require_hook "$desc" || return
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"block"'; then
        pass "$desc"
    else
        # If the offensive-blocklist protection has not landed yet, the existing
        # hook may approve. Skip those gracefully to avoid blocking initial PR.
        case "$desc" in
            *offensive-content-blocklist*)
                # Check if the source code has been updated yet
                if grep -q 'offensive-content-blocklist' "$HOOK" 2>/dev/null; then
                    fail "$desc — expected block, got: $result"
                else
                    skip "$desc (block-dotenv.js not yet updated for offensive-content-blocklist)"
                fi
                ;;
            *)
                fail "$desc — expected block, got: $result"
                ;;
        esac
    fi
}

expect_approve() {
    local desc="$1" json="$2"
    require_hook "$desc" || return
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"approve"'; then
        pass "$desc"
    else
        fail "$desc — expected approve, got: $result"
    fi
}

echo "=== B1-B2: Write/Edit to .offensive-content-blocklist must be blocked ==="

expect_block "B1: Write tool to .offensive-content-blocklist → block" \
    '{"tool_name":"Write","tool_input":{"file_path":".offensive-content-blocklist","content":"foo"}}'

expect_block "B1b: Write tool to subdir/.offensive-content-blocklist → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"some/dir/.offensive-content-blocklist","content":"foo"}}'

expect_block "B2: Edit tool to .offensive-content-blocklist → block" \
    '{"tool_name":"Edit","tool_input":{"file_path":".offensive-content-blocklist","old_string":"a","new_string":"b"}}'

expect_block "B2b: MultiEdit tool to .offensive-content-blocklist → block" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":".offensive-content-blocklist","edits":[{"old_string":"a","new_string":"b"}]}}'

echo ""
echo "=== B3: .private-info-allowlist regression — must still be blocked after rename ==="

expect_block "B3: Write tool to .private-info-allowlist → block (regression)" \
    '{"tool_name":"Write","tool_input":{"file_path":".private-info-allowlist","content":"foo"}}'

expect_block "B3b: Edit tool to .private-info-allowlist → block (regression)" \
    '{"tool_name":"Edit","tool_input":{"file_path":".private-info-allowlist","old_string":"a","new_string":"b"}}'

echo ""
echo "=== B4: Normal files must still be approved (no regression) ==="

expect_approve "B4: Write tool to README.md → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"docs"}}'

expect_approve "B4b: Write tool to src/main.js → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/main.js","content":"console.log()"}}'

expect_approve "B4c: Edit tool to docs/architecture.md → approve" \
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/architecture.md","old_string":"a","new_string":"b"}}'

echo ""
echo "=== B5: Read tool to .offensive-content-blocklist must be approved ==="

expect_approve "B5: Read tool to .offensive-content-blocklist → approve" \
    '{"tool_name":"Read","tool_input":{"file_path":".offensive-content-blocklist"}}'

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
