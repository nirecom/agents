#!/bin/bash
# tests/fix-923-enforce-worktree-early-exit.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/worktree-command.js
# Tags: enforce-worktree, git-worktree, scope:issue-specific
#
# Issue #923: early-exit block in enforce-worktree.js for git worktree remove/prune.
#
# The early-exit evaluates isMainCheckout(earlyRoot) + isAllowedWorktreeCommand()
# BEFORE detectWritePredicate, so the hook doesn't stall on non-write analysis.
#
# Security requirement: the early-exit MUST check that the CWD is the main worktree,
# not just that -C points to the main repo root. T923-L2.E is the sentinel test:
#   git -C <main> worktree remove /wt   from LINKED worktree CWD → BLOCK
# A broken implementation that does isMainCheckout(findRepoRootForBash(cmd)) without
# anchoring to CWD would allow this, which is a security boundary violation.
#
# L3 gap (what this test does NOT catch):
# - Whether the real Claude Code CLI blocks/allows these commands in a live session.
# - Hook registration in the actual settings.json environment.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
GUARD_JS="${_A}/hooks/enforce-worktree.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

# ── Fixture setup ─────────────────────────────────────────────────────────────
TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t wt923test)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

# Main repo
MAIN_REPO="$TMPBASE/main"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q -m "initial"

# Linked worktree: separate checkout from the main repo
LINKED_WT="$TMPBASE/linked"
git -C "$MAIN_REPO" worktree add -q -b feature/wt-test "$LINKED_WT" 2>/dev/null

# Target worktree path (the path argument to worktree remove)
TARGET_WT="$TMPBASE/target-wt"

# Normalize to forward-slash (Windows-safe for -C args)
if command -v cygpath >/dev/null 2>&1; then
  MAIN_N="$(cygpath -m "$MAIN_REPO")"
  LINKED_N="$(cygpath -m "$LINKED_WT")"
  TARGET_N="$(cygpath -m "$TARGET_WT")"
else
  MAIN_N="$MAIN_REPO"
  LINKED_N="$LINKED_WT"
  TARGET_N="$TARGET_WT"
fi

# Unrelated repo (for -C path mismatch test T923-L2.F)
OTHER_REPO="$TMPBASE/other"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email "test@example.com"
git -C "$OTHER_REPO" config user.name "Test"
git -C "$OTHER_REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then OTHER_N="$(cygpath -m "$OTHER_REPO")"; else OTHER_N="$OTHER_REPO"; fi

# ── Helper: run enforce-worktree.js with a Bash payload ───────────────────────
# run_bash_guard <cmd> <cwd> [ENV_VAR=val ...]
# Runs the hook with process.cwd() set to <cwd>.
run_bash_guard() {
  local cmd="$1"; shift
  local cwd="$1"; shift
  local payload
  payload="$(node -e "
    const j={session_id:'test-923',tool_name:'Bash',tool_input:{command:process.argv[1]}};
    console.log(JSON.stringify(j));
  " -- "$cmd" 2>/dev/null)"
  if [ -n "$cwd" ]; then
    (cd "$cwd" && echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null)
  else
    echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null
  fi
}

# Decision helpers
is_allow() { echo "$1" | grep -qv '"decision":"block"' && echo "$1" | grep -q '{}'; }
is_block() { echo "$1" | grep -q '"decision":"block"'; }

assert_allow() {
  local out="$1" label="$2"
  if is_allow "$out"; then pass "$label"; else fail "$label (got: $out)"; fi
}

assert_block() {
  local out="$1" label="$2"
  if is_block "$out"; then pass "$label"; else fail "$label (got: $out)"; fi
}

# ── T923-L2.A: git worktree remove /wt from main CWD → ALLOW ─────────────────
# No -C flag; CWD is main worktree; isAllowedWorktreeCommand returns true.
L2A_OUT="$(run_bash_guard "git worktree remove \"$TARGET_N\"" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
assert_allow "$L2A_OUT" "T923-L2.A: git worktree remove /wt from main CWD → ALLOW"

# ── T923-L2.B: git -C <main> worktree remove /wt from main CWD → ALLOW ────────
# This is the #923 MUST case: -C points to the main repo, CWD is also main.
# Early-exit should detect: earlyRoot=main, isMainCheckout(main)=true,
# isAllowedWorktreeCommand=true → allow.
L2B_OUT="$(run_bash_guard "git -C \"$MAIN_N\" worktree remove \"$TARGET_N\"" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
assert_allow "$L2B_OUT" "T923-L2.B: git -C <main> worktree remove /wt from main CWD → ALLOW"

# ── T923-L2.C: git worktree prune from main CWD → ALLOW ──────────────────────
L2C_OUT="$(run_bash_guard "git worktree prune" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
assert_allow "$L2C_OUT" "T923-L2.C: git worktree prune from main CWD → ALLOW"

# ── T923-L2.D: git worktree remove --force /wt from main CWD → BLOCK ─────────
# --force is NOT exempted by isAllowedWorktreeCommand (hasWorktreeRemoveForceFlag).
L2D_OUT="$(run_bash_guard "git worktree remove --force \"$TARGET_N\"" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
assert_block "$L2D_OUT" "T923-L2.D: git worktree remove --force /wt from main CWD → BLOCK"

# ── T923-L2.E: git -C <main> worktree remove /wt from LINKED worktree CWD → BLOCK
# SECURITY BOUNDARY: -C points to the main repo root, but the process CWD is a
# linked worktree. The early-exit MUST check that the CWD itself is the main
# checkout — not just that -C resolves to the main repo root.
#
# A broken implementation (early-exit without isMainCheckout guard on CWD):
#   earlyRoot = findRepoRootForBash(cmd, _toolCwd) → resolves -C → returns main
#   isMainCheckout(earlyRoot) → true (main repo root is main checkout)
#   isAllowedWorktreeCommand → true
#   → WRONGLY ALLOWS (security hole)
#
# Correct implementation must also confirm CWD is main worktree (or equivalently,
# ensure earlyRoot derived from CWD (not -C) is the main checkout).
# If this test PASSES after implementation, the isMainCheckout guard is present.
# If this test FAILS after implementation, the security boundary is broken.
L2E_OUT="$(run_bash_guard "git -C \"$MAIN_N\" worktree remove \"$TARGET_N\"" "$LINKED_WT" ENFORCE_WORKTREE=on)"
assert_block "$L2E_OUT" "T923-L2.E: git -C <main> worktree remove /wt from linked CWD → BLOCK"

# ── T923-L2.F: git -C <other> worktree remove /wt from main CWD → BLOCK ───────
# -C points to an unrelated repo (not the main repo). isAllowedWorktreeCommand
# should reject because the -C path doesn't match repoRoot.
L2F_OUT="$(run_bash_guard "git -C \"$OTHER_N\" worktree remove \"$TARGET_N\"" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
assert_block "$L2F_OUT" "T923-L2.F: git -C <other> worktree remove /wt from main CWD → BLOCK"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
