#!/usr/bin/env bash
# Tests: hooks/workflow-state/resolve-worktree-path.js, bin/resolve-worktree-path, hooks/workflow-state/session-id.js, bin/resolve-session-id, skills/review-tests/scripts/select-staged-files.sh
# Tags: scope:issue-specific, session-id, ssot
# Tests for issue #882: worktree-aware staged-file selection for /review-tests.
# RT-1 file selection must resolve the session's *linked worktree* from the workflow
# state (state.cwd), never process.cwd() and never the main worktree — guarding against
# a subagent / background run whose process.cwd() is the main worktree silently
# reviewing the wrong (or empty) file set.
# L3 gap: RT-2 draft assembly and a full end-to-end /review-tests run both need a real
# claude -p session; checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
AGENTS_WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER_JS="$AGENTS_WORKTREE/hooks/workflow-state/resolve-worktree-path.js"
RESOLVER_BIN="$AGENTS_WORKTREE/bin/resolve-worktree-path"
SELECT_SH="$AGENTS_WORKTREE/skills/review-tests/scripts/select-staged-files.sh"
COMPUTE_JS="$AGENTS_WORKTREE/bin/compute-staged-tests-token.js"
RUN_TIMEOUT="$AGENTS_WORKTREE/bin/run-with-timeout.sh"
PARTS="$AGENTS_WORKTREE/tests/fix-882-resolve-worktree-path"

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
WTB="$TMPDIR_BASE/wtB"
WF_DIR="$TMPDIR_BASE/workflow-state"
# Empty transcript base: without it Priority 7's JSONL mtime scan can reach the
# developer's real ~/.claude/projects and resolve their live session (#2270).
EMPTY_TRANSCRIPTS="$TMPDIR_BASE/empty-transcripts"
# Dual-pin (#1799): without WORKFLOW_PLANS_DIR the supervisor emitter still
# resolves the developer's real ~/.workflow-plans/ and appends there.
PLANS_DIR="$TMPDIR_BASE/plans"

cleanup() {
  git -C "$MAIN_REPO" worktree remove --force "$WTA" 2>/dev/null || true
  git -C "$MAIN_REPO" worktree remove --force "$WTB" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MAIN_REPO" "$WF_DIR" "$PLANS_DIR" "$EMPTY_TRANSCRIPTS"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config core.hooksPath /dev/null 2>/dev/null || true
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
touch "$MAIN_REPO/.gitkeep"
git -C "$MAIN_REPO" add .gitkeep
git -C "$MAIN_REPO" commit -q -m "init"

git -C "$MAIN_REPO" worktree add -q -b "wt-branch-a" "$WTA"
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-b" "$WTB"

# Inference-tier bait for Case T: a worktree whose WORKTREE_NOTES.md carries a
# discoverable Session-ID (resolveSessionId Priority 6).
NOTES_SID="fix-882-notes-sid"
printf 'Session-ID: %s\n' "$NOTES_SID" > "$WTB/WORKTREE_NOTES.md"

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
  _tonode() { cygpath -m "$1"; }
else
  _tonode() { printf '%s' "$1"; }
fi
WTA_NODE="$(_tonode "$WTA")"
WTB_NODE="$(_tonode "$WTB")"
MAIN_NODE="$(_tonode "$MAIN_REPO")"
AGENTS_NODE="$(_tonode "$AGENTS_WORKTREE")"
WF_DIR_NODE="$(_tonode "$WF_DIR")"
PLANS_DIR_NODE="$(_tonode "$PLANS_DIR")"
TRANSCRIPTS_NODE="$(_tonode "$EMPTY_TRANSCRIPTS")"

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

  # The session id is supplied through CLAUDE_CODE_SESSION_ID — the only variable
  # a Claude Code subprocess reliably carries, and after #2270 the only env
  # channel the resolver reads. Legacy SESSION_ID stays empty here on purpose.
  run_resolver_env "" "$sid_env" "$TMPDIR_BASE"
}

# The env-explicit resolver runner every case above and below routes through.
# CWD is a parameter (default $TMPDIR_BASE, outside any worktree) and the three
# session vars plus CLAUDE_ENV_FILE / CLAUDE_TRANSCRIPT_BASE_DIR are pinned, so
# the developer's real host session can never leak into a fixture assertion
# (rules/test/fixture-isolation.md "Unset inherited session IDs").
#   $1: SESSION_ID   $2: CLAUDE_CODE_SESSION_ID   $3: process cwd
#   $4: value for the bridge's --session flag (omitted when empty)
run_resolver_env() {
  (
    cd "${3:-$TMPDIR_BASE}" || exit 1
    SESSION_ID="$1" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION_ID="$2" \
    CLAUDE_ENV_FILE="" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
    AGENTS_CONFIG_DIR="$AGENTS_NODE" \
      bash "$RUN_TIMEOUT" 30 "$RESOLVER_BIN" ${4:+--session "$4"}
  ) 2>/dev/null
}

# Write a state file for an ARBITRARY session id — Cases M/N/O need two stores.
#   $1: session id   $2: cwd value (node-form path)
write_state_for() {
  cat > "$WF_DIR/$1.json" <<EOF
{
  "version": 1,
  "session_id": "$1",
  "created_at": "2026-09-09T00:00:00.000Z",
  "cwd": "$2",
  "git_branch": "wt-branch-a",
  "steps": {}
}
EOF
}

# ---------------------------------------------------------------------------
# Helper: run select-staged-files.sh from a given process cwd + env.
#   $1: process cwd   $2: sid, routed to CLAUDE_CODE_SESSION_ID when $5 is
#       empty (SESSION_ID is not a supply channel — #2270)   $3: "state" /
#       "nostate"   $4: cwd embedded in state ("wta"/"main")   $5: explicit
#       CLAUDE_CODE_SESSION_ID (wins over $2)   $6: AGENTS_CONFIG_DIR override.
# Sets SELECT_OUT / SELECT_ERR / SELECT_RC; stderr kept out of stdout.
# ---------------------------------------------------------------------------
SELECT_RC=0
SELECT_OUT=""
SELECT_ERR=""
run_select() {
  local proc_cwd="$1"
  local sid="$2"
  local state_mode="$3"
  local cwd_mode="${4:-wta}"
  local ccsid="${5:-}"
  local agents_dir="${6:-$AGENTS_NODE}"
  local errfile="$TMPDIR_BASE/select-staged-files.err"
  local effective_ccsid="$ccsid"
  [[ -z "$effective_ccsid" ]] && effective_ccsid="$sid"

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
    SESSION_ID="" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION_ID="$effective_ccsid" \
    CLAUDE_ENV_FILE="" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
    AGENTS_CONFIG_DIR="$agents_dir" \
      bash "$RUN_TIMEOUT" 30 bash "$SELECT_SH" 2>"$errfile")"
  SELECT_RC=$?
  SELECT_OUT="$out"
  SELECT_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# Case bodies (rules/coding/file-split.md Pattern A)
# ---------------------------------------------------------------------------
. "$PARTS/cases-882-950.sh"
. "$PARTS/cases-2270-ssot.sh"
. "$PARTS/cases-2270-arg.sh"
. "$PARTS/cases-2270-bridge-rc.sh"

run_cases_882_950
run_cases_2270_ssot
run_cases_2270_arg
run_cases_2270_bridge_rc

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
