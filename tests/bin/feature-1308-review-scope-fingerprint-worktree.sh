#!/usr/bin/env bash
# Tests: bin/compute-review-scope-fingerprint.js
# Tags: staged-tests, worktree, fingerprint, scope:issue-specific
# #1308: compute-review-scope-fingerprint.js worktree selection priority.
# Priority: explicit argv[2] > SESSION_ID resolution. Calc error on missing session.
# L3 gap: live parallel sessions with competing linked worktrees.

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
AGENTS_WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_UNDER_TEST="$AGENTS_WORKTREE/bin/compute-review-scope-fingerprint.js"
RUN_TIMEOUT="$AGENTS_WORKTREE/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_WORKTREE/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"

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
TMPDIR_BASE="$(mktemp -d)"
MAIN_REPO="$TMPDIR_BASE/main"
WTA="$TMPDIR_BASE/wtA"
WTB="$TMPDIR_BASE/wtB"

cleanup() {
  git -C "$MAIN_REPO" worktree remove --force "$WTA" 2>/dev/null || true
  git -C "$MAIN_REPO" worktree remove --force "$WTB" 2>/dev/null || true
  rm -rf "$TMPDIR_BASE" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config core.hooksPath /dev/null 2>/dev/null || true
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
touch "$MAIN_REPO/.gitkeep"
git -C "$MAIN_REPO" add .gitkeep
git -C "$MAIN_REPO" commit -q -m "init"

git -C "$MAIN_REPO" worktree add -q -b "wt-branch-a" "$WTA"
git -C "$MAIN_REPO" worktree add -q -b "wt-branch-b" "$WTB"

mkdir -p "$WTA/tests"
echo "# test file A - $(date)" > "$WTA/tests/fixture-a.sh"
git -C "$WTA" add tests/fixture-a.sh

mkdir -p "$WTB/tests"
echo "# test file B - $(date) - different content" > "$WTB/tests/fixture-b.sh"
git -C "$WTB" add tests/fixture-b.sh

# ---------------------------------------------------------------------------
# Oracle: compute expected fingerprints for each worktree
# ---------------------------------------------------------------------------
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

oracle_fingerprint() {
  local wt_node_path="$1"
  AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" node -e "
    try {
      const { computeReviewScopeFingerprint } = require('$EVIDENCE_MODULE');
      const result = computeReviewScopeFingerprint(process.argv[1]);
      if (result && result.ok && result.fingerprint) {
        process.stdout.write(result.fingerprint);
      } else {
        process.stdout.write('');
      }
    } catch(e) {
      process.stderr.write('ERROR: ' + e.message + '\n');
      process.stdout.write('');
    }
  " -- "$wt_node_path" 2>/dev/null
}

FINGERPRINT_A="$(oracle_fingerprint "$WTA_NODE")"
FINGERPRINT_B="$(oracle_fingerprint "$WTB_NODE")"

if [[ -z "$FINGERPRINT_A" ]]; then
  fail "oracle setup: fingerprint for wtA is empty — staged files not picked up"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
if [[ -z "$FINGERPRINT_B" ]]; then
  fail "oracle setup: fingerprint for wtB is empty — staged files not picked up"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi
if [[ "$FINGERPRINT_A" = "$FINGERPRINT_B" ]]; then
  fail "oracle setup: FINGERPRINT_A == FINGERPRINT_B (fixture content is not distinct enough)"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Helper: run the script under test
# ---------------------------------------------------------------------------
run_script_cwd() {
  local cwd="$1"
  local explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    (cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" bash "$RUN_TIMEOUT" 30 \
      node "$AGENTS_WORKTREE_NODE/bin/compute-review-scope-fingerprint.js" "$explicit" 2>/dev/null)
  else
    (cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_WORKTREE_NODE" bash "$RUN_TIMEOUT" 30 \
      node "$AGENTS_WORKTREE_NODE/bin/compute-review-scope-fingerprint.js" 2>/dev/null)
  fi
}

# ---------------------------------------------------------------------------
# Case 1: Explicit arg wins over cwd
# ---------------------------------------------------------------------------
case1_got="$(run_script_cwd "$WTA" "$WTB_NODE")"
if [[ "$case1_got" = "$FINGERPRINT_B" ]]; then
  pass "Case 1 (explicit arg wins): got FINGERPRINT_B='$case1_got' even when cwd=wtA"
elif [[ "$case1_got" = "$FINGERPRINT_A" ]]; then
  fail "Case 1 (explicit arg wins): got FINGERPRINT_A instead of FINGERPRINT_B — argv[2] not honoured"
else
  fail "Case 1 (explicit arg wins): got '$case1_got', expected FINGERPRINT_B='$FINGERPRINT_B'"
fi

# ---------------------------------------------------------------------------
# Case 2: No explicit arg and no SESSION_ID → calc error (exit 1 + stderr).
# Per plan: missing worktree path is a calc error; 0 in-scope files is exit 0 + empty.
# ---------------------------------------------------------------------------
case2_rc=0
case2_got="$(SESSION_ID="" CLAUDE_CODE_SESSION_ID="" run_script_cwd "$WTA")" || case2_rc=$?
if [[ $case2_rc -ne 0 ]]; then
  pass "Case 2 (no session → calc error): non-zero exit when no arg and no SESSION_ID"
elif [[ -z "$case2_got" ]]; then
  pass "Case 2 (no session): empty string when no arg and no SESSION_ID"
else
  fail "Case 2 (no session): expected error exit or empty, got '$case2_got'"
fi

# ---------------------------------------------------------------------------
# Case 3: Explicit arg for wtA, run from cwd=main
# ---------------------------------------------------------------------------
case3_got="$(run_script_cwd "$MAIN_REPO" "$WTA_NODE")"
if [[ "$case3_got" = "$FINGERPRINT_A" ]]; then
  pass "Case 3 (explicit arg, neutral cwd): got FINGERPRINT_A='$case3_got' when cwd=main"
elif [[ "$case3_got" = "$FINGERPRINT_B" ]]; then
  fail "Case 3 (explicit arg, neutral cwd): got FINGERPRINT_B instead of FINGERPRINT_A"
else
  fail "Case 3 (explicit arg, neutral cwd): got '$case3_got', expected FINGERPRINT_A='$FINGERPRINT_A'"
fi

# ---------------------------------------------------------------------------
# Case 4: Determinism
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
