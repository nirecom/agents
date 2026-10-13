#!/usr/bin/env bash
# Tests: hooks/workflow-mark/branching-handler.js, hooks/workflow-state/state-io.js, hooks/workflow-state/resolve-worktree-path.js
# Tags: fix, branching-handler, state-io, session-worktree, scope:issue-specific, plan-approval, delivery-reconcile

# Issue #950: branching-handler.js must write state.session_worktree when the
# WORKFLOW_BRANCHING_COMPLETE decision includes a "worktree:" segment.
# BH-1 worktree: path → session_worktree written; BH-2 regression guard: branching_complete.decision still written;
# BH-3 stale clear: main-only decision → session_worktree=null; BH-4 non-existent path → not written / null.
# #2277 (S12): branching is recorded only when detail is approved or skipped, so BH-1..4 seed
# detail=skipped; BH-5..8 (detail unapproved / corrupt state / no state) must write nothing.
# L3 gap: real-session hook firing on an actual sentinel, and sentinel → dispatch → persisted → resolveSessionWorktreePath end-to-end.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
RUN_TIMEOUT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

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
  cd / 2>/dev/null || true
  git -C "$MAIN_REPO" worktree remove --force "$WTA" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MAIN_REPO" "$WF_DIR"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config core.hooksPath /dev/null 2>/dev/null || true
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
  AGENTS_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
  MAIN_NODE="$MAIN_REPO"
  WTA_NODE="$WTA"
  WF_DIR_NODE="$WF_DIR"
  AGENTS_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

NONEXISTENT_NODE="$TMPDIR_BASE/does-not-exist"

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside WORKFLOW_STATE_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
WORKFLOW_PLANS_DIR="$(cygpath -m "$WORKFLOW_PLANS_DIR" 2>/dev/null || echo "$WORKFLOW_PLANS_DIR")"
export WORKFLOW_PLANS_DIR
# isolation (#2512): the state dir is pinned file-wide too, not only per hook call.
export WORKFLOW_STATE_DIR="$WF_DIR_NODE"
# #2277: the CONFIRM_DETAIL off waiver is read from $AGENTS_MAIN_ROOT/.env — pin it on in a
# decoy root; never resolve the live session, the developer's transcripts, or the worktree repo.
mkdir -p "$TMPDIR_BASE/decoy-root" "$TMPDIR_BASE/no-transcripts"
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\n' > "$TMPDIR_BASE/decoy-root/.env"
export AGENTS_MAIN_ROOT="$(cygpath -m "$TMPDIR_BASE/decoy-root" 2>/dev/null || echo "$TMPDIR_BASE/decoy-root")"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/no-transcripts"
unset CLAUDE_CODE_SESSION_ID CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
# #2527 3-13: BRANCHING_COMPLETE reconciles the delivery path against the declared worktree
# and the repo cwd. Pin both: the repo cwd is the fixture MAIN repo (never the inherited real
# linked worktree) and enforcement is on, so the WTA decisions are pull_request + linked
# worktree of the same repo; BH-3 (no worktree:) runs with enforcement off (main-direct).
export CLAUDE_PROJECT_DIR="$MAIN_NODE"
export ENFORCE_WORKTREE=on
export ENFORCE_WORKTREE_EXCLUDE=
cd "$TMPDIR_BASE" || exit 1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a minimal workflow state JSON with cwd pointing to the main worktree.
# (Simulates a session started from main — the mid-session /worktree-start case.)
# $1: detail status (default skipped: #2277 records branching only after detail is approved/skipped)
# $2: session id (default $SESSION_ID)
write_state_main_cwd() {
  local detail_status="${1:-skipped}" sid="${2:-$SESSION_ID}"
  cat > "$WF_DIR/$sid.json" <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-07-18T00:00:00.000Z",
  "cwd": "$MAIN_NODE",
  "git_branch": "main",
  "steps": {
    "detail": { "status": "$detail_status", "updated_at": "2026-07-18T00:00:00.000Z" },
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
    WORKFLOW_STATE_DIR="$WF_DIR_NODE" \
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

# Read steps[branching_complete].decision through readState (a v2 file keeps steps as events).
read_bc_decision() {
  node -e "
try {
  const s = require(process.argv[1] + '/hooks/workflow-state').readState('$SESSION_ID');
  const v = s && s.steps && s.steps.branching_complete && s.steps.branching_complete.decision;
  process.stdout.write(v === null || v === undefined ? '' : String(v));
} catch(e) { process.stdout.write('READ_ERROR'); }
" "$AGENTS_NODE" 2>/dev/null
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
if [[ "$bh2_got" = "$DECISION_PLAIN" ]]; then
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
    "detail": { "status": "skipped", "updated_at": "2026-07-18T00:00:00.000Z" },
    "branching_complete": { "status": "pending", "updated_at": null }
  }
}
EOF
DECISION_MAIN_ONLY="working-directly-on-main"
ENFORCE_WORKTREE=off run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_MAIN_ONLY>>\""
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

# ===========================================================================
# BH-5..9 (#2277 S12): BRANCHING_COMPLETE records nothing unless detail is
# approved or skipped — no branching_complete, session_worktree or baseline.
# ===========================================================================

# bc_snapshot <sid> — "bc=<status> decision=<d> wt=<path> mbb=<yes|no>" via readState.
bc_snapshot() {
  node -e "
const ws = require(process.argv[1] + '/hooks/workflow-state');
try {
  const s = ws.readState(process.argv[2]);
  if (!s) { process.stdout.write('NO_STATE'); process.exit(0); }
  const bc = (s.steps && s.steps.branching_complete) || {};
  process.stdout.write('bc=' + (bc.status || '') + ' decision=' + (bc.decision || '') +
    ' wt=' + (s.session_worktree || '') + ' mbb=' + (s.merge_base_baseline ? 'yes' : 'no'));
} catch (e) { process.stdout.write('READ_ERROR ' + e.message); }
" "$AGENTS_NODE" "$1" 2>/dev/null
}

DECISION_GATED="branch:wt-branch-950 worktree:$WTA_NODE"
NOTHING_WRITTEN="bc=pending decision= wt= mbb=no"

# _bh_unapproved <id> <detail-status>
_bh_unapproved() {
  local id="$1" sid="fix-950-${1,,}"
  write_state_main_cwd "$2" "$sid"
  run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_GATED>>\"" "$sid"
  local got; got="$(bc_snapshot "$sid")"
  if [[ "$got" = "$NOTHING_WRITTEN" ]]; then
    pass "$id: detail=$2 without approval → nothing recorded ($got)"
  else
    fail "$id: detail=$2 without approval → got '$got', expected '$NOTHING_WRITTEN'"
  fi
  if [[ "$MARK_OUT$MARK_ERR" == *WORKFLOW_CONFIRM_DETAIL* ]]; then
    pass "$id: refusal guidance names WORKFLOW_CONFIRM_DETAIL"
  else
    fail "$id: refusal guidance does not name WORKFLOW_CONFIRM_DETAIL (out='$MARK_OUT' err='$MARK_ERR')"
  fi
}

echo "--- BH-5/6: detail unapproved → branching not recorded ---"
_bh_unapproved "BH-5" complete
_bh_unapproved "BH-6" pending

echo "--- BH-7: corrupt state (APPROVAL unknown) → state file untouched ---"
SID7="fix-950-bh-7"
printf '{ this is not json' > "$WF_DIR/$SID7.json"
run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_GATED>>\"" "$SID7"
bh7_got="$(cat "$WF_DIR/$SID7.json" 2>/dev/null)"
if [[ "$bh7_got" = "{ this is not json" ]]; then
  pass "BH-7: corrupt state left byte-identical (nothing recorded)"
else
  fail "BH-7: corrupt state was rewritten: '$(printf '%s' "$bh7_got" | head -c 200)'"
fi

echo "--- BH-8: no state file (APPROVAL not-applicable) → no state created ---"
SID8="fix-950-bh-8"
rm -f "$WF_DIR/$SID8.json"
run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_GATED>>\"" "$SID8"
if [[ ! -e "$WF_DIR/$SID8.json" ]]; then
  pass "BH-8: no state file created for an out-of-workflow session"
else
  fail "BH-8: a state file was created: $(bc_snapshot "$SID8")"
fi

echo "--- BH-9: control — CONFIRM_DETAIL=off waiver counts as approved → recorded ---"
SID9="fix-950-bh-9"
mkdir -p "$TMPDIR_BASE/decoy-root-off"
printf 'CONFIRM_DETAIL=off\n' > "$TMPDIR_BASE/decoy-root-off/.env"
write_state_main_cwd complete "$SID9"
OFF_ROOT_DIR="$(cygpath -m "$TMPDIR_BASE/decoy-root-off" 2>/dev/null || echo "$TMPDIR_BASE/decoy-root-off")"
AGENTS_MAIN_ROOT="$OFF_ROOT_DIR" run_hook "echo \"<<WORKFLOW_BRANCHING_COMPLETE: $DECISION_GATED>>\"" "$SID9"
bh9_got="$(bc_snapshot "$SID9")"
if [[ "$bh9_got" == "bc=complete decision=$DECISION_GATED wt=$WTA_NODE "* ]]; then
  pass "BH-9: off-waived detail → branching_complete + session_worktree recorded"
else
  fail "BH-9: off-waived detail → got '$bh9_got'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
