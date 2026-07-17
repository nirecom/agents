#!/usr/bin/env bash
# Tests: hooks/lib/workflow-state/resolve-worktree-path.js, bin/resolve-worktree-path, skills/review-tests/scripts/select-staged-files.sh
# Tags: scope:issue-specific
# Tests for issue #882: worktree-aware staged-file selection for /review-tests.
#
# RT-1 file selection must resolve the session's *linked worktree* from the
# workflow state (state.cwd), never process.cwd() and never the main worktree.
# This guards against a subagent / background run whose process.cwd() is the
# main worktree silently reviewing the wrong (or empty) file set.
#
# L3 gap (what this test does NOT catch):
# - RT-2 draft assembly (model selecting test/source from staged file list) — requires real claude -p session
# - Full /review-tests skill run verifying end-to-end review uses linked worktree files
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
AGENTS_WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER_JS="$AGENTS_WORKTREE/hooks/lib/workflow-state/resolve-worktree-path.js"
RESOLVER_BIN="$AGENTS_WORKTREE/bin/resolve-worktree-path"
SELECT_SH="$AGENTS_WORKTREE/skills/review-tests/scripts/select-staged-files.sh"
COMPUTE_JS="$AGENTS_WORKTREE/bin/compute-staged-tests-token.js"
RUN_TIMEOUT="$AGENTS_WORKTREE/bin/run-with-timeout.sh"

SESSION_ID="fix-882-test-sid"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "node not found — check skipped"
  exit 77
fi

# ---------------------------------------------------------------------------
# Throwaway git fixture + isolated workflow-state dir
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t rwp-test)"
MAIN_REPO="$TMPDIR_BASE/main"
WTA="$TMPDIR_BASE/wtA"
WF_DIR="$TMPDIR_BASE/workflow-state"

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

git -C "$MAIN_REPO" worktree add -q -b "wt-branch-a" "$WTA"

# Stage a test file in the linked worktree wtA.
mkdir -p "$WTA/tests"
echo "# linked worktree test file - $(date)" > "$WTA/tests/fixture-wta.sh"
git -C "$WTA" add tests/fixture-wta.sh

# Stage a DIFFERENT, distinguishable test file in the MAIN worktree.
mkdir -p "$MAIN_REPO/tests"
echo "# MAIN worktree test file - should NOT be selected" > "$MAIN_REPO/tests/fixture-main.sh"
git -C "$MAIN_REPO" add tests/fixture-main.sh

# ---------------------------------------------------------------------------
# Path conversion for Node.js on Windows (Git Bash /c/... -> C:/...)
# ---------------------------------------------------------------------------
if command -v cygpath >/dev/null 2>&1; then
  WTA_NODE="$(cygpath -m "$WTA")"
  MAIN_NODE="$(cygpath -m "$MAIN_REPO")"
  AGENTS_NODE="$(cygpath -m "$AGENTS_WORKTREE")"
  WF_DIR_NODE="$(cygpath -m "$WF_DIR")"
else
  WTA_NODE="$WTA"
  MAIN_NODE="$MAIN_REPO"
  AGENTS_NODE="$AGENTS_WORKTREE"
  WF_DIR_NODE="$WF_DIR"
fi

# ---------------------------------------------------------------------------
# Write workflow state JSON with cwd pointing to the linked worktree (wtA).
# ---------------------------------------------------------------------------
write_state() {
  # $1: cwd value to embed (node-form path)
  local cwd_val="$1"
  cat > "$WF_DIR/$SESSION_ID.json" <<EOF
{
  "version": 1,
  "session_id": "$SESSION_ID",
  "created_at": "2026-07-12T00:00:00.000Z",
  "cwd": "$cwd_val",
  "git_branch": "wt-branch-a",
  "steps": {}
}
EOF
}

# ---------------------------------------------------------------------------
# Helper: run bin/resolve-worktree-path with a given env.
#   $1: SESSION_ID value ("" to unset)
#   $2: whether state file exists ("state" / "nostate")
#   $3: cwd embedded in state ("wta" / "main")
# ---------------------------------------------------------------------------
run_resolver() {
  local sid="$1"
  local state_mode="$2"
  local cwd_mode="${3:-wta}"

  rm -f "$WF_DIR/$SESSION_ID.json"
  if [[ "$state_mode" = "state" ]]; then
    if [[ "$cwd_mode" = "main" ]]; then
      write_state "$MAIN_NODE"
    else
      write_state "$WTA_NODE"
    fi
  fi

  local sid_env=""
  [[ -n "$sid" ]] && sid_env="$sid"

  SESSION_ID="$sid_env" \
  CLAUDE_SESSION_ID="" \
  CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
  AGENTS_CONFIG_DIR="$AGENTS_NODE" \
    bash "$RUN_TIMEOUT" 30 "$RESOLVER_BIN" 2>/dev/null
}

# ===========================================================================
# NOTE: fail-before-fix. resolve-worktree-path.js / bin/resolve-worktree-path /
# select-staged-files.sh do not exist yet. Cases A-H below FAIL until the
# write-code step creates them. This is the expected pre-implementation state.
# ===========================================================================

# ---------------------------------------------------------------------------
# Case A: CLI returns linked worktree path when state.cwd is a linked worktree
# ---------------------------------------------------------------------------
caseA_got="$(run_resolver "$SESSION_ID" "state" "wta")"
if [[ "$caseA_got" = "$WTA_NODE" ]]; then
  pass "Case A (linked worktree resolved): got '$caseA_got'"
else
  fail "Case A (linked worktree resolved): got '$caseA_got', expected '$WTA_NODE'"
fi

# ---------------------------------------------------------------------------
# Case B: CLI returns empty string when state.cwd is the main worktree
# ---------------------------------------------------------------------------
caseB_got="$(run_resolver "$SESSION_ID" "state" "main")"
if [[ -z "$caseB_got" ]]; then
  pass "Case B (main worktree rejected): empty string as expected"
else
  fail "Case B (main worktree rejected): got '$caseB_got', expected empty"
fi

# ---------------------------------------------------------------------------
# Case C: CLI returns empty string when SESSION_ID not set
# ---------------------------------------------------------------------------
caseC_got="$(run_resolver "" "state" "wta")"
if [[ -z "$caseC_got" ]]; then
  pass "Case C (no SESSION_ID): empty string as expected"
else
  fail "Case C (no SESSION_ID): got '$caseC_got', expected empty"
fi

# ---------------------------------------------------------------------------
# Case D: CLI returns "NOSTATE" when state file is absent for the session
# ---------------------------------------------------------------------------
caseD_got="$(run_resolver "$SESSION_ID" "nostate" "wta")"
if [[ "$caseD_got" = "NOSTATE" ]]; then
  pass "Case D (state file absent): got 'NOSTATE' as expected"
else
  fail "Case D (state file absent): got '$caseD_got', expected 'NOSTATE'"
fi

# ---------------------------------------------------------------------------
# Helper: run select-staged-files.sh from a given process cwd + env.
#   $1: process cwd
#   $2: SESSION_ID value ("" to unset)
#   $3: state mode ("state" / "nostate")
#   $4: cwd embedded in state ("wta" / "main")
# Returns stdout; capture exit code separately via SELECT_RC.
# ---------------------------------------------------------------------------
SELECT_RC=0
SELECT_OUT=""
run_select() {
  local proc_cwd="$1"
  local sid="$2"
  local state_mode="$3"
  local cwd_mode="${4:-wta}"

  rm -f "$WF_DIR/$SESSION_ID.json"
  if [[ "$state_mode" = "state" ]]; then
    if [[ "$cwd_mode" = "main" ]]; then
      write_state "$MAIN_NODE"
    else
      write_state "$WTA_NODE"
    fi
  fi

  local out
  out="$(cd "$proc_cwd" && \
    SESSION_ID="$sid" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    AGENTS_CONFIG_DIR="$AGENTS_NODE" \
      bash "$RUN_TIMEOUT" 30 bash "$SELECT_SH" 2>/dev/null)"
  SELECT_RC=$?
  SELECT_OUT="$out"
}

# ---------------------------------------------------------------------------
# Case E [C2 core]: process cwd = main worktree, state.cwd = linked worktree.
# stdout must contain ONLY wtA's staged files, NOT the main worktree's files.
# ---------------------------------------------------------------------------
run_select "$MAIN_REPO" "$SESSION_ID" "state" "wta"
caseE_got="$SELECT_OUT"
if echo "$caseE_got" | grep -q "fixture-wta.sh" && ! echo "$caseE_got" | grep -q "fixture-main.sh"; then
  pass "Case E (worktree-aware selection): wtA files only, no main files"
else
  fail "Case E (worktree-aware selection): got '$caseE_got' (expect fixture-wta.sh, NOT fixture-main.sh)"
fi

# ---------------------------------------------------------------------------
# Case F [C2]: state.cwd = main worktree -> exit code 3, empty stdout
# (no cwd fallback — explicit skip).
# ---------------------------------------------------------------------------
run_select "$WTA" "$SESSION_ID" "state" "main"
caseF_got="$SELECT_OUT"
if [[ "$SELECT_RC" -eq 3 && -z "$caseF_got" ]]; then
  pass "Case F (main worktree state -> skip): exit 3, empty stdout"
else
  fail "Case F (main worktree state -> skip): rc=$SELECT_RC out='$caseF_got', expected rc=3 empty"
fi

# ---------------------------------------------------------------------------
# Case G [C2]: state file absent (NOSTATE) -> falls back to process cwd.
# Run from cwd=wtA -> selects wtA's staged files.
# ---------------------------------------------------------------------------
run_select "$WTA" "$SESSION_ID" "nostate" "wta"
caseG_got="$SELECT_OUT"
if echo "$caseG_got" | grep -q "fixture-wta.sh"; then
  pass "Case G (NOSTATE -> cwd fallback): selected wtA files from cwd"
else
  fail "Case G (NOSTATE -> cwd fallback): got '$caseG_got' (rc=$SELECT_RC), expected fixture-wta.sh"
fi

# ---------------------------------------------------------------------------
# Case H: compute-staged-tests-token.js with $WORKTREE as argv[2] returns a
# non-empty token when the linked worktree has staged tests.
# ---------------------------------------------------------------------------
caseH_got="$(AGENTS_CONFIG_DIR="$AGENTS_NODE" \
  bash "$RUN_TIMEOUT" 30 node "$COMPUTE_JS" "$WTA_NODE" 2>/dev/null)"
if [[ -n "$caseH_got" ]]; then
  pass "Case H (token for linked worktree): non-empty token '$caseH_got'"
else
  fail "Case H (token for linked worktree): empty token, expected non-empty"
fi

# ===========================================================================
# Cases I-L: state.session_worktree fallback (issue #950)
#
# When state.cwd points to the main worktree (i.e. the session was started
# from main), resolveSessionWorktreePath() must fall back to
# state.session_worktree (set by branching-handler after /worktree-start).
# These cases are EXPECTED to FAIL until the source fix lands.
# ===========================================================================

# Helper: write state JSON with both cwd and optional session_worktree.
# $1: cwd value (node-form path)
# $2: session_worktree value (node-form path | "null" | "" to omit)
write_state_950() {
  local cwd_val="$1"
  local sw_val="$2"
  local sw_line=""
  if [[ "$sw_val" = "null" ]]; then
    sw_line='"session_worktree": null,'
  elif [[ -n "$sw_val" ]]; then
    sw_line="\"session_worktree\": \"$sw_val\","
  fi
  cat > "$WF_DIR/$SESSION_ID.json" <<EOF
{
  "version": 1,
  "session_id": "$SESSION_ID",
  "created_at": "2026-07-18T00:00:00.000Z",
  "cwd": "$cwd_val",
  $sw_line
  "git_branch": "wt-branch-a",
  "steps": {}
}
EOF
}

# Helper: invoke the JS resolver directly (not the bin wrapper) so we can
# inspect the resolveSessionWorktreePath() return value in isolation.
# Uses a tiny inline Node.js runner that prints the return value or "null".
run_resolver_js() {
  local sid="$1"
  SESSION_ID="$sid" \
  CLAUDE_SESSION_ID="" \
  CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    bash "$RUN_TIMEOUT" 30 node -e "
const { resolveSessionWorktreePath } = require('$AGENTS_NODE/hooks/lib/workflow-state/resolve-worktree-path.js');
const result = resolveSessionWorktreePath('$sid');
process.stdout.write(result === null ? '' : result);
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Case I: state.cwd=main + state.session_worktree=valid linked worktree path
# Expected: resolveSessionWorktreePath returns that linked worktree path.
# FAIL before fix (source still reads only state.cwd).
# ---------------------------------------------------------------------------
write_state_950 "$MAIN_NODE" "$WTA_NODE"
caseI_got="$(run_resolver_js "$SESSION_ID")"
if [[ "$caseI_got" = "$WTA_NODE" ]]; then
  pass "Case I (session_worktree fallback): got '$caseI_got'"
else
  fail "Case I (session_worktree fallback): got '$caseI_got', expected '$WTA_NODE' [expected FAIL before source fix]"
fi

# ---------------------------------------------------------------------------
# Case J: state.cwd=main + state.session_worktree=null
# Expected: resolveSessionWorktreePath returns null (empty stdout).
# FAIL before fix only if the code tries to use null as a path.
# ---------------------------------------------------------------------------
write_state_950 "$MAIN_NODE" "null"
caseJ_got="$(run_resolver_js "$SESSION_ID")"
if [[ -z "$caseJ_got" ]]; then
  pass "Case J (session_worktree=null -> empty): got empty as expected"
else
  fail "Case J (session_worktree=null -> empty): got '$caseJ_got', expected empty [expected FAIL before source fix]"
fi

# ---------------------------------------------------------------------------
# Case K: state.cwd=main + state.session_worktree=nonexistent path
# Expected: resolveSessionWorktreePath returns null (empty stdout).
# ---------------------------------------------------------------------------
NONEXISTENT_PATH="$TMPDIR_BASE/does-not-exist"
write_state_950 "$MAIN_NODE" "$NONEXISTENT_PATH"
caseK_got="$(run_resolver_js "$SESSION_ID")"
if [[ -z "$caseK_got" ]]; then
  pass "Case K (session_worktree=nonexistent -> empty): got empty as expected"
else
  fail "Case K (session_worktree=nonexistent -> empty): got '$caseK_got', expected empty [expected FAIL before source fix]"
fi

# ---------------------------------------------------------------------------
# Case L: state.cwd=main + state.session_worktree=main worktree path
# (isMainWorktree=true) -> must also be rejected, return empty.
# ---------------------------------------------------------------------------
write_state_950 "$MAIN_NODE" "$MAIN_NODE"
caseL_got="$(run_resolver_js "$SESSION_ID")"
if [[ -z "$caseL_got" ]]; then
  pass "Case L (session_worktree=main -> empty): got empty as expected"
else
  fail "Case L (session_worktree=main -> empty): got '$caseL_got', expected empty [expected FAIL before source fix]"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
