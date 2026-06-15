#!/bin/bash
# tests/fix-852-enforce-worktree-abort.sh
# Tests: hooks/enforce-worktree/main-worktree-allows.js, hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, git, security, fix-852
# Tests for isAllowedMidOperationAbort() — issue #852.
#
# Predicate covers mid-operation abort/continue/skip from the main worktree:
#   git merge --abort
#   git rebase --abort | --continue | --skip
#   git cherry-pick --abort | --continue | --skip
#
# Design points:
#   - No linked-worktree-count gate (unlike isAllowedMainWorktreeCleanup)
#   - -C flag (if present) must match repoRoot
#   - Rejects shell chaining + interpreter wrappers
#   - Rejects multiple -C flags
#
# L3 gap (what this test does NOT catch):
# - Whether the real Claude Code CLI blocks/allows these commands in a live session
# - Hook registration in the actual settings.json environment
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
GUARD_JS="${_A}/hooks/enforce-worktree.js"
ALLOWS_JS="${_A}/hooks/enforce-worktree/main-worktree-allows.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t aborttest)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

# Main repo (CWD for L2 tests)
MAIN_REPO="$TMPBASE/main"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
echo "init" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q -m "initial"
if command -v cygpath >/dev/null 2>&1; then MAIN_N="$(cygpath -m "$MAIN_REPO")"; else MAIN_N="$MAIN_REPO"; fi

# Linked worktree (for L2.A test)
LINKED_WT="$TMPBASE/linked"
git -C "$MAIN_REPO" worktree add -q -b feature/test-abort "$LINKED_WT" 2>/dev/null
if command -v cygpath >/dev/null 2>&1; then LINKED_N="$(cygpath -m "$LINKED_WT")"; else LINKED_N="$LINKED_WT"; fi

# Unrelated repo (for S9 -C mismatch test)
OTHER_REPO="$TMPBASE/other"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email "test@example.com"
git -C "$OTHER_REPO" config user.name "Test"
git -C "$OTHER_REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then OTHER_N="$(cygpath -m "$OTHER_REPO")"; else OTHER_N="$OTHER_REPO"; fi

# Outside-repo path for L2.D
OUTSIDE_DIR="$TMPBASE/outside-plans"
mkdir -p "$OUTSIDE_DIR"
if command -v cygpath >/dev/null 2>&1; then OUTSIDE_N="$(cygpath -m "$OUTSIDE_DIR")"; else OUTSIDE_N="$OUTSIDE_DIR"; fi

# ============================================================================
# Direct predicate tests (call isAllowedMidOperationAbort directly via Node)
# ============================================================================
check_moa() {
  run_with_timeout node -e "
    const {isAllowedMidOperationAbort}=require('$ALLOWS_JS');
    console.log(isAllowedMidOperationAbort(process.argv[1],process.argv[2])?'allow':'reject');
  " -- "$1" "$2" 2>/dev/null
}
assert_allow_moa() { local got; got="$(check_moa "$1" "$2")"; [ "$got" = "allow"  ] && pass "$3" || fail "$3 (got=$got)"; }
assert_block_moa() { local got; got="$(check_moa "$1" "$2")"; [ "$got" = "reject" ] && pass "$3" || fail "$3 (got=$got)"; }

# S1-S7: subcommand × action coverage (merge/rebase/cherry-pick × abort/continue/skip)
assert_allow_moa "git merge --abort"                "$MAIN_N" "S1: git merge --abort → allow"
assert_allow_moa "git rebase --abort"               "$MAIN_N" "S2: git rebase --abort → allow"
assert_allow_moa "git rebase --continue"            "$MAIN_N" "S3: git rebase --continue → allow"
assert_allow_moa "git rebase --skip"                "$MAIN_N" "S4: git rebase --skip → allow"
assert_allow_moa "git cherry-pick --abort"          "$MAIN_N" "S5: git cherry-pick --abort → allow"
assert_allow_moa "git cherry-pick --continue"       "$MAIN_N" "S6: git cherry-pick --continue → allow"
assert_allow_moa "git cherry-pick --skip"           "$MAIN_N" "S7: git cherry-pick --skip → allow"

# S8: -C flag matching repoRoot → allow
assert_allow_moa "git -C \"$MAIN_N\" merge --abort" "$MAIN_N" "S8: -C repoRoot merge --abort → allow"

# S9: -C pointing at unrelated repo → block
assert_block_moa "git -C \"$OTHER_N\" merge --abort" "$MAIN_N" "S9: -C /other merge --abort → block"

# S10: shell chaining after abort → block
assert_block_moa "git merge --abort && echo done"   "$MAIN_N" "S10: chaining (&&) → block"

# S11: interpreter wrapper → block
assert_block_moa "bash -c 'git merge --abort'"      "$MAIN_N" "S11: bash -c wrapper → block"

# S12: defensive pin — 'abort' appears in commit message, not subcommand
assert_block_moa 'git commit -m "merge --abort"'    "$MAIN_N" "S12: commit -m containing 'merge --abort' → block (defensive pin)"

# S13: multiple -C flags → block
assert_block_moa "git -C \"$MAIN_N\" -C \"$OTHER_N\" merge --abort" "$MAIN_N" "S13: multiple -C flags → block"

# S14: extra flags around abort/continue/skip → allow
assert_allow_moa "git rebase --abort --rebase-merges" "$MAIN_N" "S14: extra flags after abort → allow"

# S15: chaining after abort (positive chain) → block
assert_block_moa "git cherry-pick --abort && git push" "$MAIN_N" "S15: cherry-pick --abort && git push → block"

# S16: -c config flag injects editor on --continue → block (RCE via core.editor)
assert_block_moa "git -c core.editor=evil merge --continue"    "$MAIN_N" "S16: -c core.editor=evil merge --continue → block"

# S17: -c config flag injects sequence.editor during interactive rebase continuation → block
assert_block_moa "git -c sequence.editor=evil rebase --continue" "$MAIN_N" "S17: -c sequence.editor=evil rebase --continue → block"

# S18: env-var prefix sets GIT_EDITOR before git invocation → block
assert_block_moa "GIT_EDITOR=evil git merge --abort"           "$MAIN_N" "S18: GIT_EDITOR=evil git merge --abort → block"

# S19: env-var prefix sets GIT_SEQUENCE_EDITOR for interactive rebase continuation → block
assert_block_moa "GIT_SEQUENCE_EDITOR=evil git rebase --continue" "$MAIN_N" "S19: GIT_SEQUENCE_EDITOR=evil git rebase --continue → block"

# ============================================================================
# L2 integration tests — full enforce-worktree.js dispatch
# ============================================================================
guard_decision() {
    local out="$1"
    echo "$out" | grep -q '"decision":"block"' && return 1 || return 0
}

run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j={session_id:'test',tool_name:'Bash',tool_input:{command:process.argv[1]}};
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

run_edit_guard() {
    local tool_name="$1"; shift
    local file_path="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j={session_id:'test',tool_name:process.argv[1],tool_input:{file_path:process.argv[2]}};
      console.log(JSON.stringify(j));
    " -- "$tool_name" "$file_path" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# L2.A: `git -C <linked_wt_path> merge --abort` from main CWD → ALLOW
# This pins findRepoRootForBash behavior — the -C makes effective repo = linked wt,
# which is a linked worktree (not main), so the existing flow already allows it.
L2A_OUT="$(run_bash_guard "git -C \"$LINKED_N\" merge --abort" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
if guard_decision "$L2A_OUT"; then
    pass "L2.A: git -C <linked_wt> merge --abort from main CWD → ALLOW"
else
    fail "L2.A: git -C <linked_wt> merge --abort from main CWD should ALLOW (got: $L2A_OUT)"
fi

# L2.B: `git merge --abort` from main CWD (no -C) → ALLOW
# Requires isAllowedMidOperationAbort to be registered in the main-worktree dispatch.
# FAILS (RED) until the predicate is implemented and registered.
L2B_OUT="$(run_bash_guard "git merge --abort" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
if guard_decision "$L2B_OUT"; then
    pass "L2.B: git merge --abort from main CWD (no -C) → ALLOW"
else
    fail "L2.B: git merge --abort from main CWD should ALLOW (got: $L2B_OUT)"
fi

# L2.C: Write tool with file_path inside main worktree from main CWD → BLOCK
L2C_OUT="$(run_edit_guard "Write" "$MAIN_REPO/README.md" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
if guard_decision "$L2C_OUT"; then
    fail "L2.C: Write tool into main worktree should BLOCK (got: $L2C_OUT)"
else
    pass "L2.C: Write tool into main worktree → BLOCK"
fi

# L2.D: Write tool with file_path to non-git path from main CWD → ALLOW
L2D_OUT="$(run_edit_guard "Write" "$OUTSIDE_DIR/plan.md" "$MAIN_REPO" ENFORCE_WORKTREE=on)"
if guard_decision "$L2D_OUT"; then
    pass "L2.D: Write tool to non-git outside path → ALLOW (Edit/Write fail-open maintained)"
else
    fail "L2.D: Write tool to non-git outside path should ALLOW (got: $L2D_OUT)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
