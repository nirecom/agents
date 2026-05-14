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
for f in gh doc-append; do
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

# --- R4: missing history.md entry → warn + skip
setup_tmp
# history.md intentionally empty.
OUT=$(GH_MOCK_SCENARIO=closed_no_sentinel \
    run_with_timeout 30 bash "$BACKFILL_SCRIPT" 2>&1)
if ! grep -qE "(resolved-by|issue-close-sentinel)" "$GH_MOCK_COMMENT_LOG" 2>/dev/null \
   && echo "$OUT" | grep -qiE 'warn|skip|not (found|in history)|missing'; then
    pass "R4: missing history.md entry → warn + skip"
else
    fail "R4: out=$OUT log=$(cat "$GH_MOCK_COMMENT_LOG" 2>/dev/null)"
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
