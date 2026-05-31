#!/bin/bash
# Test suite for check-tests-updated.js PreToolUse hook
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/claude-global/hooks/check-tests-updated.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# --- Unit tests: non-commit commands (no git repo needed) ---

run_hook() {
    local json="$1"
    echo "$json" | node "$HOOK" 2>/dev/null
}

expect_approve() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

expect_block() {
    local desc="$1" json="$2"
    local result
    result=$(run_hook "$json")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

echo "=== Non-commit commands (should approve) ==="
expect_approve "git status" '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
expect_approve "git push" '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
expect_approve "git diff" '{"tool_name":"Bash","tool_input":{"command":"git diff"}}'
expect_approve "ls command" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
expect_approve "non-Bash tool" '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'

echo ""
echo "=== Edge cases ==="
expect_approve "missing tool_input" '{"tool_name":"Bash"}'
expect_approve "empty command" '{"tool_name":"Bash","tool_input":{"command":""}}'
expect_approve "invalid JSON" 'NOT JSON'

# --- Integration tests: real git repo with staging ---

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo/docs" "$repo/src" "$repo/tests"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    echo "test" > "$repo/tests/test.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "initial"
    # Create review marker so stage-2 (review check) doesn't interfere
    local gitdir
    gitdir=$(git -C "$repo" rev-parse --git-dir)
    local head
    head=$(git -C "$repo" rev-parse --short HEAD)
    echo "$head" > "$repo/$gitdir/.test-reviewed"
    echo "$repo"
}

run_hook_in_repo() {
    local repo="$1" json="$2"
    echo "$json" | HOOK_CWD="$repo" node "$HOOK" 2>/dev/null
}

expect_block_repo() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_hook_in_repo "$repo" "$json")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

expect_approve_repo() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_hook_in_repo "$repo" "$json")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"update\""}}'

echo ""
echo "=== Integration: code change without tests (should block) ==="
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_block_repo "src change, no tests staged" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: code change with tests (should approve) ==="
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
echo "updated" >> "$REPO/tests/test.sh"
git -C "$REPO" add src/app.js tests/test.sh
# Need fresh review marker for new HEAD
local_head=$(git -C "$REPO" rev-parse --short HEAD)
local_gitdir=$(git -C "$REPO" rev-parse --git-dir)
echo "$local_head" > "$REPO/$local_gitdir/.test-reviewed"
expect_approve_repo "src + tests staged" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: docs-only change (should approve) ==="
REPO=$(setup_repo)
echo "updated" >> "$REPO/docs/history.md"
git -C "$REPO" add docs/history.md
expect_approve_repo "docs-only change" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: config-only change (should approve) ==="
REPO=$(setup_repo)
echo "setting" > "$REPO/.gitignore"
git -C "$REPO" add .gitignore
expect_approve_repo "config-only (exempt file)" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: .config/ dir change (should approve) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/.config/git"
echo "config-work" >> "$REPO/.config/git/ignore"
git -C "$REPO" add .config/git/ignore
expect_approve_repo ".config/git/ignore — exempt dir" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: nothing staged (should approve) ==="
REPO=$(setup_repo)
expect_approve_repo "nothing staged" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: .md file outside docs (should approve — not code) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/projects/engineering"
echo "spec" > "$REPO/projects/engineering/architecture.md"
git -C "$REPO" add projects/engineering/architecture.md
expect_approve_repo "md outside docs — single file" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: multiple .md files across dirs (should approve) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/projects/engineering/langchain" "$REPO/notes"
echo "ops" > "$REPO/projects/engineering/langchain/ops.md"
echo "todo" > "$REPO/projects/engineering/todo.md"
echo "note" > "$REPO/notes/meeting.md"
git -C "$REPO" add projects/ notes/
expect_approve_repo "md outside docs — multiple dirs" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: .md + real code without tests (should block) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/projects"
echo "spec" > "$REPO/projects/spec.md"
echo "code" > "$REPO/src/app.js"
git -C "$REPO" add projects/spec.md src/app.js
expect_block_repo "md + code, no tests" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: .md + real code + tests (should approve) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/projects"
echo "spec" > "$REPO/projects/spec.md"
echo "code" > "$REPO/src/app.js"
echo "updated" >> "$REPO/tests/test.sh"
git -C "$REPO" add projects/spec.md src/app.js tests/test.sh
local_head=$(git -C "$REPO" rev-parse --short HEAD)
local_gitdir=$(git -C "$REPO" rev-parse --git-dir)
echo "$local_head" > "$REPO/$local_gitdir/.test-reviewed"
expect_approve_repo "md + code + tests" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: deeply nested .md (should approve) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/projects/engineering/langchain/architecture"
echo "detail" > "$REPO/projects/engineering/langchain/architecture/overview.md"
git -C "$REPO" add projects/
expect_approve_repo "deeply nested md" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: git -C path commit (should detect and block) ==="
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
expect_block_repo "git -C commit" "$REPO" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO commit -m \\\"update\\\"\"}}"

echo ""
echo "=== Integration: uppercase .MD extension (should approve — not code) ==="
REPO=$(setup_repo)
mkdir -p "$REPO/projects"
echo "spec" > "$REPO/projects/DESIGN.MD"
git -C "$REPO" add projects/DESIGN.MD
expect_approve_repo "uppercase .MD extension" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Integration: idempotency — repeated hook calls produce same result ==="
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
git -C "$REPO" add src/app.js
result1=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
result2=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
if [ "$result1" = "$result2" ]; then pass "idempotent block"
else fail "idempotent block — results differ: $result1 vs $result2"; fi

REPO=$(setup_repo)
mkdir -p "$REPO/projects"
echo "doc" > "$REPO/projects/notes.md"
git -C "$REPO" add projects/notes.md
result1=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
result2=$(run_hook_in_repo "$REPO" "$COMMIT_JSON")
if [ "$result1" = "$result2" ]; then pass "idempotent approve"
else fail "idempotent approve — results differ: $result1 vs $result2"; fi

echo ""
echo "=== Integration: stale review marker (should block) ==="
REPO=$(setup_repo)
echo "new code" > "$REPO/src/app.js"
echo "updated" >> "$REPO/tests/test.sh"
git -C "$REPO" add src/app.js tests/test.sh
# Write a stale marker (wrong hash)
local_gitdir=$(git -C "$REPO" rev-parse --git-dir)
echo "0000000" > "$REPO/$local_gitdir/.test-reviewed"
expect_block_repo "stale review marker" "$REPO" "$COMMIT_JSON"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
