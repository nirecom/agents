#!/usr/bin/env bash
# Tests for workflow-gate.js commit detection regex
# Tests the FIXED regex: /^git\s+(?:-C\s+\S+\s+)?commit\s/
# (current source lacks ^ anchor, so bug regression cases will fail on unpatched source)

ERRORS=0

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
}

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Run a single regex test case via Node.js inline
# Usage: check_match <description> <command_string> <expected: match|no-match>
check_match() {
    local desc="$1"
    local cmd="$2"
    local expected="$3"

    local result
    result=$(run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = $(node -e "process.stdout.write(JSON.stringify('$cmd'))");
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")

    if [ "$result" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (expected=$expected, got=$result)"
    fi
}

# Use a helper that properly handles the command string via stdin to avoid quoting issues
check_match_raw() {
    local desc="$1"
    local expected="$3"

    local result
    result=$(run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
" TEST_CMD="$2")

    if [ "$result" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (expected=$expected, got=$result)"
    fi
}

echo "=== workflow-gate.js commit regex tests ==="
echo "Testing fixed regex: /^git\s+(?:-C\s+\S+\s+)?commit\s/"
echo ""

# Normal 1: simple git commit
TEST_CMD='git commit -m "msg"'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "match" ] && pass "Normal 1: git commit -m \"msg\"" || fail "Normal 1: git commit -m \"msg\" (expected=match, got=$result)"

# Normal 2: git -C /path/repo commit
TEST_CMD='git -C /path/repo commit -m "msg"'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "match" ] && pass "Normal 2: git -C /path/repo commit -m \"msg\"" || fail "Normal 2: git -C /path/repo commit -m \"msg\" (expected=match, got=$result)"

# Bug regression 1: uv run with "git commit" in argument
TEST_CMD='uv run bin/doc-append.py --background "git commit blocked"'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "no-match" ] && pass "Bug regression 1: uv run with 'git commit' in argument" || fail "Bug regression 1: uv run with 'git commit' in argument (expected=no-match, got=$result)"

# Bug regression 2: echo "git commit message"
TEST_CMD='echo "git commit message"'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "no-match" ] && pass "Bug regression 2: echo \"git commit message\"" || fail "Bug regression 2: echo \"git commit message\" (expected=no-match, got=$result)"

# Normal 3: git status (should not match)
TEST_CMD='git status'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "no-match" ] && pass "Normal 3: git status (no match)" || fail "Normal 3: git status (expected=no-match, got=$result)"

# Edge 1: leading spaces before git commit
TEST_CMD='  git commit -m "msg"'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "no-match" ] && pass "Edge 1: leading spaces before git commit (no match due to ^ anchor)" || fail "Edge 1: leading spaces before git commit (expected=no-match, got=$result)"

# Normal 4: git -C with Windows path
TEST_CMD='git -C c:\git\dotfiles commit -m "msg"'
result=$(TEST_CMD="$TEST_CMD" run_with_timeout node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
const command = process.env.TEST_CMD;
const matched = regex.test(command);
process.stdout.write(matched ? 'match' : 'no-match');
")
[ "$result" = "match" ] && pass "Normal 4: git -C c:\\git\\dotfiles commit -m \"msg\" (Windows path)" || fail "Normal 4: git -C Windows path (expected=match, got=$result)"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
