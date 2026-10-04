#!/usr/bin/env bash
# tests/bin/feature-2434-control-migration/session-start.sh
# Tests: hooks/session-start.js, bin/workflow-control-dir, hooks/workflow-state/state-io/control-dir.js
# Tags: TL2, scope:issue-specific, control-dir, migration, session-start
# TL3 gap: real SessionStart hook firing in a live Claude Code host.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight category: migration.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_mtime.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SESSION_START="$AGENTS_DIR/hooks/session-start.js"
WCD_CLI="$AGENTS_DIR/bin/workflow-control-dir"
UUID="aabbccdd-1111-2222-3333-444455556666"
UUID2="bbccddee-2222-3333-4444-555566667777"

# Helper: run session-start.js with a synthetic SessionStart event
run_session_start() {
  local sid="$1" wf="$2" plans="$3"
  printf '{"session_id":"%s","source":"new"}' "$sid" \
    | WORKFLOW_STATE_DIR="$wf" WORKFLOW_PLANS_DIR="$plans" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$wf/transcripts" \
      node "$SESSION_START" 2>/dev/null
}

# Helper: set mtime to N seconds ago
set_old_mtime() {
  local f="$1" ago="${2:-700}"
  age_files "$ago" "$f"
}

case_begin "session-start-migrates-quiet-uuid" "hooks/session-start.js"
T=$(make_tmp)
harness_isolate "$T"
mkdir -p "$T/workflow-state/transcripts"
printf 'terminal\n' > "$T/plans/${UUID}-detail-plan-terminal.txt"
set_old_mtime "$T/plans/${UUID}-detail-plan-terminal.txt" 700
printf '{}' > "$T/workflow-state/${UUID}.json"
SID2="ccddee11-3333-4444-5555-666677778888"
run_session_start "$SID2" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${UUID}.control/detail-plan-terminal.txt"
if [ -f "$DST" ]; then
  pass "session-start-migrates-quiet-uuid"
else
  fail "session-start-migrates-quiet-uuid" "quiet dormant UUID session should be migrated on session-start (D4 absent?)"
fi
rm -rf "$T"
case_end

case_begin "session-start-migrates-quiet-date" "hooks/session-start.js"
T=$(make_tmp)
harness_isolate "$T"
mkdir -p "$T/workflow-state/transcripts"
DATE_SID="20260601-120000"
printf 'terminal\n' > "$T/plans/${DATE_SID}-detail-plan-terminal.txt"
set_old_mtime "$T/plans/${DATE_SID}-detail-plan-terminal.txt" 700
SID2="ccddee11-3333-4444-5555-666677778888"
run_session_start "$SID2" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${DATE_SID}.control/detail-plan-terminal.txt"
if [ -f "$DST" ]; then
  pass "session-start-migrates-quiet-date"
else
  fail "session-start-migrates-quiet-date" "quiet date-form session should be migrated on session-start (D4 absent?)"
fi
rm -rf "$T"
case_end

case_begin "session-start-skips-recent-sid" "hooks/session-start.js"
T=$(make_tmp)
harness_isolate "$T"
mkdir -p "$T/workflow-state/transcripts"
printf 'terminal\n' > "$T/plans/${UUID}-detail-plan-terminal.txt"
SID2="ccddee11-3333-4444-5555-666677778888"
run_session_start "$SID2" "$(np "$T/workflow-state")" "$(np "$T/plans")" > /dev/null
DST="$T/workflow-state/${UUID}.control/detail-plan-terminal.txt"
if [ -f "$DST" ]; then
  fail "session-start-skips-recent-sid" "recent sid (within quiet period) should not be migrated"
else
  pass "session-start-skips-recent-sid"
fi
rm -rf "$T"
case_end

case_begin "workflow-control-dir-migrates-terminal" "bin/workflow-control-dir"
T=$(make_tmp)
harness_isolate "$T"
printf 'terminal\n' > "$T/plans/${UUID}-detail-plan-terminal.txt"
set_old_mtime "$T/plans/${UUID}-detail-plan-terminal.txt" 700
if [ ! -f "$WCD_CLI" ]; then
  fail "workflow-control-dir-migrates-terminal" "bin/workflow-control-dir not found (implementation absent)"
else
  OUT=$(WORKFLOW_STATE_DIR="$(np "$T/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$T/plans")" \
        node "$WCD_CLI" --session "$UUID" --file "detail-plan-terminal.txt" 2>/dev/null)
  DST="$T/workflow-state/${UUID}.control/detail-plan-terminal.txt"
  if [ -f "$DST" ]; then
    pass "workflow-control-dir-migrates-terminal"
  else
    fail "workflow-control-dir-migrates-terminal" "bin/workflow-control-dir should migrate legacy terminal on first call"
  fi
fi
rm -rf "$T"
case_end

case_begin "static-begin-line-control-dir" "hooks/workflow-state/state-io/control-dir.js"
CTRL_DIR_FILE="$AGENTS_DIR/hooks/workflow-state/state-io/control-dir.js"
BEGIN_LINE="// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---"
if [ ! -f "$CTRL_DIR_FILE" ]; then
  fail "static-begin-line-control-dir" "control-dir.js not found (implementation absent)"
elif grep -qF "$BEGIN_LINE" "$CTRL_DIR_FILE"; then
  pass "static-begin-line-control-dir:begin-line"
  if grep -q "deletion-condition" "$CTRL_DIR_FILE"; then
    pass "static-begin-line-control-dir:deletion-condition"
  else
    fail "static-begin-line-control-dir:deletion-condition" "deletion-condition comment missing in control-dir.js"
  fi
else
  fail "static-begin-line-control-dir" "BEGIN line missing in control-dir.js"
fi
case_end

case_begin "static-begin-line-session-start" "hooks/session-start.js"
BEGIN_LINE="// --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---"
if grep -qF "$BEGIN_LINE" "$SESSION_START"; then
  pass "static-begin-line-session-start:begin-line"
  if grep -q "deletion-condition" "$SESSION_START"; then
    pass "static-begin-line-session-start:deletion-condition"
  else
    fail "static-begin-line-session-start:deletion-condition" "deletion-condition comment missing in session-start.js"
  fi
else
  fail "static-begin-line-session-start" "BEGIN line missing in session-start.js (D4 not implemented)"
fi
case_end

case_begin "check-migration-blocks-clean" "hooks/workflow-state/state-io/control-dir.js"
CHECK_BLOCKS="$AGENTS_DIR/bin/check-migration-blocks.sh"
if [ ! -f "$CHECK_BLOCKS" ]; then
  fail "check-migration-blocks-clean" "bin/check-migration-blocks.sh not found"
else
  OUT=$(bash "$CHECK_BLOCKS" --all 2>/dev/null)
  RC=$?
  if [ "$RC" -ne 0 ]; then
    fail "check-migration-blocks-clean:exit" "expected exit 0, got $RC"
  else
    if printf '%s' "$OUT" | grep -qi "warning.*2026-09-28\|stale.*2026-09-28"; then
      fail "check-migration-blocks-clean:warning" "migration blocks emit a warning: $OUT"
    else
      pass "check-migration-blocks-clean"
    fi
  fi
fi
case_end

echo ""
echo "session-start: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
