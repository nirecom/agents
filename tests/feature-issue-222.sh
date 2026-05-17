#!/bin/bash
# Tests for issue #222 — /issue-close skill refactor + backfill script.
#
# After the refactor:
#   - State routing moved from SKILL.md prose into bin/github-issues/issue-close-triage.sh
#   - Step G moved into bin/github-issues/parent-body-update.sh
#   - Step J moved into bin/github-issues/post-close-sentinels.sh
#   - bin/github-issues/backfill-commit-comments.sh handles retroactive migration
#
# Suites:
#   M-series — gh-mock infrastructure smoke checks
#   T-series — issue-close-triage.sh routing for each (state × sentinel)
#   J-series — post-close-sentinels.sh (resolved-by + appended sentinel)
#   P-series — parent-body-update.sh (parent → no-op vs. edit)
#   R-series — backfill-commit-comments.sh
#   D-series — minimal SKILL.md regression guards on the new prose

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_FILE="$AGENTS_DIR/skills/issue-close/SKILL.md"
TRIAGE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-triage.sh"
PARENT_SCRIPT="$AGENTS_DIR/bin/github-issues/parent-body-update.sh"
SENTINELS_SCRIPT="$AGENTS_DIR/bin/github-issues/post-close-sentinels.sh"
BACKFILL_SCRIPT="$AGENTS_DIR/bin/github-issues/backfill-commit-comments.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

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

# --- Existence gate (RED until every script lands) --------------------------
missing=()
[ -f "$SKILL_FILE" ]      || missing+=("skills/issue-close/SKILL.md")
[ -f "$TRIAGE_SCRIPT" ]   || missing+=("bin/github-issues/issue-close-triage.sh")
[ -f "$PARENT_SCRIPT" ]   || missing+=("bin/github-issues/parent-body-update.sh")
[ -f "$SENTINELS_SCRIPT" ] || missing+=("bin/github-issues/post-close-sentinels.sh")
[ -f "$BACKFILL_SCRIPT" ] || missing+=("bin/github-issues/backfill-commit-comments.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# Ensure mock helpers are executable (Windows checkouts may strip the bit).
# Note: the jq shim was removed after the issue #222 refactor (gh --jq only).
for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/docs/history"
    : > "$TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
    unset GH_MOCK_COMMENT_LOG
}

# Helper: run triage for a given scenario and capture STATE/SENTINEL/ACTION/NEXT_STEPS.
# Sets globals: T_STATE, T_SENTINEL, T_ACTION, T_NEXT_STEPS, T_RC.
# Note: after the issue #222 refactor, triage no longer emits ISSUE_VIEW_FILE.
run_triage() {
    local scenario="$1"
    unset STATE SENTINEL ACTION NEXT_STEPS
    local out
    if out=$(GH_MOCK_SCENARIO="$scenario" run_with_timeout 15 bash "$TRIAGE_SCRIPT" 42 2>/dev/null); then
        T_RC=0
    else
        T_RC=$?
    fi
    # shellcheck disable=SC1090
    eval "$out" 2>/dev/null
    T_STATE="${STATE:-}"
    T_SENTINEL="${SENTINEL:-}"
    T_ACTION="${ACTION:-}"
    T_NEXT_STEPS="${NEXT_STEPS:-}"
}

# ============================================================================
# M-series — mock infrastructure
# ============================================================================

# --- M1: gh mock — closed_no_sentinel scenario returns CLOSED + empty comments
OUT=$(GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 "$MOCK_DIR/gh" issue view 42 --json state,comments 2>/dev/null)
if echo "$OUT" | grep -q '"state":"CLOSED"' && echo "$OUT" | grep -q '"comments":\[\]'; then
    pass "M1: gh mock closed_no_sentinel returns CLOSED + empty comments"
else
    fail "M1: gh mock closed_no_sentinel returns CLOSED + empty comments (got=$OUT)"
fi

# --- M2: gh mock — closed_with_appended_sentinel returns CLOSED + sentinel
OUT=$(GH_MOCK_SCENARIO=closed_with_appended_sentinel \
    run_with_timeout 15 "$MOCK_DIR/gh" issue view 42 --json state,comments 2>/dev/null)
if echo "$OUT" | grep -q '"state":"CLOSED"' && echo "$OUT" | grep -q "issue-close-sentinel: appended"; then
    pass "M2: gh mock closed_with_appended_sentinel returns CLOSED + appended sentinel"
else
    fail "M2: gh mock closed_with_appended_sentinel returns CLOSED + appended sentinel (got=$OUT)"
fi

# --- M3: gh mock — closed_with_resolved_comment returns resolved-by comment
OUT=$(GH_MOCK_SCENARIO=closed_with_resolved_comment \
    run_with_timeout 15 "$MOCK_DIR/gh" issue view 42 --json state,comments 2>/dev/null)
if echo "$OUT" | grep -q "resolved-by: abc1234"; then
    pass "M3: gh mock closed_with_resolved_comment returns resolved-by marker"
else
    fail "M3: gh mock closed_with_resolved_comment returns resolved-by marker (got=$OUT)"
fi

# --- M4: gh mock — closed_with_both returns both markers
OUT=$(GH_MOCK_SCENARIO=closed_with_both \
    run_with_timeout 15 "$MOCK_DIR/gh" issue view 42 --json state,comments 2>/dev/null)
if echo "$OUT" | grep -q "resolved-by: abc1234" && echo "$OUT" | grep -q "issue-close-sentinel: appended"; then
    pass "M4: gh mock closed_with_both returns both markers"
else
    fail "M4: gh mock closed_with_both returns both markers (got=$OUT)"
fi

# --- M5: gh mock `issue comment --body` appends to GH_MOCK_COMMENT_LOG
setup_tmp
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 "$MOCK_DIR/gh" issue comment 42 --body "test body" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q "test body" "$GH_MOCK_COMMENT_LOG"; then
    pass "M5: gh mock 'issue comment --body' appends to GH_MOCK_COMMENT_LOG"
else
    fail "M5: gh mock 'issue comment --body' appends to GH_MOCK_COMMENT_LOG (rc=$RC log=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null))"
fi
teardown_tmp

# ============================================================================
# T-series — issue-close-triage.sh routing
# ============================================================================

# --- T1: OPEN + no sentinel → proceed + B,D,E,F,G,H,J
setup_tmp
run_triage issue_task
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "proceed" ] && [ "$T_NEXT_STEPS" = "B,D,E,F,G,H,J" ]; then
    pass "T1: OPEN + no sentinel → proceed (B,D,E,F,G,H,J)"
else
    fail "T1: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T2: OPEN + pending → resume_e + E,F,G,H,J
setup_tmp
run_triage open_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_e" ] && [ "$T_NEXT_STEPS" = "E,F,G,H,J" ]; then
    pass "T2: OPEN + pending → resume_e (E,F,G,H,J)"
else
    fail "T2: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T3: OPEN + appended → resume_h + G,H,J
setup_tmp
run_triage open_with_appended
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_h" ] && [ "$T_NEXT_STEPS" = "G,H,J" ]; then
    pass "T3: OPEN + appended → resume_h (G,H,J)"
else
    fail "T3: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T4: CLOSED + appended → resume_j + J
setup_tmp
run_triage closed_with_appended_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_j" ] && [ "$T_NEXT_STEPS" = "J" ]; then
    pass "T4: CLOSED + appended → resume_j (J)"
else
    fail "T4: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T5: CLOSED + no sentinel → auto_close_path + B,E,G,J
setup_tmp
run_triage closed_no_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "auto_close_path" ] && [ "$T_NEXT_STEPS" = "B,E,G,J" ]; then
    pass "T5: CLOSED + no sentinel → auto_close_path (B,E,G,J)"
else
    fail "T5: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T6: CLOSED + pending + history hit → stuck_sentinel_only + J
setup_tmp
# Seed history.md so the triage finds #42 already documented.
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Already documented (2026-05-10, abc1234, #42)
Background: x
Changes: y
EOF
run_triage closed_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "stuck_sentinel_only" ] && [ "$T_NEXT_STEPS" = "J" ]; then
    pass "T6: CLOSED + pending + history-has → stuck_sentinel_only (J)"
else
    fail "T6: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T7: CLOSED + pending + history miss → stuck_append_sentinel + E,J
setup_tmp
# history.md intentionally empty.
run_triage closed_with_pending
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "stuck_append_sentinel" ] && [ "$T_NEXT_STEPS" = "E,J" ]; then
    pass "T7: CLOSED + pending + history-missing → stuck_append_sentinel (E,J)"
else
    fail "T7: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS"
fi
teardown_tmp

# --- T8: non-numeric issue number → non-zero exit
setup_tmp
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$TRIAGE_SCRIPT" "42; touch /tmp/T8_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/T8_INJECT ]; then
    pass "T8: non-numeric N rejected, no shell injection"
else
    fail "T8: shell-injection guard failed (rc=$RC, side-effect=$([ -f /tmp/T8_INJECT ] && echo yes || echo no))"
    rm -f /tmp/T8_INJECT 2>/dev/null
fi
teardown_tmp

# --- T9: AGENTS_CONFIG_DIR unset → non-zero exit
setup_tmp
unset AGENTS_CONFIG_DIR
GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$TRIAGE_SCRIPT" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "T9: AGENTS_CONFIG_DIR unset → non-zero exit"
else
    fail "T9: AGENTS_CONFIG_DIR unset should fail (rc=$RC)"
fi
teardown_tmp

# ============================================================================
# J-series — post-close-sentinels.sh
# ============================================================================
# Signature after issue #222 refactor: post-close-sentinels.sh <N> [<commit-hash>]
# (the ISSUE_VIEW_FILE arg was removed; idempotency is now checked via
# `gh issue view --json comments --jq` inline.)

# --- J1: with commit hash + no existing comments → both posted
setup_tmp
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 bash "$SENTINELS_SCRIPT" 42 abc1234 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG")
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: abc1234" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended"; then
    pass "J1: commit hash + empty comments → both resolved-by + sentinel posted"
else
    fail "J1: rc=$RC log=$LOG"
fi
teardown_tmp

# --- J2: without commit hash → only sentinel posted
setup_tmp
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 bash "$SENTINELS_SCRIPT" 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG")
SENTINEL_COUNT=$(echo "$LOG" | grep -c "issue-close-sentinel: appended" || true)
# The sentinel body itself contains "(resolved-by: closes-keyword)", so a
# substring match on "resolved-by: " would also hit the sentinel line. Filter
# out sentinel lines first.
RESOLVED_HASH_ONLY=$(echo "$LOG" | grep "resolved-by: " | grep -vc "issue-close-sentinel" || true)
if [ "$RC" -eq 0 ] && [ "$RESOLVED_HASH_ONLY" -eq 0 ] && [ "$SENTINEL_COUNT" -ge 1 ]; then
    pass "J2: no commit hash → only appended sentinel posted, no resolved-by"
else
    fail "J2: rc=$RC resolved_hash_only=$RESOLVED_HASH_ONLY sentinel=$SENTINEL_COUNT log=$LOG"
fi
teardown_tmp

# --- J3: commit hash but existing resolved-by → resolved-by not re-posted
setup_tmp
GH_MOCK_SCENARIO=closed_with_resolved_comment \
    run_with_timeout 15 bash "$SENTINELS_SCRIPT" 42 abc1234 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG")
# Only the sentinel body should hit the log; no fresh resolved-by comment.
FRESH_RESOLVED=$(echo "$LOG" | grep "resolved-by: abc1234" | grep -vc "issue-close-sentinel" || true)
if [ "$RC" -eq 0 ] && [ "$FRESH_RESOLVED" -eq 0 ]; then
    pass "J3: existing resolved-by → not re-posted (idempotent)"
else
    fail "J3: rc=$RC fresh_resolved=$FRESH_RESOLVED log=$LOG"
fi
teardown_tmp

# --- J4: existing appended sentinel → sentinel not re-posted
setup_tmp
GH_MOCK_SCENARIO=closed_with_appended_sentinel \
    run_with_timeout 15 bash "$SENTINELS_SCRIPT" 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG")
SENTINEL_COUNT=$(echo "$LOG" | grep -c "issue-close-sentinel: appended" || true)
if [ "$RC" -eq 0 ] && [ "$SENTINEL_COUNT" -eq 0 ]; then
    pass "J4: existing appended sentinel → not re-posted (idempotent)"
else
    fail "J4: rc=$RC sentinel_count=$SENTINEL_COUNT log=$LOG"
fi
teardown_tmp

# --- J5: invalid commit hash format → script exits non-zero
setup_tmp
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 bash "$SENTINELS_SCRIPT" 42 "ZZZZ-not-hex" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "J5: invalid commit hash → non-zero exit"
else
    fail "J5: invalid commit hash should fail (rc=$RC)"
fi
teardown_tmp

# --- J6: both already present → no-op, exit 0, log stays empty
setup_tmp
GH_MOCK_SCENARIO=closed_with_both \
    run_with_timeout 15 bash "$SENTINELS_SCRIPT" 42 abc1234 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG")
if [ "$RC" -eq 0 ] && [ -z "$LOG" ]; then
    pass "J6: both resolved-by + appended already present → no-op (exit 0, nothing posted)"
else
    fail "J6: rc=$RC log=$LOG"
fi
teardown_tmp

# ============================================================================
# P-series — parent-body-update.sh
# ============================================================================

# --- P1: no parent → no-op, exit 0, no edit
setup_tmp
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && ! echo "$LOG" | grep -q "EDIT_PARENT_"; then
    pass "P1: no parent → no-op (exit 0, no edit)"
else
    fail "P1: rc=$RC log=$LOG"
fi
teardown_tmp

# --- P2: parent exists → gh issue edit called with body containing '- [x] #42'
setup_tmp
GH_MOCK_SCENARIO=parent_42 \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo 42 >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && echo "$LOG" | grep -q "EDIT_PARENT_99" && echo "$LOG" | grep -q -- "- \[x\] #42"; then
    pass "P2: parent exists → parent body edited with checked checkbox"
else
    fail "P2: rc=$RC log=$LOG"
fi
teardown_tmp

# --- P3: shell-injected N is rejected
setup_tmp
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 15 bash "$PARENT_SCRIPT" owner/repo "42; touch /tmp/P3_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f /tmp/P3_INJECT ]; then
    pass "P3: non-numeric N rejected (no shell injection)"
else
    fail "P3: shell-injection guard failed (rc=$RC, file=$([ -f /tmp/P3_INJECT ] && echo yes || echo no))"
    rm -f /tmp/P3_INJECT 2>/dev/null
fi
teardown_tmp

# ============================================================================
# R-series — backfill-commit-comments.sh
# ============================================================================

# --- R1: script exists and is executable (or has a shebang + readable)
if [ -f "$BACKFILL_SCRIPT" ]; then
    pass "R1: backfill-commit-comments.sh exists"
else
    fail "R1: backfill-commit-comments.sh missing"
fi

# --- R2: --dry-run does not post comments
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Closed-by-keyword task (2026-05-10, abc1234, #42)
Background: closed via PR
Changes: feature shipped
EOF
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && ! grep -qE "(resolved-by|issue-close-sentinel)" "$GH_MOCK_COMMENT_LOG" 2>/dev/null; then
    pass "R2: --dry-run does not post comments"
else
    fail "R2: rc=$RC log=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)"
fi
teardown_tmp

# --- R3: issue with existing appended sentinel → skipped
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Already appended (2026-05-10, abc1234, #42)
Background: x
Changes: y
EOF
GH_MOCK_SCENARIO=closed_with_appended_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && ! grep -qE "(resolved-by|issue-close-sentinel)" "$GH_MOCK_COMMENT_LOG" 2>/dev/null; then
    pass "R3: existing appended sentinel → skipped"
else
    fail "R3: rc=$RC log=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)"
fi
teardown_tmp

# --- R4: missing history.md entry + no git-log hit → no-hash J-2 posted
setup_tmp
# history.md intentionally empty; GIT_MOCK_LOG_FOR_42 not set → no-hash class.
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q "issue-close-sentinel: appended (resolved-by: backfill-no-hash)" \
        "$GH_MOCK_COMMENT_LOG" 2>/dev/null; then
    pass "R4: missing history + no git-log hit → no-hash J-2 posted"
else
    fail "R4: rc=$RC log=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)"
fi
teardown_tmp

# --- R5: hash from history.md → J-1 + J-2 posted
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Closed-by-keyword task (2026-05-10, abc1234, #42)
Background: closed via PR
Changes: feature shipped
EOF
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: abc1234 -->" \
   && echo "$LOG" | grep -q "Resolved by commit" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill, commit=abc1234)"; then
    pass "R5: hash from history → J-1 + J-2 posted"
else
    fail "R5: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R6: --dry-run shows classification, no comments posted
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Closed-by-keyword task (2026-05-10, abc1234, #42)
Background: closed via PR
Changes: feature shipped
EOF
OUT=$(GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run 2>&1)
RC=$?
if [ "$RC" -eq 0 ] \
   && echo "$OUT" | grep -q "\[dry-run class=hash-from-history\]" \
   && ! grep -qE "(resolved-by|issue-close-sentinel)" "$GH_MOCK_COMMENT_LOG" 2>/dev/null; then
    pass "R6: --dry-run shows class, no comments posted"
else
    fail "R6: rc=$RC out=$OUT log=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)"
fi
teardown_tmp

# --- R7: J-1 idempotency — existing resolved-by → J-1 skipped, J-2 posted
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Already has resolved-by (2026-05-10, abc1234, #42)
Background: x
Changes: y
EOF
GH_MOCK_SCENARIO=closed_with_resolved_comment \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
# J-1 must NOT be re-posted (no new "Resolved by commit" line)
# J-2 sentinel MUST be posted
J1_FRESH=$(echo "$LOG" | grep "Resolved by commit" | grep -vc "issue-close-sentinel" || true)
SENTINEL=$(echo "$LOG" | grep -c "issue-close-sentinel: appended" || true)
if [ "$RC" -eq 0 ] && [ "$J1_FRESH" -eq 0 ] && [ "$SENTINEL" -ge 1 ]; then
    pass "R7: existing resolved-by → J-1 skipped (idempotent), J-2 posted"
else
    fail "R7: rc=$RC j1_fresh=$J1_FRESH sentinel=$SENTINEL log=$LOG"
fi
teardown_tmp

# --- R8: git-log fallback + boundary check (#42 does not match #420 pattern)
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Pending hash (2026-05-10, pending, #42)
Background: x
Changes: y
EOF
# GIT_MOCK_LOG_FOR_42 → real hash; GIT_MOCK_LOG_FOR_420 → wronghash (must not appear)
GIT_MOCK_LOG_FOR_42=deadbee \
GIT_MOCK_LOG_FOR_420=wronghash \
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: deadbee" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill-gitlog, commit=deadbee)" \
   && ! echo "$LOG" | grep -q "wronghash"; then
    pass "R8: git-log fallback used; boundary check: #42 pattern does not match #420"
else
    fail "R8: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R9: no-hash — history has (pending) + git-log empty → J-2 only
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: No hash available (2026-05-10, pending, #42)
Background: x
Changes: y
EOF
# GIT_MOCK_LOG_FOR_42 intentionally NOT set
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
J1_POSTED=$(echo "$LOG" | grep -c "Resolved by commit" || true)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill-no-hash)" \
   && [ "$J1_POSTED" -eq 0 ]; then
    pass "R9: no-hash class → J-2 only (no J-1)"
else
    fail "R9: rc=$RC j1_posted=$J1_POSTED log=$LOG"
fi
teardown_tmp

# --- R10: --canary posts exactly 1 per class (3 total)
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: hist-42 (2026-05-10, abc1234, #42)
Background: x
Changes: y

### FEATURE: gitlog-43 (2026-05-10, pending, #43)
Background: x
Changes: y

### FEATURE: nohash-44 (2026-05-10, pending, #44)
Background: x
Changes: y
EOF
export GH_MOCK_ISSUE_NUMBERS="42
43
44"
export GIT_MOCK_LOG_FOR_43=deadbee
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --canary >/dev/null 2>&1
RC=$?
unset GH_MOCK_ISSUE_NUMBERS GIT_MOCK_LOG_FOR_43
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
SENTINEL_COUNT=$(echo "$LOG" | grep -c "issue-close-sentinel: appended" || true)
if [ "$RC" -eq 0 ] && [ "$SENTINEL_COUNT" -eq 3 ]; then
    pass "R10: --canary posts 1 per class (3 total: hash-from-history, hash-from-gitlog, no-hash)"
else
    fail "R10: rc=$RC sentinel_count=$SENTINEL_COUNT log=$LOG"
fi
teardown_tmp

# --- R11: AGENTS_CONFIG_DIR unset → non-zero exit
(unset AGENTS_CONFIG_DIR; bash "$BACKFILL_SCRIPT" >/dev/null 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "R11: AGENTS_CONFIG_DIR unset → non-zero exit"
else
    fail "R11: AGENTS_CONFIG_DIR unset should fail (rc=$RC)"
fi

# --- R12: unknown flag → non-zero exit
setup_tmp
bash "$BACKFILL_SCRIPT" --unknown-flag >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    pass "R12: unknown flag → non-zero exit"
else
    fail "R12: unknown flag should fail (rc=$RC)"
fi
teardown_tmp

# --- R13: Fix A+B — INCIDENT: #N: heading with hash in first paren → hash-from-history
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### INCIDENT: #42: Some incident title (abc1234) (2026-05-10)
Cause: x
Fix: y
EOF
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: abc1234 -->" \
   && echo "$LOG" | grep -q "Resolved by commit" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill, commit=abc1234)"; then
    pass "R13: Fix A+B — INCIDENT: #N: format, hash in first paren → hash-from-history"
else
    fail "R13: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R14: archive path — history.md empty, hash in docs/history/2026.md
setup_tmp
# history.md is intentionally empty (setup_tmp creates it blank)
cat > "$TMP/docs/history/2026.md" <<'EOF'
### INCIDENT: #42: Archived incident title (abc1234) (2026-01-15)
Cause: old cause
Fix: old fix
EOF
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: abc1234 -->" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill, commit=abc1234)"; then
    pass "R14: archive path — hash extracted from docs/history/*.md (HISTORY_DIR branch)"
else
    fail "R14: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R15: Fix B only — hash in first paren group, date in last → tail -n 1 bypass needed
# Pattern already matches (#42) via [,)]; Fix A is NOT required here.
# Only Fix B (removing tail -n 1) makes this pass.
setup_tmp
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Hash-first heading (abc1234) (#42) (2026-05-10)
Background: hash appears before issue number
Changes: shipped
EOF
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: abc1234 -->" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill, commit=abc1234)"; then
    pass "R15: Fix B — hash in first paren group, date-only in last → hash extracted"
else
    fail "R15: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R16: Tier 0a — closedByPullRequestsReferences → mergeCommit.oid → hash-from-pr-link
setup_tmp
export GH_MOCK_PR_MERGE_COMMIT_FOR_42="cafe1234"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
unset GH_MOCK_PR_MERGE_COMMIT_FOR_42
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: cafe1234 -->" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill-pr-link, commit=cafe1234)"; then
    pass "R16: Tier 0a — PR mergeCommit.oid → hash-from-pr-link"
else
    fail "R16: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R17: Tier 0b — body contains hex → hash-from-body
setup_tmp
export GH_MOCK_BODY_FOR_42="Resolved upstream in deadb0de — see thread."
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
unset GH_MOCK_BODY_FOR_42
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: deadb0de -->" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill-body, commit=deadb0de)"; then
    pass "R17: Tier 0b — issue body hex → hash-from-body"
else
    fail "R17: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R18: Tier 1.5 — git log -S history introducer → hash-from-history-introducer
setup_tmp
export GIT_MOCK_ARGV_LOG="$TMP/git-argv-r18.log"
export GH_MOCK_TITLE_FOR_42="feat: backfill hash discovery extension"
export GIT_MOCK_LOG_S_RESULT="beef5678 docs(history): record backfill tier expansion"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
unset GH_MOCK_TITLE_FOR_42 GIT_MOCK_LOG_S_RESULT
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
ARGV=$(cat "$GIT_MOCK_ARGV_LOG" 2>/dev/null)
unset GIT_MOCK_ARGV_LOG
if [ "$RC" -eq 0 ] \
   && echo "$LOG"  | grep -q "resolved-by: beef5678 -->" \
   && echo "$LOG"  | grep -q "issue-close-sentinel: appended (resolved-by: backfill-history-introducer, commit=beef5678)" \
   && echo "$ARGV" | grep -q -- '--reverse' \
   && echo "$ARGV" | grep -q 'feat: backfill hash discovery extension' \
   && echo "$ARGV" | grep -q -- '-- docs/history.md' \
   && ! echo "$ARGV" | grep -q 'diff-filter'; then
    pass "R18: Tier 1.5 — flags=--all --reverse -S, no --diff-filter"
else
    fail "R18: rc=$RC log=$LOG argv=$ARGV"
fi
teardown_tmp

# --- R19: priority chain — Tier 0a wins when all tiers can hit
setup_tmp
export GIT_MOCK_ARGV_LOG="$TMP/git-argv-r19.log"
cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: Priority test (2026-05-10, abc12345, #42)
Background: also references deadb0de in body
Changes: shipped
EOF
export GH_MOCK_PR_MERGE_COMMIT_FOR_42="cafe1234"
export GH_MOCK_BODY_FOR_42="See commit deadb0de for context."
export GH_MOCK_TITLE_FOR_42="Priority test header"
export GIT_MOCK_LOG_S_RESULT="beef5678 docs(history): record priority test"
export GIT_MOCK_LOG_FOR_42="feedface"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
unset GH_MOCK_PR_MERGE_COMMIT_FOR_42 GH_MOCK_BODY_FOR_42 GH_MOCK_TITLE_FOR_42 \
      GIT_MOCK_LOG_S_RESULT GIT_MOCK_LOG_FOR_42
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
ARGV_R19=$(cat "$GIT_MOCK_ARGV_LOG" 2>/dev/null)
unset GIT_MOCK_ARGV_LOG
if [ "$RC" -eq 0 ] \
   && echo "$LOG"      | grep -q "resolved-by: cafe1234 -->" \
   && echo "$LOG"      | grep -q "issue-close-sentinel: appended (resolved-by: backfill-pr-link, commit=cafe1234)" \
   && ! echo "$LOG"    | grep -qE "(deadb0de|abc12345|beef5678|feedface)" \
   && ! echo "$ARGV_R19" | grep -q 'Priority test header'; then
    pass "R19: priority — Tier 0a wins, Tier 1.5 not invoked"
else
    fail "R19: rc=$RC log=$LOG argv=$ARGV_R19"
fi
teardown_tmp

# --- R20: Tier 0b rejects 41+ char hex runs (no bogus SHA from truncation)
setup_tmp
# 41 chars: truncating to 40 would be syntactically valid but semantically bogus.
export GH_MOCK_BODY_FOR_42="Spurious hex: 0123456789abcdef0123456789abcdef0123456789a"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r20.out" 2>&1
RC=$?
unset GH_MOCK_BODY_FOR_42
if [ "$RC" -eq 0 ] \
   && ! grep -q 'class=hash-from-body' "$TMP/r20.out" \
   && ! grep -q '0123456789abcdef0123456789abcdef0123456789' "$TMP/r20.out"; then
    pass "R20: Tier 0b — 41-char hex run rejected (falls through)"
else
    fail "R20: rc=$RC out=$(cat "$TMP/r20.out")"
fi
teardown_tmp

# --- R21: canary cap = 6 classes; per-issue slug dispatch verified
setup_tmp
export GIT_MOCK_ARGV_LOG="$TMP/git-argv-r21.log"

cat >> "$TMP/docs/history.md" <<'EOF'

### FEATURE: e1 (2026-05-01, aaa1111, #101)
### FEATURE: e2 (2026-05-02, aaa2222, #102)
EOF

export GH_MOCK_PR_MERGE_COMMIT_FOR_103="bbbb111"
export GH_MOCK_PR_MERGE_COMMIT_FOR_104="bbbb222"
export GH_MOCK_BODY_FOR_105="See cccc111"
export GH_MOCK_BODY_FOR_106="See cccc222"
export GH_MOCK_TITLE_FOR_107="canary 107 entry"
export GH_MOCK_TITLE_FOR_108="canary 108 entry"
export GIT_MOCK_LOG_S_RESULT_canary_107_entry="dddd111 docs: 107"
export GIT_MOCK_LOG_S_RESULT_canary_108_entry="dddd222 docs: 108"
export GIT_MOCK_LOG_FOR_109="eeee111"
export GIT_MOCK_LOG_FOR_110="eeee222"

GH_MOCK_SCENARIO=canary_six_class \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --canary --dry-run >"$TMP/r21.out" 2>&1
RC=$?
unset GH_MOCK_PR_MERGE_COMMIT_FOR_103 GH_MOCK_PR_MERGE_COMMIT_FOR_104 \
      GH_MOCK_BODY_FOR_105 GH_MOCK_BODY_FOR_106 \
      GH_MOCK_TITLE_FOR_107 GH_MOCK_TITLE_FOR_108 \
      GIT_MOCK_LOG_S_RESULT_canary_107_entry GIT_MOCK_LOG_S_RESULT_canary_108_entry \
      GIT_MOCK_LOG_FOR_109 GIT_MOCK_LOG_FOR_110 GIT_MOCK_ARGV_LOG

DRY_COUNT=$(grep -c '^\[dry-run class=' "$TMP/r21.out" 2>/dev/null || echo 0)
SKIP_COUNT=$(grep -c '^\[canary-skip class=' "$TMP/r21.out" 2>/dev/null || echo 0)

if [ "$RC" -eq 0 ] \
   && [ "$DRY_COUNT"  -eq 6 ] \
   && [ "$SKIP_COUNT" -eq 6 ] \
   && grep -q 'class=hash-from-pr-link' "$TMP/r21.out" \
   && grep -q 'class=hash-from-body' "$TMP/r21.out" \
   && grep -qE 'class=hash-from-history[^-]' "$TMP/r21.out" \
   && grep -q 'class=hash-from-history-introducer' "$TMP/r21.out" \
   && grep -q 'class=hash-from-gitlog' "$TMP/r21.out" \
   && grep -q 'class=no-hash' "$TMP/r21.out" \
   && grep -q 'canary-skip class=hash-from-pr-link' "$TMP/r21.out" \
   && grep -q 'canary-skip class=hash-from-body' "$TMP/r21.out" \
   && grep -qE 'canary-skip class=hash-from-history[^-]' "$TMP/r21.out" \
   && grep -q 'canary-skip class=hash-from-history-introducer' "$TMP/r21.out" \
   && grep -q 'canary-skip class=hash-from-gitlog' "$TMP/r21.out" \
   && grep -q 'canary-skip class=no-hash' "$TMP/r21.out" \
   && grep -q 'hash=dddd111' "$TMP/r21.out" \
   && ! grep -q 'hash=dddd222' "$TMP/r21.out"; then
    pass "R21: canary cap = 6 classes; per-issue slug dispatch verified; canary-skip per duplicate"
else
    fail "R21: rc=$RC dry=$DRY_COUNT skip=$SKIP_COUNT out=$(cat "$TMP/r21.out")"
fi
teardown_tmp

# --- R22: regression — non-comment lines must NOT contain --diff-filter
if ! grep -nE '^[[:space:]]*[^#[:space:]].*--diff-filter' "$BACKFILL_SCRIPT" >/dev/null 2>&1; then
    pass "R22: script has no --diff-filter in code (comments allowed)"
else
    fail "R22: script contains --diff-filter outside comments — would exclude history.md append commits"
fi

# --- R23: Tier 0a — empty mergeCommit (no merged PR) → falls through to next tier
setup_tmp
export GH_MOCK_PR_MERGE_COMMIT_FOR_42=""
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r23.out" 2>&1
RC=$?
unset GH_MOCK_PR_MERGE_COMMIT_FOR_42
if [ "$RC" -eq 0 ] \
   && ! grep -q 'class=hash-from-pr-link' "$TMP/r23.out"; then
    pass "R23: Tier 0a — empty PR merge commit → falls through (hash-from-pr-link not selected)"
else
    fail "R23: rc=$RC out=$(cat "$TMP/r23.out")"
fi
teardown_tmp

# --- R24: Tier 0b — exactly 7-char hex (minimum boundary) → hash-from-body
setup_tmp
export GH_MOCK_BODY_FOR_42="deadbee"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" >/dev/null 2>&1
RC=$?
unset GH_MOCK_BODY_FOR_42
LOG=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] \
   && echo "$LOG" | grep -q "resolved-by: deadbee -->" \
   && echo "$LOG" | grep -q "issue-close-sentinel: appended (resolved-by: backfill-body, commit=deadbee)"; then
    pass "R24: Tier 0b — 7-char hex (minimum boundary) accepted → hash-from-body"
else
    fail "R24: rc=$RC log=$LOG"
fi
teardown_tmp

# --- R25: Tier 0b — 6-char hex (below minimum) → falls through
setup_tmp
export GH_MOCK_BODY_FOR_42="deadbe"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r25.out" 2>&1
RC=$?
unset GH_MOCK_BODY_FOR_42
if [ "$RC" -eq 0 ] \
   && ! grep -q 'class=hash-from-body' "$TMP/r25.out"; then
    pass "R25: Tier 0b — 6-char hex (below minimum) rejected → falls through"
else
    fail "R25: rc=$RC out=$(cat "$TMP/r25.out")"
fi
teardown_tmp

# --- R26: Tier 1.5 blacklist — blacklisted hash falls through to no-hash
setup_tmp
export GH_MOCK_TITLE_FOR_42="bulk import candidate title"
export GIT_MOCK_LOG_S_RESULT="3969773 feat(agents-split): add 39 tests from dotfiles (step 11)"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r26.out" 2>&1
RC=$?
unset GH_MOCK_TITLE_FOR_42 GIT_MOCK_LOG_S_RESULT
if [ "$RC" -eq 0 ] \
   && grep -q 'class=no-hash' "$TMP/r26.out" \
   && ! grep -q 'class=hash-from-history-introducer' "$TMP/r26.out"; then
    pass "R26: Tier 1.5 blacklist — blacklisted hash 3969773 falls through to no-hash"
else
    fail "R26: rc=$RC out=$(cat "$TMP/r26.out")"
fi
teardown_tmp

# --- R27: Tier 1.5 — title < 8 chars → git log not invoked, falls through
setup_tmp
export GIT_MOCK_ARGV_LOG="$TMP/git-argv-r27.log"
export GH_MOCK_TITLE_FOR_42="short"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r27.out" 2>&1
RC=$?
unset GH_MOCK_TITLE_FOR_42
ARGV_R27=$(cat "$GIT_MOCK_ARGV_LOG" 2>/dev/null)
unset GIT_MOCK_ARGV_LOG
if [ "$RC" -eq 0 ] \
   && ! grep -q 'class=hash-from-history-introducer' "$TMP/r27.out" \
   && ! echo "$ARGV_R27" | grep -q -- '-S'; then
    pass "R27: Tier 1.5 — title < 8 chars → git log -S not invoked, no hash-from-history-introducer"
else
    fail "R27: rc=$RC out=$(cat "$TMP/r27.out") argv=$ARGV_R27"
fi
teardown_tmp

# --- R28: Tier 1.5 — empty title → falls through (no git log invoked)
setup_tmp
export GIT_MOCK_ARGV_LOG="$TMP/git-argv-r28.log"
export GH_MOCK_TITLE_FOR_42=""
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r28.out" 2>&1
RC=$?
unset GH_MOCK_TITLE_FOR_42
ARGV_R28=$(cat "$GIT_MOCK_ARGV_LOG" 2>/dev/null)
unset GIT_MOCK_ARGV_LOG
if [ "$RC" -eq 0 ] \
   && ! grep -q 'class=hash-from-history-introducer' "$TMP/r28.out" \
   && ! echo "$ARGV_R28" | grep -q -- '-S'; then
    pass "R28: Tier 1.5 — empty title → git log -S not invoked, no hash-from-history-introducer"
else
    fail "R28: rc=$RC out=$(cat "$TMP/r28.out") argv=$ARGV_R28"
fi
teardown_tmp

# --- R29: Tier 1.5 blacklist with Tier 2 fallback — blacklisted hash → hash-from-gitlog
setup_tmp
export GH_MOCK_TITLE_FOR_42="bulk import candidate title"
export GIT_MOCK_LOG_S_RESULT="3969773 feat(agents-split): add 39 tests from dotfiles (step 11)"
export GIT_MOCK_LOG_FOR_42="deadbee"
GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" --dry-run >"$TMP/r29.out" 2>&1
RC=$?
unset GH_MOCK_TITLE_FOR_42 GIT_MOCK_LOG_S_RESULT GIT_MOCK_LOG_FOR_42
if [ "$RC" -eq 0 ] \
   && grep -q 'class=hash-from-gitlog' "$TMP/r29.out" \
   && grep -q 'hash=deadbee' "$TMP/r29.out" \
   && ! grep -q 'class=hash-from-history-introducer' "$TMP/r29.out"; then
    pass "R29: Tier 1.5 blacklist + Tier 2 fallback — blacklisted hash 3969773, Tier 2 returns deadbee"
else
    fail "R29: rc=$RC out=$(cat "$TMP/r29.out")"
fi
teardown_tmp

# ============================================================================
# D-series — SKILL.md regression guards (minimal, after refactor)
# ============================================================================

# --- D1: SKILL.md mentions issue-close-triage.sh as routing SSOT
if grep -q "issue-close-triage.sh" "$SKILL_FILE"; then
    pass "D1: SKILL.md references issue-close-triage.sh (routing SSOT)"
else
    fail "D1: SKILL.md missing reference to issue-close-triage.sh"
fi

# --- D2: SKILL.md still documents Step J
if grep -qE "^## Step J" "$SKILL_FILE"; then
    pass "D2: SKILL.md has '## Step J' section"
else
    fail "D2: SKILL.md missing '## Step J' section"
fi

# --- D3: SKILL.md mentions auto_close_path (the new ACTION name)
if grep -q "auto_close_path" "$SKILL_FILE"; then
    pass "D3: SKILL.md mentions auto_close_path"
else
    fail "D3: SKILL.md missing auto_close_path"
fi

# --- D4: SKILL.md does NOT instruct 'abort' on a CLOSED-state line
# Old prose used "abort" to reject closes-keyword path; new prose must not.
if grep -nE 'CLOSED.*abort|abort.*CLOSED' "$SKILL_FILE" >/dev/null; then
    fail "D4: SKILL.md still pairs 'abort' with CLOSED (regression)"
else
    pass "D4: SKILL.md no longer pairs 'abort' with CLOSED"
fi

# --- D5: SKILL.md mentions `closes #N` (the auto-close keyword flow)
if grep -qE "closes #N|closes-keyword" "$SKILL_FILE"; then
    pass "D5: SKILL.md documents closes #N / closes-keyword flow"
else
    fail "D5: SKILL.md missing closes #N / closes-keyword reference"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
