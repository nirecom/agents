#!/bin/bash
# Tests: bin/github-issues/migration/migrate-history.sh, bin/github-issues/migration/migrate-todo.sh, bin/github-issues/migration/state.sh
# Tags: migration, repo, history, docs, todo
# Tests for feat/migrate-repo — canary flow across migrate-history.sh and migrate-todo.sh.
#
# Sequential canary calls share state across one fixture repo:
#   migrate-history --canary 1 → 1 issue, todo unchanged
#   migrate-history --canary 2 → cumulative 2, no dupes
#   migrate-history             → cumulative 6, no dupes
#   migrate-todo    --canary 1 → 1 todo issue, todo.md still unchanged
#   migrate-todo    --canary 2 → cumulative 2, todo.md still unchanged
#   migrate-todo                → cumulative 2, todo.md rewritten as ID index
#
# RED: fails clean while migrate-history.sh / migrate-todo.sh are missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HIST_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/migrate-history.sh"
TODO_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/migrate-todo.sh"
STATE_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/state.sh"
FIXTURE_DIR="$AGENTS_DIR/tests/fixtures/migration"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$HIST_SCRIPT" ]  || missing+=("bin/github-issues/migration/migrate-history.sh")
[ -f "$TODO_SCRIPT" ]  || missing+=("bin/github-issues/migration/migrate-todo.sh")
[ -f "$STATE_SCRIPT" ] || missing+=("bin/github-issues/migration/state.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# Single shared fixture for the cumulative canary flow.
TMP="$(mktemp -d)"
REPO="$TMP/repo"
mkdir -p "$REPO/docs"
cp "$FIXTURE_DIR/history.md" "$REPO/docs/history.md"
cp "$FIXTURE_DIR/todo.md"    "$REPO/docs/todo.md"
ORIGINAL_TODO_HASH=$(cksum "$REPO/docs/todo.md" | awk '{print $1}')

# gh-mock dir on PATH.
MOCK_DIR="$TMP/mock"
mkdir -p "$MOCK_DIR"
cp "$FIXTURE_DIR/gh-mock.sh" "$MOCK_DIR/gh"
chmod +x "$MOCK_DIR/gh"

export MOCK_LOG="$TMP/mock.log"
export MOCK_COUNTER="$TMP/counter"
echo 101 > "$MOCK_COUNTER"
: > "$MOCK_LOG"

export PATH="$MOCK_DIR:$PATH"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

# shellcheck disable=SC1090
source "$STATE_SCRIPT"
state_init "$REPO" >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1

cleanup() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

count_create_calls() {
    grep -c '^gh issue create' "$MOCK_LOG" 2>/dev/null || echo 0
}

# --- K1: migrate-history --canary 1
run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO" --canary 1 >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1
c=$(state_count_migrated history 2>/dev/null)
todo_hash=$(cksum "$REPO/docs/todo.md" | awk '{print $1}')
if [ "$c" = "1" ] && [ "$todo_hash" = "$ORIGINAL_TODO_HASH" ]; then
    pass "K1: canary 1 history → migrated=1, todo.md unchanged"
else
    fail "K1: migrated=$c todo_changed=$([ "$todo_hash" = "$ORIGINAL_TODO_HASH" ] && echo no || echo yes)"
fi

# --- K2: migrate-history --canary 2 (cumulative 2, no dupes)
run_with_timeout 30 bash "$HIST_SCRIPT" "$REPO" --canary 2 >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1
c=$(state_count_migrated history 2>/dev/null)
create_calls=$(count_create_calls)
if [ "$c" = "2" ] && [ "$create_calls" = "2" ]; then
    pass "K2: canary 2 → cumulative 2, create_calls=2 (no dup)"
else
    fail "K2: migrated=$c create_calls=$create_calls"
fi

# --- K3: full history → cumulative 6, no dupes
run_with_timeout 60 bash "$HIST_SCRIPT" "$REPO" >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1
c=$(state_count_migrated history 2>/dev/null)
create_calls=$(count_create_calls)
if [ "$c" = "6" ] && [ "$create_calls" = "6" ]; then
    pass "K3: full history → cumulative 6, create_calls=6"
else
    fail "K3: migrated=$c create_calls=$create_calls"
fi

# --- K4: migrate-todo --canary 1 → 1 todo issue, todo.md unchanged
run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" --canary 1 >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1
c=$(state_count_migrated todo 2>/dev/null)
# todo.md must still match original (only rewritten on full run).
if [ "$c" = "1" ] && grep -q "## Active Work" "$REPO/docs/todo.md"; then
    pass "K4: canary 1 todo → migrated=1, todo.md headers intact"
else
    fail "K4: migrated=$c headers_intact=$(grep -q '## Active Work' "$REPO/docs/todo.md" && echo yes || echo no)"
fi

# --- K5: migrate-todo --canary 2 → cumulative 2, todo.md still unchanged
run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" --canary 2 >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1
c=$(state_count_migrated todo 2>/dev/null)
if [ "$c" = "2" ] && grep -q "## Active Work" "$REPO/docs/todo.md"; then
    pass "K5: canary 2 todo → cumulative 2, todo.md still not rewritten"
else
    fail "K5: migrated=$c headers_intact=$(grep -q '## Active Work' "$REPO/docs/todo.md" && echo yes || echo no)"
fi

# --- K6: full todo → cumulative 2 (no new issues), todo.md rewritten
run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" >/dev/null 2>&1
state_load "$REPO" >/dev/null 2>&1
c=$(state_count_migrated todo 2>/dev/null)
rewritten=$(jq -r '.todo.todo_md_rewritten' "$REPO/.migration-state.json" 2>/dev/null)
if [ "$c" = "2" ] && [ "$rewritten" = "true" ] && \
   grep -q "See GitHub Issues" "$REPO/docs/todo.md" 2>/dev/null; then
    pass "K6: full todo → migrated=2, todo.md rewritten as ID index"
else
    fail "K6: migrated=$c rewritten=$rewritten see_gh=$(grep -q 'See GitHub Issues' "$REPO/docs/todo.md" 2>/dev/null && echo yes || echo no)"
fi

# --- K7: total create calls == 8 (6 history + 2 todo)
total_calls=$(count_create_calls)
if [ "$total_calls" = "8" ]; then
    pass "K7: total gh issue create calls = 8 (no duplicates)"
else
    fail "K7: total create_calls=$total_calls (expected 8)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
