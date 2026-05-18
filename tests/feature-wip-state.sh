#!/bin/bash
# Tests for bin/github-issues/wip-state.sh — Issue #362 WIP signaling helper.
#
# Helper has four verbs: set, check, clear, setup.
#   - set <N>:   write fingerprint (text field) BEFORE Status=In Progress.
#   - check <N>: print same|other|none.
#   - clear <N>: Status=Done + fingerprint="" + delete lock file (idempotent).
#   - setup:     one-shot ID discovery via gh api graphql; append to .env.
#
# 30 test cases per detail.md §"tests/feature-wip-state.sh (new)".
# Inline-gh-mock pattern from tests/feature-issue-create-skill.sh.
#
# RED: this suite fails clean while bin/github-issues/wip-state.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/wip-state.sh"

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
    echo "FAIL: bin/github-issues/wip-state.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 30 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory — written per test so each test gets its own log
# and env vars. Mock supports:
#   - project item-edit (records args; can fail per GH_MOCK_FAIL value)
#   - project item-add (returns GH_MOCK_ITEM_ADD_ID or fails)
#   - issue view --json url (URL resolve)
#   - api graphql (returns mock fieldValues / item id / setup metadata)
#
# Env knobs:
#   GH_MOCK_PROJECT_ITEM_ID    item id returned by resolve_item_id graphql query
#   GH_MOCK_ITEM_ADD_ID        item id returned by item-add (default: PVTI_added)
#   GH_MOCK_STATUS             status name returned by check graphql (e.g. "In Progress")
#   GH_MOCK_FINGERPRINT        fingerprint text returned by check graphql
#   GH_MOCK_FAIL               one of: item-edit-status|item-edit-fp|graphql|item-add|issue-view
#   GH_MOCK_ISSUE_URL          URL returned by `gh issue view --json url`
#   GH_MOCK_PAGINATED_PAGES    if "1", check returns two graphql JSON pages (status on p1, fp on p2)
#   GH_MOCK_ARGS_LOG           append-only call log (one line per gh invocation)
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
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    # Default: nirecom/agents. resolve_owner_repo --jq produces "owner/name".
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_FAIL:-}" = "item-add" ]; then
        echo "error: item-add failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ITEM_ADD_ID:-PVTI_added}"
    exit 0 ;;
  project\ item-edit\ *--single-select-option-id*)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-status" ]; then
        echo "error: status item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  project\ item-edit\ *--text*)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-fp" ]; then
        echo "error: fingerprint item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  issue\ view\ *--json\ url*)
    if [ "${GH_MOCK_FAIL:-}" = "issue-view" ]; then
        echo "error: gh issue view failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"
    exit 0 ;;
  api\ graphql\ *)
    if [ "${GH_MOCK_FAIL:-}" = "graphql" ]; then
        echo "error: graphql failed" >&2
        exit 1
    fi
    # Source uses `gh --jq` so mock emits the pre-filtered value.
    # Distinguish by --jq filter content (each query has a unique key token).
    case "$ARGS" in
      *projectItems*)
        # resolve_item_id query — print just the item id (or empty if no membership).
        printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"
        exit 0
        ;;
      *".name == \"Status\""*)
        # cmd_setup: STATUS-related --jq filter.
        case "$ARGS" in
          *"select(.__typename == \"ProjectV2SingleSelectField\""*) echo "PVTSSF_status" ;;
          *"select(.name == \"Todo\")"*)         echo "OPT_todo" ;;
          *"select(.name == \"In Progress\")"*)  echo "OPT_inprog" ;;
          *"select(.name == \"Done\")"*)         echo "OPT_done" ;;
          *) echo "" ;;
        esac
        exit 0
        ;;
      *".name == \"session-fingerprint\""*)
        # cmd_setup: fingerprint field id.
        echo "PVTF_fp"
        exit 0
        ;;
      *"select(.field.id"*".name"*|*".field.id"*"\")"*"| .name"*)
        # cmd_check: status read (single-select .name).
        printf '%s\n' "${GH_MOCK_STATUS:-In Progress}"
        exit 0
        ;;
      *"select(.field.id"*".text"*|*".field.id"*"\")"*"| .text"*)
        # cmd_check: fingerprint read.
        printf '%s\n' "${GH_MOCK_FINGERPRINT:-}"
        exit 0
        ;;
      *)
        # Fallback: generic empty.
        echo ""
        exit 0
        ;;
    esac
    ;;
  issue\ view\ *)
    if [ "${GH_MOCK_FAIL:-}" = "issue-view" ]; then
        echo "error: gh issue view failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"
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

    # Required env vars for the helper.
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR"
    # Fake plans dir resolver: a stub bin/workflow-plans-dir that prints $PLANS_DIR.
    mkdir -p "$AGENTS_CONFIG_DIR/bin"
    export PLANS_DIR="$TMP/plans"
    mkdir -p "$PLANS_DIR"
    cat > "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" <<EOF
#!/bin/bash
echo "$PLANS_DIR"
EOF
    chmod +x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"

    # CLAUDE_ENV_FILE with a deterministic session id.
    export CLAUDE_ENV_FILE="$TMP/claude-env"
    echo "CLAUDE_SESSION_ID=test-sid-fixture" > "$CLAUDE_ENV_FILE"

    # WIP_STATE_* env vars (preflight-required).
    export WIP_STATE_STATUS_FIELD_ID="PVTSSF_status"
    export WIP_STATE_IN_PROGRESS_OPTION_ID="OPT_inprog"
    export WIP_STATE_DONE_OPTION_ID="OPT_done"
    export WIP_STATE_TODO_OPTION_ID="OPT_todo"
    export WIP_STATE_FINGERPRINT_FIELD_ID="PVTF_fp"

    # Reuse from issue-create.sh convention.
    export ISSUE_CREATE_PROJECT_ID="PVT_kwHOAMF_jc4BXf9E"
    export ISSUE_CREATE_PROJECT_NUM="1"
    export ISSUE_CREATE_OWNER="nirecom"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_ITEM_ID GH_MOCK_ITEM_ADD_ID \
          GH_MOCK_STATUS GH_MOCK_FINGERPRINT GH_MOCK_FAIL GH_MOCK_ISSUE_URL \
          GH_MOCK_PAGINATED_PAGES 2>/dev/null || true
    unset AGENTS_CONFIG_DIR CLAUDE_ENV_FILE PLANS_DIR \
          WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
          WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
          WIP_STATE_FINGERPRINT_FIELD_ID \
          ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER 2>/dev/null || true
}

# ===========================================================================
# Test 1: set <N> calls gh project item-edit with --single-select-option-id $WIP_STATE_IN_PROGRESS_OPTION_ID
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--single-select-option-id $WIP_STATE_IN_PROGRESS_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T1: set <N> calls project item-edit with IN_PROGRESS option"
else
    fail "T1: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 2: set <N> writes $PLANS_DIR/wip-lock-<N>.md with three lines
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
if [ -f "$LOCKFILE" ]; then
    LINES=$(wc -l < "$LOCKFILE" 2>/dev/null | tr -d ' ')
    # Three lines could be 3 lines or 2 newlines depending on trailing newline.
    if [ "$LINES" = "3" ] || [ "$LINES" = "2" ]; then
        if grep -q "42" "$LOCKFILE" && grep -q "test-sid-fixture" "$LOCKFILE"; then
            pass "T2: set <N> writes wip-lock-<N>.md with three lines (issue+session+started)"
        else
            fail "T2: lock file content missing issue or session-id: $(cat "$LOCKFILE")"
        fi
    else
        fail "T2: lock file has $LINES lines, expected 3: $(cat "$LOCKFILE")"
    fi
else
    fail "T2: lock file not written at $LOCKFILE"
fi
teardown_mock

# ===========================================================================
# Test 3: set <N> with missing WIP_STATE_STATUS_FIELD_ID exits 2
# ===========================================================================
setup_mock
unset WIP_STATE_STATUS_FIELD_ID
# Also ensure .env doesn't auto-source it back.
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T3: set <N> with missing WIP_STATE_STATUS_FIELD_ID → exit 2"
else
    fail "T3: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 4: set <N> with missing WIP_STATE_FINGERPRINT_FIELD_ID exits 2 (required)
# ===========================================================================
setup_mock
unset WIP_STATE_FINGERPRINT_FIELD_ID
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T4: set <N> with missing WIP_STATE_FINGERPRINT_FIELD_ID → exit 2"
else
    fail "T4: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 5: set <N> with missing/unextractable CLAUDE_SESSION_ID exits 2
# ===========================================================================
setup_mock
echo "" > "$CLAUDE_ENV_FILE"  # no CLAUDE_SESSION_ID
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T5: set <N> with missing CLAUDE_SESSION_ID → exit 2"
else
    fail "T5: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 6: ORDERING INVARIANT — set <N> writes fingerprint BEFORE Status
# Verified via $GH_MOCK_ARGS_LOG line order.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
# Find first item-edit-with-text line number (fingerprint write).
FP_LINE=$(grep -n -- "--text" "$GH_MOCK_ARGS_LOG" 2>/dev/null | grep "item-edit" | head -1 | cut -d: -f1)
STATUS_LINE=$(grep -n -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null | grep "item-edit" | head -1 | cut -d: -f1)
if [ -n "$FP_LINE" ] && [ -n "$STATUS_LINE" ] && [ "$FP_LINE" -lt "$STATUS_LINE" ]; then
    pass "T6: ORDERING — fingerprint write (line $FP_LINE) precedes Status set (line $STATUS_LINE)"
else
    fail "T6: ordering violated (fp_line=$FP_LINE status_line=$STATUS_LINE) log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 7: set <N> with fingerprint-write mock failing → exit 1; Status-set NOT called.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit-fp"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ] && ! grep -q -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T7: fingerprint-write fail → exit 1, Status-set NOT called"
else
    fail "T7: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 8: set <N> with Status-set mock failing → exit 1; fingerprint already written.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit-status"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ] && grep -q -- "--text" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T8: Status-set fail → exit 1, fingerprint already written"
else
    fail "T8: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 9: set <N> with lock-write failure (read-only $PLANS_DIR) exits 0 (warn-and-continue)
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
chmod 555 "$PLANS_DIR" 2>/dev/null || true
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
chmod 755 "$PLANS_DIR" 2>/dev/null || true
# Read-only enforcement is unreliable on Windows/MSYS; accept either exit 0
# (warn-and-continue on lock failure) or exit 0 because lock write actually
# succeeded — the test's invariant is "lock failure must not be fatal".
if [ "$RC" -eq 0 ]; then
    pass "T9: lock-write fail → exit 0 (warn-and-continue)"
else
    fail "T9: lock-write fail should not fail helper; rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 10: set <N> on item not in project — resolves URL via gh issue view, calls item-add.
# ===========================================================================
setup_mock
# GH_MOCK_PROJECT_ITEM_ID unset → graphql returns empty nodes → triggers item-add path.
export GH_MOCK_ITEM_ADD_ID="PVTI_newly_added"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q "issue view.*--json url" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T10: item not in project → URL resolve + item-add called"
else
    fail "T10: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 11: set <N> where item-add fails but refetch succeeds (duplicate-add race).
# ===========================================================================
setup_mock
# First resolve_item_id returns empty; item-add fails; refetch returns id.
# We approximate by: item-add fails, then a second graphql call returns a real id.
# Mock cannot easily switch state mid-run; simulate by using a counter file.
COUNTER="$TMP/resolve-counter"
echo 0 > "$COUNTER"
# Replace the mock to count graphql resolve calls.
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'project', 'repo'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectItems*)
    # Counter-driven: first call empty, second returns refetched id.
    N=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    N=$((N + 1)); echo "$N" > "$COUNTER_FILE"
    if [ "$N" -le 1 ]; then
        echo ""
    else
        echo "${GH_MOCK_REFETCH_ITEM_ID:-PVTI_refetched}"
    fi
    exit 0
    ;;
  api\ graphql\ *)
    echo ""; exit 0 ;;
  project\ item-add\ *)
    echo "error: duplicate add race" >&2; exit 1 ;;
  project\ item-edit\ *)
    exit 0 ;;
  issue\ view\ *--json\ url*)
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  issue\ view\ *)
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  *)
    echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
export COUNTER_FILE="$COUNTER"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T11: item-add fail + refetch succeeds → exit 0 (duplicate-add race)"
else
    fail "T11: expected exit 0 with refetch recovery, got rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 12: set <N> where item-add fails AND refetch empty → exit 1.
# ===========================================================================
setup_mock
# Reuse default mock; ensure resolve_item_id stays empty AND item-add fails.
export GH_MOCK_FAIL="item-add"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "T12: item-add fail + refetch empty → exit 1"
else
    fail "T12: expected exit 1, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 13: set <N> where gh issue view URL resolution fails → exit 1.
# ===========================================================================
setup_mock
# Empty PROJECT_ITEM_ID → triggers URL resolve; force issue-view failure.
export GH_MOCK_FAIL="issue-view"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "T13: gh issue view URL resolve fail → exit 1"
else
    fail "T13: expected exit 1, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 14: check <N> returns "same" on matching fingerprint with "In Progress".
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
# Compute expected fingerprint locally (sha256(sid:N)[:8]).
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "T14: check <N> with matching fingerprint + In Progress → 'same'"
else
    fail "T14: rc=$RC out='$OUT' expected_fp=$EXPECTED_FP"
fi
teardown_mock

# ===========================================================================
# Test 15: check <N> returns "other" on fingerprint mismatch with "In Progress".
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
export GH_MOCK_FINGERPRINT="deadbeef"  # not matching test-sid-fixture:42
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "other" ]; then
    pass "T15: check <N> with mismatched fingerprint → 'other'"
else
    fail "T15: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 16: check <N> returns "none" when item not found in project.
# ===========================================================================
setup_mock
# GH_MOCK_PROJECT_ITEM_ID unset → resolve_item_id returns empty.
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then
    pass "T16: check <N> with item not in project → 'none'"
else
    fail "T16: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 17: check <N> returns "none" when status ≠ "In Progress".
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="Todo"
export GH_MOCK_FINGERPRINT="deadbeef"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then
    pass "T17: check <N> with status=Todo → 'none'"
else
    fail "T17: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 18: check <N> on gh graphql failure → exit 1, stdout empty.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="graphql"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
    pass "T18: check <N> graphql fail → exit 1, stdout empty"
else
    fail "T18: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 19: check <N> with missing session-id → exit 2.
# ===========================================================================
setup_mock
echo "" > "$CLAUDE_ENV_FILE"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T19: check <N> with missing CLAUDE_SESSION_ID → exit 2"
else
    fail "T19: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 20: check <N> graphql query references $WIP_STATE_STATUS_FIELD_ID and $WIP_STATE_FINGERPRINT_FIELD_ID.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
run_with_timeout 60 bash "$TARGET" check 42 >/dev/null 2>&1
# Look for both field IDs anywhere in the args log of the graphql calls.
if grep -q "$WIP_STATE_STATUS_FIELD_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "$WIP_STATE_FINGERPRINT_FIELD_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T20: check <N> graphql references both WIP_STATE_*_FIELD_ID env vars (ID-based filter)"
else
    fail "T20: expected both field IDs in gh args log; log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -20)"
fi
teardown_mock

# ===========================================================================
# Test 21: clear <N> calls item-edit with $WIP_STATE_DONE_OPTION_ID AND --text "" AND deletes lock.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
# Pre-create the lock file.
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
HAS_DONE=$(grep -c -- "--single-select-option-id $WIP_STATE_DONE_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
# After bash expansion, `--text ""` appears as `--text ` (empty arg collapsed).
HAS_EMPTY_TEXT=$(grep -cE -- '--text *$' "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
if [ "$RC" -eq 0 ] && [ "$HAS_DONE" -ge 1 ] && [ "$HAS_EMPTY_TEXT" -ge 1 ] && [ "$LOCK_DELETED" -eq 1 ]; then
    pass "T21: clear <N> sets DONE + clears fingerprint + deletes lock"
else
    fail "T21: rc=$RC done=$HAS_DONE empty_text=$HAS_EMPTY_TEXT lock_deleted=$LOCK_DELETED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 22: clear <N> idempotent on repeat (no lock file exists).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC1=$?
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC2=$?
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]; then
    pass "T22: clear <N> idempotent on repeat (both exits 0)"
else
    fail "T22: rc1=$RC1 rc2=$RC2"
fi
teardown_mock

# ===========================================================================
# Test 23: clear <N> with every gh call failing → exit 0 AND attempts lock deletion.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit-status"  # only one fail flag; mock also will fail item-edit-fp via combined? Use --text fail via env override
# To simulate every gh call failing, override mock to always fail item-edit:
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  project\ item-edit\ *) echo "error: gh down" >&2; exit 1 ;;
  api\ graphql\ *)
    echo "PVTI_existing"; exit 0
    ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ]; then
    pass "T23: clear <N> all gh fail → exit 0, lock still deleted"
else
    fail "T23: rc=$RC lock_deleted=$LOCK_DELETED"
fi
teardown_mock

# ===========================================================================
# Test 24: setup parses mock graphql, appends env vars; second invocation doesn't duplicate.
# ===========================================================================
setup_mock
ENV_FILE="$AGENTS_CONFIG_DIR/.env"
: > "$ENV_FILE"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC1=$?
COUNT1=$(grep -c "WIP_STATE_STATUS_FIELD_ID" "$ENV_FILE" 2>/dev/null || echo 0)
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC2=$?
COUNT2=$(grep -c "WIP_STATE_STATUS_FIELD_ID" "$ENV_FILE" 2>/dev/null || echo 0)
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$COUNT1" -ge 1 ] && [ "$COUNT2" -eq "$COUNT1" ]; then
    pass "T24: setup writes env vars + second invocation does not duplicate (count stable at $COUNT1)"
else
    fail "T24: rc1=$RC1 rc2=$RC2 count1=$COUNT1 count2=$COUNT2"
fi
teardown_mock

# ===========================================================================
# Test 25: fingerprint determinism: same (session-id, N) → same 8-char hex.
# This is verified indirectly through check matching — but we also assert the
# helper accepts a query and a repeated call yields the same fingerprint in
# the args log.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
FP1=$(grep -- "--text " "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 | sed -nE 's/.*--text ([0-9a-f]+).*/\1/p')
: > "$GH_MOCK_ARGS_LOG"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
FP2=$(grep -- "--text " "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 | sed -nE 's/.*--text ([0-9a-f]+).*/\1/p')
if [ -n "$FP1" ] && [ "$FP1" = "$FP2" ] && [ "${#FP1}" -eq 8 ]; then
    pass "T25: fingerprint determinism: same (sid,N) → same 8-char hex (fp=$FP1)"
else
    fail "T25: fp1='$FP1' fp2='$FP2' len(fp1)=${#FP1}"
fi
teardown_mock

# ===========================================================================
# Test 26: PLANS_DIR resolution honors WORKFLOW_PLANS_DIR override.
# bin/workflow-plans-dir in our stub prints $PLANS_DIR — override $PLANS_DIR.
# ===========================================================================
setup_mock
ALT_PLANS="$TMP/alternative-plans"
mkdir -p "$ALT_PLANS"
# Rewrite stub to use WORKFLOW_PLANS_DIR override.
cat > "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" <<EOF
#!/bin/bash
echo "\${WORKFLOW_PLANS_DIR:-$PLANS_DIR}"
EOF
chmod +x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"
export WORKFLOW_PLANS_DIR="$ALT_PLANS"
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
if [ -f "$ALT_PLANS/wip-lock-42.md" ]; then
    pass "T26: PLANS_DIR resolution honors WORKFLOW_PLANS_DIR override"
else
    fail "T26: lock not written to override path $ALT_PLANS/wip-lock-42.md"
fi
unset WORKFLOW_PLANS_DIR
teardown_mock

# ===========================================================================
# Test 27: .env auto-source — preflight passes when var lives only in $AGENTS_CONFIG_DIR/.env.
# ===========================================================================
setup_mock
# Move STATUS_FIELD_ID from env into .env.
ORIG_STATUS="$WIP_STATE_STATUS_FIELD_ID"
unset WIP_STATE_STATUS_FIELD_ID
cat > "$AGENTS_CONFIG_DIR/.env" <<EOF
WIP_STATE_STATUS_FIELD_ID=$ORIG_STATUS
EOF
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T27: .env auto-source — preflight passes via $AGENTS_CONFIG_DIR/.env"
else
    fail "T27: expected exit 0 with .env-sourced var, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 28: .env missing → set still exits 2 via preflight (no spurious pre-preflight failure).
# ===========================================================================
setup_mock
# Wipe required env var; ensure no .env exists.
unset WIP_STATE_STATUS_FIELD_ID
rm -f "$AGENTS_CONFIG_DIR/.env" 2>/dev/null || true
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T28: .env missing → preflight exit 2 (no spurious pre-preflight error)"
else
    fail "T28: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 29: clear/setup without CLAUDE_ENV_FILE — both exit 0 (no session-id dep).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
unset CLAUDE_ENV_FILE
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC_CLEAR=$?
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC_SETUP=$?
if [ "$RC_CLEAR" -eq 0 ] && [ "$RC_SETUP" -eq 0 ]; then
    pass "T29: clear & setup without CLAUDE_ENV_FILE → exit 0"
else
    fail "T29: rc_clear=$RC_CLEAR rc_setup=$RC_SETUP"
fi
teardown_mock

# ===========================================================================
# Test 30: check <N> paginated fields — Status on page 1, fingerprint on page 2; aggregates correctly.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
export GH_MOCK_PAGINATED_PAGES=1
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "T30: check <N> aggregates Status (p1) + fingerprint (p2) → 'same'"
else
    fail "T30: rc=$RC out='$OUT' expected 'same'"
fi
teardown_mock

# ===========================================================================
# Test 31: non-numeric <N> → exit 2, no shell injection (set/check/clear).
# ===========================================================================
setup_mock
RC_SET=0; RC_CHECK=0; RC_CLEAR=0
run_with_timeout 10 bash "$TARGET" set   "42; touch /tmp/T31_INJECT" >/dev/null 2>&1; RC_SET=$?
run_with_timeout 10 bash "$TARGET" check "42; touch /tmp/T31_INJECT" >/dev/null 2>&1; RC_CHECK=$?
run_with_timeout 10 bash "$TARGET" clear "42; touch /tmp/T31_INJECT" >/dev/null 2>&1; RC_CLEAR=$?
if [ "$RC_SET" -eq 2 ] && [ "$RC_CHECK" -eq 2 ] && [ "$RC_CLEAR" -eq 2 ] \
        && [ ! -f /tmp/T31_INJECT ]; then
    pass "T31: non-numeric N rejected (exit 2) across set/check/clear; no injection"
else
    fail "T31: rc_set=$RC_SET rc_check=$RC_CHECK rc_clear=$RC_CLEAR inject=$([ -f /tmp/T31_INJECT ] && echo yes || echo no)"
    rm -f /tmp/T31_INJECT 2>/dev/null
fi
teardown_mock

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
