#!/usr/bin/env bash
# Tests: hooks/workflow-mark/branching-handler.js, hooks/lib/workflow-state/state-io.js, hooks/lib/workflow-state/resolve-worktree-path.js
# Tags: fix, branching-handler, state-io, session-worktree, scope:issue-specific
#
# Tests for issue #950: branching-handler.js must write state.session_worktree
# when the WORKFLOW_BRANCHING_COMPLETE decision includes a "worktree:" segment.
#
# BH-1: BRANCHING_COMPLETE sentinel with worktree: path → state.session_worktree written
# BH-2: Regression guard — branching_complete.decision still written (not dropped)
# BH-3: Stale clear — main-only decision (no worktree: segment) → state.session_worktree=null
# BH-4: decision with non-existent path → state.session_worktree not written / null
#
# BH-1, BH-3, BH-4 are EXPECTED TO FAIL until the source fix lands.
# BH-2 is a regression guard that MUST PASS both before and after the fix.
#
# L3 gap (what this test does NOT catch):
# - That the hook fires in a real Claude Code session triggered by an actual sentinel
# - End-to-end: sentinel emission → hook dispatch → state persisted → resolveSessionWorktreePath reads it
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_JS="$AGENTS_DIR/hooks/workflow-mark.js"
RUN_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found"
  exit 77
fi
if [ ! -f "$HOOK_JS" ]; then
  echo "SKIP: hooks/workflow-mark.js not present"
  exit 77
fi

# ---------------------------------------------------------------------------
# Fixtures: a real git repo pair (main + linked worktree) so isMainWorktree()
# can distinguish them when the source fix calls it.
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t bh950-test)"
MAIN_REPO="$TMPDIR_BASE/main"
WTA="$TMPDIR_BASE/wtA"
WF_DIR="$TMPDIR_BASE/workflow-state"
SESSION_ID="fix-950-test-sid"

cleanup() {
  git -C "$MAIN_REPO" worktree remove --force "$WTA" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MAIN_REPO" "$WF_DIR"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
touch "$MAIN_REPO/.gitkeep"
git -C "$MAIN_REPO" add .gitkeep
git -C "$MAIN_REPO" commit -q -m "init"
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-950" "$WTA"

# Windows: node needs forward-slash paths on Git Bash
if command -v cygpath >/dev/null 2>&1; then
  MAIN_NODE="$(cygpath -m "$MAIN_REPO")"
  WTA_NODE="$(cygpath -m "$WTA")"
  WF_DIR_NODE="$(cygpath -m "$WF_DIR")"
  AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
  MAIN_NODE="$MAIN_REPO"
  WTA_NODE="$WTA"
  WF_DIR_NODE="$WF_DIR"
  AGENTS_NODE="$AGENTS_DIR"
fi

NONEXISTENT_NODE="$TMPDIR_BASE/does-not-exist"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a minimal workflow state JSON with cwd pointing to the main worktree.
# (Simulates a session started from main — the mid-session /worktree-start case.)
write_state_main_cwd() {
  cat > "$WF_DIR/$SESSION_ID.json" <<EOF
{
  "version": 1,
  "session_id": "$SESSION_ID",
  "created_at": "2026-07-18T00:00:00.000Z",
  "cwd": "$MAIN_NODE",
  "git_branch": "main",
  "steps": {
    "branching_complete": { "status": "pending", "updated_at": null }
  }
}
EOF
}

# Build a JSON payload for workflow-mark.js.
# $1: Bash command string (the sentinel echo)
# $2: session_id (embedded in payload so resolveSessionId() finds it)
build_payload() {
  local cmd="$1"
  local sid="$2"
  # Escape double-quotes inside cmd for embedding in JSON string.
  local cmd_escaped
  cmd_escaped="$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0},"session_id":"%s"}' \
    "$cmd_escaped" "$sid"
}

# Run the hook with a given sentinel command and session_id.
# Sets MARK_RC, MARK_OUT, MARK_ERR.
MARK_RC=0
MARK_OUT=""
MARK_ERR=""
run_hook() {
  local sentinel_cmd="$1"
  local sid="${2:-$SESSION_ID}"
  local payload
  payload="$(build_payload "$sentinel_cmd" "$sid")"
  local out_file="$TMPDIR_BASE/out-$$.txt"
  local err_file="$TMPDIR_BASE/err-$$.txt"
  local rc=0
  ( \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    AGENTS_CONFIG_DIR="$AGENTS_NODE" \
      bash "$RUN_TIMEOUT" 30 node "$HOOK_JS" <<< "$payload" \
      > "$out_file" 2> "$err_file"
  ) || rc=$?
  MARK_RC="$rc"
  MARK_OUT="$(cat "$out_file" 2>/dev/null)"
  MARK_ERR="$(cat "$err_file" 2>/dev/null)"
}

# Read a top-level field from the state file.
# $1: jq-style key (e.g. ".session_worktree")
read_state_field() {
  local field="$1"
  node -e "
const fs = require('fs');
try {
  const s = JSON.parse(fs.readFileSync('$WF_DIR_NODE/$SESSION_ID.json', 'utf8'));
  const v = s$field;
  process.stdout.write(v === null || v === undefined ? '' : String(v));
} catch(e) { process.stdout.write('READ_ERROR'); }
" 2>/dev/null
}

# Read steps[branching_complete].decision from state file.
read_bc_decision() {
  node -e "
const fs = require('fs');
try {
  const s = JSON.parse(fs.readFileSync('$WF_DIR_NODE/$SESSION_ID.json', 'utf8'));
  const v = s && s.steps && s.steps.branching_complete && s.steps.branching_complete.decision;
  process.stdout.write(v === null || v === undefined ? '' : String(v));
} catch(e) { process.stdout.write('READ_ERROR'); }
" 2>/dev/null
}

# ===========================================================================
# BH-1: BRANCHING_COMPLETE with "worktree: <path>" in decision
#        → state.session_worktree must be set to that path.
# EXPECTED TO FAIL before source fix.
# ===========================================================================
echo "--- BH-1: session_worktree written from worktree: segment ---"
write_state_main_cwd
DECISION_WITH_WT="branch:wt-branch-950 worktree:$WTA_NODE"
run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_WITH_WT>>\""
bh1_got="$(read_state_field '.session_worktree')"
if [[ "$bh1_got" = "$WTA_NODE" ]]; then
  pass "BH-1: state.session_worktree='$bh1_got' (worktree path written)"
else
  fail "BH-1: state.session_worktree='$bh1_got', expected '$WTA_NODE' [expected FAIL before source fix]"
fi

# ===========================================================================
# BH-2: Regression guard — steps.branching_complete.decision still written.
# MUST PASS before AND after the fix.
# ===========================================================================
echo "--- BH-2: regression guard — decision field still written ---"
write_state_main_cwd
DECISION_PLAIN="branch:wt-branch-950 worktree:$WTA_NODE"
run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_PLAIN>>\""
bh2_got="$(read_bc_decision)"
if [[ -n "$bh2_got" ]]; then
  pass "BH-2: steps.branching_complete.decision='$bh2_got' (not dropped)"
else
  fail "BH-2: steps.branching_complete.decision is empty — regression! decision field must still be written"
fi

# ===========================================================================
# BH-3: BRANCHING_COMPLETE with no "worktree:" segment (main-only decision)
#        → state.session_worktree must be null / absent (stale clear).
# EXPECTED TO FAIL before source fix (field simply won't exist yet).
# ===========================================================================
echo "--- BH-3: stale clear — no worktree: segment -> session_worktree=null ---"
# Pre-seed state with a stale session_worktree to confirm it gets cleared.
cat > "$WF_DIR/$SESSION_ID.json" <<EOF
{
  "version": 1,
  "session_id": "$SESSION_ID",
  "created_at": "2026-07-18T00:00:00.000Z",
  "cwd": "$MAIN_NODE",
  "session_worktree": "$WTA_NODE",
  "git_branch": "main",
  "steps": {
    "branching_complete": { "status": "pending", "updated_at": null }
  }
}
EOF
DECISION_MAIN_ONLY="working-directly-on-main"
run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_MAIN_ONLY>>\""
bh3_got="$(read_state_field '.session_worktree')"
if [[ -z "$bh3_got" ]]; then
  pass "BH-3: state.session_worktree is empty/null after main-only decision (stale cleared)"
else
  fail "BH-3: state.session_worktree='$bh3_got', expected empty/null [expected FAIL before source fix]"
fi

# ===========================================================================
# BH-4: BRANCHING_COMPLETE with a non-existent "worktree:" path
#        → state.session_worktree must NOT be written (or must be null).
# EXPECTED TO FAIL before source fix (field will remain absent when no write happens).
# ===========================================================================
echo "--- BH-4: non-existent worktree path -> session_worktree not set / null ---"
write_state_main_cwd
DECISION_NONEXISTENT="branch:wt-branch-950 worktree:$NONEXISTENT_NODE"
run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_NONEXISTENT>>\""
bh4_got="$(read_state_field '.session_worktree')"
if [[ -z "$bh4_got" ]]; then
  pass "BH-4: state.session_worktree empty for non-existent path (rejected)"
else
  fail "BH-4: state.session_worktree='$bh4_got', expected empty/null for non-existent path [expected FAIL before source fix]"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
