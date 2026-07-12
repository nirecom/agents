#!/usr/bin/env bash
# Tests: bin/compute-staged-tests-token.js
# Tags: staged-tests, worktree, fingerprint, scope:issue-specific
# Tests for issue #1308: compute-staged-tests-token.js worktree selection priority.
#
# Worktree selection order (most authoritative first):
#   1. Explicit worktree path in argv[2] — highest priority
#   2. process.cwd()'s worktree when it has staged tests/
#   3. Fallback scan: first linked worktree with staged tests
#
# L3 gap: these are L2 subprocess tests using a throwaway git repo with real
#          linked worktrees. A true L3 test would exercise live parallel Claude
#          Code sessions committing to competing linked worktrees; that requires
#          a real session pair and is out of scope for per-PR CI (#1308).

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
AGENTS_WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$AGENTS_WORKTREE/bin/compute-staged-tests-token.js"
RUN_TIMEOUT="$AGENTS_WORKTREE/bin/run-with-timeout.sh"

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

if [[ ! -f "$SCRIPT_UNDER_TEST" ]]; then
  fail "precondition: $SCRIPT_UNDER_TEST not found"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# Throwaway git fixture
# ---------------------------------------------------------------------------
# Create temp repo inside the scratchpad dir provided by the session harness.
SCRATCH_BASE="C:/Users/nire/AppData/Local/Temp/claude/c--git-agents/628796b9-df03-49f9-8b34-dae19909f689/scratchpad"
TMPDIR_BASE="$(mktemp -d "$SCRATCH_BASE/cst-test-XXXXXX" 2>/dev/null || mktemp -d)"
MAIN_REPO="$TMPDIR_BASE/main"
WTA="$TMPDIR_BASE/wtA"
WTB="$TMPDIR_BASE/wtB"

cleanup() {
  # Remove worktrees before rm-rf to release git's locks
  git -C "$MAIN_REPO" worktree remove --force "$WTA" 2>/dev/null || true
  git -C "$MAIN_REPO" worktree remove --force "$WTB" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT

# Initialise main repo
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
# Initial commit so worktrees can be added
touch "$MAIN_REPO/.gitkeep"
git -C "$MAIN_REPO" add .gitkeep
git -C "$MAIN_REPO" commit -q -m "init"

# Create two linked worktrees on separate branches
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-a" "$WTA"
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-b" "$WTB"

# Stage different test files in each worktree so their fingerprints differ
mkdir -p "$WTA/tests"
echo "# test file A - $(date)" > "$WTA/tests/fixture-a.sh"
git -C "$WTA" add tests/fixture-a.sh

mkdir -p "$WTB/tests"
echo "# test file B - $(date) - different content" > "$WTB/tests/fixture-b.sh"
git -C "$WTB" add tests/fixture-b.sh

# ---------------------------------------------------------------------------
# Oracle: compute expected tokens for each worktree
# ---------------------------------------------------------------------------
# Convert paths for Node.js on Windows (Git Bash returns /c/... but node needs C:/...)
if command -v cygpath >/dev/null 2>&1; then
  WTA_NODE="$(cygpath -m "$WTA")"
  WTB_NODE="$(cygpath -m "$WTB")"
  AGENTS_WORKTREE_NODE="$(cygpath -m "$AGENTS_WORKTREE")"
else
  WTA_NODE="$WTA"
  WTB_NODE="$WTB"
  AGENTS_WORKTREE_NODE="$AGENTS_WORKTREE"
fi

EVIDENCE_MODULE="$AGENTS_WORKTREE_NODE/hooks/workflow-gate/review-tests-evidence"

oracle_token() {
  local wt_node_path="$1"
  AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" node -e "
    try {
      const { computeStagedTestsToken } = require('$EVIDENCE_MODULE');
      const tok = computeStagedTestsToken(process.argv[1]);
      process.stdout.write(tok || '');
    } catch(e) {
      process.stderr.write('ERROR: ' + e.message + '\n');
      process.stdout.write('');
    }
  " -- "$wt_node_path" 2>/dev/null
}

TOKEN_A="$(oracle_token "$WTA_NODE")"
TOKEN_B="$(oracle_token "$WTB_NODE")"

# Verify oracles are non-empty and differ (guards against fixture problems)
if [[ -z "$TOKEN_A" ]]; then
  fail "oracle setup: token for wtA is empty — staged files not picked up"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
if [[ -z "$TOKEN_B" ]]; then
  fail "oracle setup: token for wtB is empty — staged files not picked up"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
if [[ "$TOKEN_A" = "$TOKEN_B" ]]; then
  fail "oracle setup: TOKEN_A == TOKEN_B (fixture content is not distinct enough)"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Helper: run the script under test with AGENTS_CONFIG_DIR set
# ---------------------------------------------------------------------------
run_script() {
  # $1: cwd  $2(optional): explicit worktree arg
  local cwd="$1"
  local explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" bash "$RUN_TIMEOUT" 30 \
      node "$AGENTS_WORKTREE_NODE/bin/compute-staged-tests-token.js" "$explicit" 2>/dev/null
  else
    (cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" bash "$RUN_TIMEOUT" 30 \
      node "$AGENTS_WORKTREE_NODE/bin/compute-staged-tests-token.js" 2>/dev/null)
  fi
}

# We need run_script to run in the correct cwd; use a subshell for no-arg cases.
run_script_cwd() {
  local cwd="$1"
  local explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    (cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" bash "$RUN_TIMEOUT" 30 \
      node "$AGENTS_WORKTREE_NODE/bin/compute-staged-tests-token.js" "$explicit" 2>/dev/null)
  else
    (cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" bash "$RUN_TIMEOUT" 30 \
      node "$AGENTS_WORKTREE_NODE/bin/compute-staged-tests-token.js" 2>/dev/null)
  fi
}

# ---------------------------------------------------------------------------
# Case 1: Explicit arg wins over cwd
# Run from cwd=wtA, pass explicit arg wtB -> expect TOKEN_B (not TOKEN_A)
# ---------------------------------------------------------------------------
case1_got="$(run_script_cwd "$WTA" "$WTB_NODE")"
if [[ "$case1_got" = "$TOKEN_B" ]]; then
  pass "Case 1 (explicit arg wins): got TOKEN_B='$case1_got' even when cwd=wtA"
elif [[ "$case1_got" = "$TOKEN_A" ]]; then
  fail "Case 1 (explicit arg wins): got TOKEN_A instead of TOKEN_B — argv[2] not honoured"
else
  fail "Case 1 (explicit arg wins): got '$case1_got', expected TOKEN_B='$TOKEN_B'"
fi

# ---------------------------------------------------------------------------
# Case 2: NO process.cwd() fallback (issue #882 / #1316).
# No argv[2] and no SESSION_ID -> resolveRepoDir() returns null even when cwd=wtA
# has staged tests. The script must NOT fall back to process.cwd(); it emits an
# empty string. This negative test locks in that the main worktree (or any cwd)
# is never silently selected without an explicit arg or session state.
# ---------------------------------------------------------------------------
case2_got="$(SESSION_ID="" CLAUDE_SESSION_ID="" run_script_cwd "$WTA")"
if [[ -z "$case2_got" ]]; then
  pass "Case 2 (no cwd fallback): empty string when no arg and no SESSION_ID"
elif [[ "$case2_got" = "$TOKEN_A" ]]; then
  fail "Case 2 (no cwd fallback): got TOKEN_A — process.cwd() fallback still active"
else
  fail "Case 2 (no cwd fallback): got '$case2_got', expected empty string"
fi

# ---------------------------------------------------------------------------
# Case 3: Explicit arg for wtA, run from cwd=main (no staged tests in main)
# -> expect TOKEN_A regardless of cwd
# ---------------------------------------------------------------------------
case3_got="$(run_script_cwd "$MAIN_REPO" "$WTA_NODE")"
if [[ "$case3_got" = "$TOKEN_A" ]]; then
  pass "Case 3 (explicit arg, neutral cwd): got TOKEN_A='$case3_got' when cwd=main"
elif [[ "$case3_got" = "$TOKEN_B" ]]; then
  fail "Case 3 (explicit arg, neutral cwd): got TOKEN_B instead of TOKEN_A"
else
  fail "Case 3 (explicit arg, neutral cwd): got '$case3_got', expected TOKEN_A='$TOKEN_A'"
fi

# ---------------------------------------------------------------------------
# Case 4: Determinism — running Case 1 twice yields identical output
# ---------------------------------------------------------------------------
case4_run1="$(run_script_cwd "$WTA" "$WTB_NODE")"
case4_run2="$(run_script_cwd "$WTA" "$WTB_NODE")"
if [[ "$case4_run1" = "$case4_run2" && -n "$case4_run1" ]]; then
  pass "Case 4 (determinism): two runs of Case 1 both returned '$case4_run1'"
else
  fail "Case 4 (determinism): run1='$case4_run1' != run2='$case4_run2'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
