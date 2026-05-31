#!/bin/bash
# Integration tests for hooks/block-history-direct.js PreToolUse hook.
# Blocks direct Write/Edit/MultiEdit/editFiles on docs/history.md and CHANGELOG.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/block-history-direct.js"
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

echo "=== block-history-direct: protected file writes (should block) ==="

# B1: Edit docs/history.md (relative) → block
expect_block "B1: Edit docs/history.md (relative)" \
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/history.md","old_string":"a","new_string":"b"}}'

# B2: Edit absolute path ending in history.md → block
expect_block "B2: Edit /repo/docs/history.md (absolute)" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/repo/docs/history.md","old_string":"a","new_string":"b"}}'

# B3: Write CHANGELOG.md → block
expect_block "B3: Write CHANGELOG.md" \
    '{"tool_name":"Write","tool_input":{"file_path":"CHANGELOG.md","content":"x"}}'

# B4: Edit docs/CHANGELOG.md → block (basename match)
expect_block "B4: Edit docs/CHANGELOG.md" \
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/CHANGELOG.md","old_string":"a","new_string":"b"}}'

# B5: MultiEdit docs/history.md → block
expect_block "B5: MultiEdit docs/history.md" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"docs/history.md","edits":[]}}'

# B6: editFiles on docs/history.md → block
expect_block "B6: editFiles docs/history.md" \
    '{"tool_name":"editFiles","tool_input":{"file_path":"docs/history.md"}}'

echo ""
echo "=== block-history-direct: allowed cases (should approve) ==="

# B7: Read docs/history.md → approve (hook scoped to write tools)
expect_approve "B7: Read docs/history.md" \
    '{"tool_name":"Read","tool_input":{"file_path":"docs/history.md"}}'

# B8: Bash tool with doc-append → approve (no redirect/tee/cmdlet target)
expect_approve "B8: Bash doc-append docs/history.md" \
    '{"tool_name":"Bash","tool_input":{"command":"doc-append docs/history.md --category FEATURE --background x --changes y"}}'

# B8a: Bash echo redirect into history.md → block
expect_block "B8a: Bash echo >> docs/history.md" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> docs/history.md"}}'

# B8b: Bash tee -a CHANGELOG.md → block
expect_block "B8b: Bash tee -a CHANGELOG.md" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo | tee -a CHANGELOG.md"}}'

# B8c: Bash cp src docs/history.md → block (destination match)
expect_block "B8c: Bash cp src docs/history.md" \
    '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/draft.md docs/history.md"}}'

# B8d: Bash PowerShell Add-Content -Path CHANGELOG.md → block
expect_block "B8d: Bash Add-Content -Path CHANGELOG.md" \
    '{"tool_name":"Bash","tool_input":{"command":"Add-Content -Path CHANGELOG.md -Value foo"}}'

# B8e: Bash redirect to unrelated file → approve
expect_approve "B8e: Bash echo >> notes.md" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> notes.md"}}'

# B8f: Bash cat docs/history.md (read, no write target) → approve
expect_approve "B8f: Bash cat docs/history.md" \
    '{"tool_name":"Bash","tool_input":{"command":"cat docs/history.md"}}'

# B9: Edit docs/history/2025.md → approve (different basename, archive file)
expect_approve "B9: Edit docs/history/2025.md (archive)" \
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/history/2025.md","old_string":"a","new_string":"b"}}'

# B10: Edit docs/history-notes.md → approve (suffix match would be wrong)
expect_approve "B10: Edit docs/history-notes.md" \
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/history-notes.md","old_string":"a","new_string":"b"}}'

# B11: Edit docs/some-history.md → approve (not exact basename)
expect_approve "B11: Edit docs/some-history.md" \
    '{"tool_name":"Edit","tool_input":{"file_path":"docs/some-history.md","old_string":"a","new_string":"b"}}'

# B12: Malformed JSON on stdin → approve (fail-open)
expect_approve "B12: malformed JSON" \
    'NOT JSON AT ALL'

# B12a: JSON null on stdin → approve (null-input guard)
expect_approve "B12a: JSON null" \
    'null'

# B13: Unknown tool_name → approve
expect_approve "B13: unknown tool (Task)" \
    '{"tool_name":"Task","tool_input":{"file_path":"docs/history.md"}}'

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
