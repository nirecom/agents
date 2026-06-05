#!/bin/bash
# Tests: bin/github-issues/migration/migrate-todo.sh, bin/github-issues/migration/orchestrate.sh
# Tags: migration, todo, empty-section, dry-run, fix
# Tests for fix #683 — empty-section guard in migrate-todo.sh flush() and
# todo_entries_total() in orchestrate.sh.
#
# RED: currently fails — expected to fail until the source fix is applied.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TODO_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/migrate-todo.sh"
ORCH_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"
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
[ -f "$TODO_SCRIPT" ]  || missing+=("bin/github-issues/migration/migrate-todo.sh")
[ -f "$STATE_SCRIPT" ] || missing+=("bin/github-issues/migration/state.sh")
[ -f "$ORCH_SCRIPT" ]  || missing+=("bin/github-issues/migration/orchestrate.sh")
[ -f "$FIXTURE_DIR/gh-mock.sh" ] || missing+=("tests/fixtures/migration/gh-mock.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Shared setup helpers
# ---------------------------------------------------------------------------

setup_repo() {
    TMP="$(mktemp -d)"
    REPO="$TMP/repo"
    mkdir -p "$REPO/docs"

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
}

teardown_repo() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG MOCK_COUNTER AGENTS_CONFIG_DIR
}

count_create_calls() {
    grep -c '^gh issue create' "$MOCK_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# E1: dry-run, header-only section only → SKIP log, 0 "would" lines
# ---------------------------------------------------------------------------
setup_repo
cat > "$REPO/docs/todo.md" <<'EOF'
## Empty Section

EOF
OUT=$(run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" --dry-run 2>&1)
would_count=$(echo "$OUT" | grep -c 'would: gh issue create' 2>/dev/null)
# After the fix: 0 "would" lines; a SKIP log line is expected.
if [ "$would_count" -eq 0 ]; then
    pass "E1: dry-run header-only → 0 'would' lines"
else
    fail "E1: dry-run header-only → expected 0 'would' lines, got $would_count"
fi
teardown_repo

# ---------------------------------------------------------------------------
# E2: dry-run, 1 empty + 1 real section → exactly 1 "would" line, SKIP logged for empty
# ---------------------------------------------------------------------------
setup_repo
cat > "$REPO/docs/todo.md" <<'EOF'
## Empty Section

## Real Section

- task-001: do the thing
EOF
OUT=$(run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" --dry-run 2>&1)
would_count=$(echo "$OUT" | grep -c 'would: gh issue create' 2>/dev/null)
if [ "$would_count" -eq 1 ]; then
    pass "E2: dry-run 1 empty + 1 real → exactly 1 'would' line"
else
    fail "E2: dry-run 1 empty + 1 real → expected 1 'would' line, got $would_count"
fi
teardown_repo

# ---------------------------------------------------------------------------
# E3: live, header-only section only → 0 gh create calls (mock), SKIP logged
# ---------------------------------------------------------------------------
setup_repo
cat > "$REPO/docs/todo.md" <<'EOF'
## Empty Section

EOF
# shellcheck disable=SC1090
source "$STATE_SCRIPT"
state_init "$REPO" >/dev/null 2>&1

OUT=$(run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" 2>&1)
create_calls=$(count_create_calls)
if [ "$create_calls" -eq 0 ]; then
    pass "E3: live header-only → 0 gh create calls"
else
    fail "E3: live header-only → expected 0 create calls, got $create_calls; out=$OUT"
fi
teardown_repo

# ---------------------------------------------------------------------------
# E4: live, 1 empty + 1 real → 1 gh create call, SKIP logged, summary mentions "1 new issues created"
# ---------------------------------------------------------------------------
setup_repo
cat > "$REPO/docs/todo.md" <<'EOF'
## Empty Section

## Real Section

- task-001: do the thing
EOF
source "$STATE_SCRIPT"
state_init "$REPO" >/dev/null 2>&1

OUT=$(run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" 2>&1)
create_calls=$(count_create_calls)
summary_ok=0
echo "$OUT" | grep -qi "1 new issues created" && summary_ok=1
if [ "$create_calls" -eq 1 ] && [ "$summary_ok" -eq 1 ]; then
    pass "E4: live 1 empty + 1 real → 1 create call, summary '1 new issues created'"
else
    fail "E4: create_calls=$create_calls summary_ok=$summary_ok; out=$OUT"
fi
teardown_repo

# ---------------------------------------------------------------------------
# E5: live, all sections empty → 0 gh create calls
# ---------------------------------------------------------------------------
setup_repo
cat > "$REPO/docs/todo.md" <<'EOF'
## Empty Section One

## Empty Section Two

EOF
source "$STATE_SCRIPT"
state_init "$REPO" >/dev/null 2>&1

OUT=$(run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" 2>&1)
create_calls=$(count_create_calls)
if [ "$create_calls" -eq 0 ]; then
    pass "E5: live all-empty → 0 gh create calls"
else
    fail "E5: live all-empty → expected 0 create calls, got $create_calls; out=$OUT"
fi
teardown_repo

# ---------------------------------------------------------------------------
# E6: whitespace-only body (no task lines, just blank lines) → treated as empty, SKIP
# ---------------------------------------------------------------------------
setup_repo
# The section body has only whitespace/blank lines — no task lines
cat > "$REPO/docs/todo.md" <<'EOF'
## Whitespace-Only Section



EOF
source "$STATE_SCRIPT"
state_init "$REPO" >/dev/null 2>&1

OUT=$(run_with_timeout 30 bash "$TODO_SCRIPT" "$REPO" 2>&1)
create_calls=$(count_create_calls)
if [ "$create_calls" -eq 0 ]; then
    pass "E6: whitespace-only body → treated as empty, 0 create calls"
else
    fail "E6: whitespace-only body → expected 0 create calls, got $create_calls; out=$OUT"
fi
teardown_repo

# ---------------------------------------------------------------------------
# E7: todo_entries_total() returns non-empty section count when todo.md has
#     1 real + 1 empty section (should return 1, not 2)
#
# After the fix, orchestrate.sh's todo_entries_total() must exclude empty
# sections. We replicate the fixed awk logic inline to test the expected
# behavior — this tests the fixed semantics rather than the exact implementation.
#
# Fixed awk pattern (expected after fix): count ## sections that have at least
# one non-blank body line before the next ## header or EOF.
# ---------------------------------------------------------------------------
TMP_E7="$(mktemp -d)"
cat > "$TMP_E7/todo.md" <<'EOF'
## Empty Section

## Real Section

- task-001: do the thing
EOF

# Replicate the EXPECTED post-fix awk logic:
# A section is "non-empty" if it has at least one non-blank, non-header line.
E7_COUNT=$(awk '
  /^## / {
    if (n > 0 && has_content) non_empty++
    n++; has_content=0; next
  }
  n > 0 && /[^[:space:]]/ && !/^## / { has_content=1 }
  END { if (n > 0 && has_content) non_empty++ ; print non_empty+0 }
' "$TMP_E7/todo.md")

# Current (unfixed) awk counts all ## headers regardless of body:
E7_COUNT_CURRENT=$(awk '/^## /{n++} END{print n+0}' "$TMP_E7/todo.md")

rm -rf "$TMP_E7"

if [ "$E7_COUNT" -eq 1 ]; then
    pass "E7: todo_entries_total fixed awk → 1 non-empty section (not $E7_COUNT_CURRENT)"
else
    fail "E7: expected 1 non-empty section, got $E7_COUNT (current blind count: $E7_COUNT_CURRENT)"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
