#!/bin/bash
# Tests for bin/github-issues/ensure-board-card.sh — Issue #548
# Ensures a GitHub issue is on Projects v2 board with Content Date set.
#
# Inline gh-mock pattern from tests/feature-wip-state.sh.
#
# RED: this suite fails clean while bin/github-issues/ensure-board-card.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/ensure-board-card.sh"

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

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/ensure-board-card.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 13 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory. Mock supports:
#   - auth status (configurable project scope)
#   - project item-add (records args; can fail per GH_MOCK_FAIL value)
#   - project item-edit (records args; can fail per GH_MOCK_FAIL value)
#   - issue view --json url (URL resolve)
#   - api graphql (returns mock projectItems id for membership check)
#
# Env knobs:
#   GH_MOCK_PROJECT_ITEM_ID    item id returned by resolve_item_id graphql query
#                              (when set: simulates "already in project")
#                              (when empty/unset: simulates "not in project")
#   GH_MOCK_ITEM_ADD_ID        item id returned by item-add (default: PVTI_added)
#   GH_MOCK_FAIL               one of: item-add|item-add-already|item-edit|issue-view
#   GH_MOCK_ISSUE_URL          URL returned by `gh issue view --json url`
#   GH_MOCK_MISSING_PROJECT_SCOPE  if "1", auth status omits 'project' scope
#   GH_MOCK_RESOLVE_AFTER_ADD  item id returned by 2nd resolve_item_id call
#   GH_MOCK_ARGS_LOG           append-only call log
# ---------------------------------------------------------------------------

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    if [ "${GH_MOCK_MISSING_PROJECT_SCOPE:-}" = "1" ]; then
        echo "Token scopes: 'gist', 'read:org', 'repo'"
    else
        echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    fi
    exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_FAIL:-}" = "item-add" ]; then
        echo "error: item-add failed" >&2
        exit 1
    fi
    if [ "${GH_MOCK_FAIL:-}" = "item-add-already" ]; then
        echo "error: project item already exists for content" >&2
        exit 1
    fi
    echo "${GH_MOCK_ITEM_ADD_ID:-PVTI_added}"
    exit 0 ;;
  project\ item-edit\ *)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit" ]; then
        echo "error: item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  issue\ view\ *--json\ createdAt*)
    if [ "${GH_MOCK_FAIL:-}" = "issue-view" ]; then
        echo "error: gh issue view failed" >&2
        exit 1
    fi
    echo "2024-01-15"
    exit 0 ;;
  issue\ view\ *--json\ url*|issue\ view\ *)
    if [ "${GH_MOCK_FAIL:-}" = "issue-view" ]; then
        echo "error: gh issue view failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"
    exit 0 ;;
  api\ graphql\ *)
    # resolve_item_id query. If RESOLVE_AFTER_ADD set, the SECOND call returns
    # that id (simulating concurrent race recovery).
    if [ -n "${GH_MOCK_RESOLVE_COUNTER_FILE:-}" ]; then
        N=$(cat "$GH_MOCK_RESOLVE_COUNTER_FILE" 2>/dev/null || echo 0)
        N=$((N + 1)); echo "$N" > "$GH_MOCK_RESOLVE_COUNTER_FILE"
        if [ "$N" -ge 2 ] && [ -n "${GH_MOCK_RESOLVE_AFTER_ADD:-}" ]; then
            printf '%s\n' "$GH_MOCK_RESOLVE_AFTER_ADD"
            exit 0
        fi
    fi
    printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"
    exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
    export GH_MOCK_RESOLVE_COUNTER_FILE="$TMP/resolve-counter"
    echo 0 > "$GH_MOCK_RESOLVE_COUNTER_FILE"

    # Required env vars (mirrors issue-create.sh / wip-state.sh conventions).
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR"
    export ISSUE_CREATE_PROJECT_ID="PVT_kwHOAMF_jc4BXf9E"
    export ISSUE_CREATE_PROJECT_NUM="1"
    export ISSUE_CREATE_OWNER="nirecom"
    # Content Date field id (Projects v2 built-in field).
    export EBC_FIELD_ID="PVTF_contentdate"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_ITEM_ID GH_MOCK_ITEM_ADD_ID \
          GH_MOCK_FAIL GH_MOCK_ISSUE_URL GH_MOCK_MISSING_PROJECT_SCOPE \
          GH_MOCK_RESOLVE_AFTER_ADD GH_MOCK_RESOLVE_COUNTER_FILE \
          GH_MOCK_OWNER_REPO 2>/dev/null || true
    unset AGENTS_CONFIG_DIR ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM \
          ISSUE_CREATE_OWNER EBC_FIELD_ID \
          EBC_PROJECT_NUM 2>/dev/null || true
}

# ===========================================================================
# Test 1: Missing arg → exit 2 with usage message on stderr
# ===========================================================================
setup_mock
STDERR_FILE="$TMP/stderr.log"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>"$STDERR_FILE"
RC=$?
if [ "$RC" -eq 2 ] && [ -s "$STDERR_FILE" ]; then
    pass "T1: missing arg → exit 2, usage on stderr"
else
    fail "T1: rc=$RC stderr_empty=$([ -s "$STDERR_FILE" ] && echo no || echo yes) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 2: Non-integer arg → exit 2
# ===========================================================================
setup_mock
run_with_timeout 30 bash "$TARGET" "abc" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T2: non-integer arg → exit 2"
else
    fail "T2: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 3: Standalone invocation — env -i, no AGENTS_CONFIG_DIR. Must not error
# on missing AGENTS_CONFIG_DIR (the helper has no .env dependency).
# We expect a non-fatal outcome (exit 0 or exit 1 from gh missing, but not 2).
# ===========================================================================
setup_mock
# Capture variables we need to forward.
SAVED_PATH="$PATH"
# Run with a minimal env. Helper must not abort with "AGENTS_CONFIG_DIR unset".
STDERR_FILE="$TMP/standalone-stderr.log"
env -i PATH="$SAVED_PATH" HOME="$HOME" \
    ISSUE_CREATE_PROJECT_ID="PVT_kwHOAMF_jc4BXf9E" \
    ISSUE_CREATE_PROJECT_NUM="1" \
    ISSUE_CREATE_OWNER="nirecom" \
    EBC_FIELD_ID="PVTF_contentdate" \
    GH_MOCK_PROJECT_ITEM_ID="PVTI_existing" \
    GH_MOCK_ARGS_LOG="$GH_MOCK_ARGS_LOG" \
    run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
# Helper must not exit 2 (preflight-style failure) on missing AGENTS_CONFIG_DIR.
if [ "$RC" -ne 2 ] && ! grep -qi "AGENTS_CONFIG_DIR" "$STDERR_FILE" 2>/dev/null; then
    pass "T3: standalone (no AGENTS_CONFIG_DIR) → no preflight failure"
else
    fail "T3: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 4: Item not in project → calls item-add + item-edit (Content Date)
# ===========================================================================
setup_mock
# GH_MOCK_PROJECT_ITEM_ID unset → resolve_item_id returns empty → item-add path.
export GH_MOCK_ITEM_ADD_ID="PVTI_newly_added"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_ADD=0
HAS_ITEM_EDIT=0
grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD=1
grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_ADD" -eq 1 ] && [ "$HAS_ITEM_EDIT" -eq 1 ]; then
    pass "T4: item not in project → item-add + item-edit called"
else
    fail "T4: rc=$RC item_add=$HAS_ITEM_ADD item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 5: Item already in project → does NOT call item-add; DOES call item-edit
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_ADD=0
HAS_ITEM_EDIT=0
grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD=1
grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_ADD" -eq 0 ] && [ "$HAS_ITEM_EDIT" -eq 1 ]; then
    pass "T5: item already in project → no item-add, item-edit called"
else
    fail "T5: rc=$RC item_add=$HAS_ITEM_ADD item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 6: Concurrent race — item-add fails with "already" stderr, second
# resolve returns item id → proceeds to item-edit (does NOT warn and exit).
# ===========================================================================
setup_mock
# First resolve_item_id returns empty (not in project). item-add fails with
# "already". Second resolve returns the existing id.
export GH_MOCK_FAIL="item-add-already"
export GH_MOCK_RESOLVE_AFTER_ADD="PVTI_recovered"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_EDIT" -eq 1 ]; then
    pass "T6: concurrent race (add already) + refetch → item-edit called"
else
    fail "T6: rc=$RC item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 7: Content Date set — item-edit receives --date YYYY-MM-DD format
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
# Look for --date followed by ISO-8601 date.
HAS_ISO_DATE=0
grep -qE -- "--date [0-9]{4}-[0-9]{2}-[0-9]{2}" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ISO_DATE=1
if [ "$RC" -eq 0 ] && [ "$HAS_ISO_DATE" -eq 1 ]; then
    pass "T7: Content Date → item-edit --date YYYY-MM-DD format"
else
    fail "T7: rc=$RC iso_date=$HAS_ISO_DATE log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 8: gh issue view failure → warn on stderr, exit 0 (non-fatal)
# ===========================================================================
setup_mock
# Item not in project → triggers issue view for URL resolve. Force failure.
export GH_MOCK_FAIL="issue-view"
STDERR_FILE="$TMP/stderr.log"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && [ -s "$STDERR_FILE" ]; then
    pass "T8: gh issue view fail → warn + exit 0"
else
    fail "T8: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 9: item-add fails AND item absent after retry → warn + exit 0
# ===========================================================================
setup_mock
# resolve_item_id always returns empty (no GH_MOCK_RESOLVE_AFTER_ADD).
# item-add fails with generic error (not "already" race).
export GH_MOCK_FAIL="item-add"
STDERR_FILE="$TMP/stderr.log"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && [ -s "$STDERR_FILE" ]; then
    pass "T9: item-add fail + item absent → warn + exit 0 (non-fatal)"
else
    fail "T9: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 10: item-edit (Content Date) failure → warn + exit 0
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit"
STDERR_FILE="$TMP/stderr.log"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && [ -s "$STDERR_FILE" ]; then
    pass "T10: item-edit fail → warn + exit 0"
else
    fail "T10: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 11: No project scope — warns softly, continues
# ===========================================================================
setup_mock
export GH_MOCK_MISSING_PROJECT_SCOPE=1
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
STDERR_FILE="$TMP/stderr.log"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
# Helper warns but does not abort on missing scope.
if [ "$RC" -eq 0 ] && [ -s "$STDERR_FILE" ]; then
    pass "T11: no project scope → soft warn, continues"
else
    fail "T11: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 12: Idempotent — second invocation with existing id, no item-add
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC1=$?
: > "$GH_MOCK_ARGS_LOG"
echo 0 > "$GH_MOCK_RESOLVE_COUNTER_FILE"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC2=$?
HAS_ITEM_ADD=0
grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD=1
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$HAS_ITEM_ADD" -eq 0 ]; then
    pass "T12: idempotent — second invocation does not call item-add"
else
    fail "T12: rc1=$RC1 rc2=$RC2 item_add=$HAS_ITEM_ADD log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 13: Env var priority — ISSUE_CREATE_PROJECT_NUM beats EBC_PROJECT_NUM.
# PROJECT_NUM is passed as the positional arg to `gh project item-add`.
# Leave GH_MOCK_PROJECT_ITEM_ID unset so item-add is actually invoked.
# ===========================================================================
setup_mock
# GH_MOCK_PROJECT_ITEM_ID unset → item not in project → item-add is triggered.
export ISSUE_CREATE_PROJECT_NUM="99"
export EBC_PROJECT_NUM="77"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
# Verify "99" (winning) appears in item-add args and "77" (losing) does not.
HAS_WINNING=0
HAS_LOSING=0
grep -qE "project item-add 99" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_WINNING=1
grep -qE "project item-add 77" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_LOSING=1
if [ "$RC" -eq 0 ] && [ "$HAS_WINNING" -eq 1 ] && [ "$HAS_LOSING" -eq 0 ]; then
    pass "T13: ISSUE_CREATE_PROJECT_NUM=99 beats EBC_PROJECT_NUM=77"
else
    fail "T13: rc=$RC winning=$HAS_WINNING losing=$HAS_LOSING log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
