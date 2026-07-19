#!/bin/bash
# tests/fix-fix-923-posix-cwd.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/git-repo-detection.js
# Tags: enforce-worktree, git-worktree, scope:issue-specific
#
# Issue #923 regression: isMainCheckout(repoCwd) passes repoCwd directly to
# spawnSync without normalizing POSIX paths. When toolInput.cwd is supplied as a
# POSIX path (e.g. /c/git/agents from Git Bash), spawnSync fails with ENOENT →
# isMainCheckout returns false → the early-exit block fires the block branch.
# Fix: normalize repoCwd via toWindowsPath at the start of isMainCheckout.
#
# L3 gap (what this test does NOT catch):
# - Whether the real Claude Code CLI delivers toolInput.cwd as a POSIX path
#   in actual sessions (this test simulates it by injecting the POSIX form).
# - Hook registration in the actual settings.json environment.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

# Skip if cygpath is not available — POSIX-form paths only exist in Git Bash /
# Cygwin environments on Windows. No cygpath means no POSIX path to test.
if ! command -v cygpath >/dev/null 2>&1; then
  echo "SKIP: cygpath not available (not a Git Bash / Cygwin environment)"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_WIN="$(cygpath -m "$AGENTS_DIR")"
GUARD_JS="${AGENTS_WIN}/hooks/enforce-worktree.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

# ── Fixture setup ─────────────────────────────────────────────────────────────
# IMPORTANT: We must create the fixture under a real Windows drive-letter path
# so that cygpath -u produces the /c/... POSIX drive-letter form that Git Bash
# supplies as toolInput.cwd.
#
# On Cygwin/MSYS2, mktemp -d returns /tmp/... which maps to a virtual Cygwin
# mount (e.g. C:\Users\...\AppData\Local\Temp). cygpath -u of /tmp/... returns
# /tmp/... — a Cygwin virtual path that Node.js resolves transparently, so the
# ENOENT bug is NOT reproduced.
#
# We need a path like C:\git\tmp\... where cygpath -u gives /c/git/tmp/...
# Strategy: find a parent directory outside the Cygwin /tmp mount where
# cygpath -u produces /X/... drive-letter form, and create the fixture there.

# Candidate base directories (outside the /tmp mount) that cygpath -u converts
# to /c/... drive-letter form. Try in order; use first one that produces /X/...
_FOUND_BASE=""
for _CANDIDATE in "C:/git/tmp" "C:/tmp" "C:/Temp"; do
  mkdir -p "$_CANDIDATE" 2>/dev/null
  _POSIX_CANDIDATE="$(cygpath -u "$_CANDIDATE" 2>/dev/null)"
  if [[ "$_POSIX_CANDIDATE" == /[a-zA-Z]/* ]]; then
    _FOUND_BASE="$_CANDIDATE"
    break
  fi
done

if [ -z "$_FOUND_BASE" ]; then
  echo "SKIP: no candidate base dir produces /c/... POSIX form via cygpath -u (Cygwin mount covers all candidates)"
  exit 77
fi

# Create a unique temp dir under the found base
TMPBASE_WIN="${_FOUND_BASE}/wt923posixtest.$$"
mkdir -p "$TMPBASE_WIN"
trap 'rm -rf "$TMPBASE_WIN" 2>/dev/null' EXIT

# Main repo
MAIN_REPO="${TMPBASE_WIN}/main"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@example.com"
git -C "$MAIN_REPO" config user.name "Test"
git -C "$MAIN_REPO" config core.hooksPath /dev/null
printf 'init' > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q -m "initial"

# Linked worktree: separate checkout from the main repo
LINKED_WT="${TMPBASE_WIN}/linked"
git -C "$MAIN_REPO" worktree add -q -b feature/wt-posix-test "$LINKED_WT" 2>/dev/null

# Target worktree path (the path argument to worktree remove — does not need to exist)
TARGET_WT="${TMPBASE_WIN}/target-wt"

# Windows-form paths (forward-slash, for -C args in the JSON payload)
MAIN_WIN="$(cygpath -m "$MAIN_REPO")"
LINKED_WIN="$(cygpath -m "$LINKED_WT")"
TARGET_WIN="$(cygpath -m "$TARGET_WT")"

# POSIX drive-letter form (e.g. /c/Users/...) — what Git Bash supplies as toolInput.cwd
MAIN_POSIX="$(cygpath -u "$MAIN_WIN")"
LINKED_POSIX="$(cygpath -u "$LINKED_WIN")"

echo "Fixture paths:"
echo "  MAIN_WIN=$MAIN_WIN"
echo "  MAIN_POSIX=$MAIN_POSIX"
echo "  LINKED_WIN=$LINKED_WIN"
echo "  LINKED_POSIX=$LINKED_POSIX"
echo ""

# ── Helper: run enforce-worktree.js with a Bash payload and explicit toolInput.cwd ──
# run_bash_guard_with_cwd <cmd> <process_cwd> <tool_input_cwd> [ENV=val ...]
# Runs the hook with process.cwd() = <process_cwd>.
# JSON payload includes toolInput.cwd = <tool_input_cwd>.
#
# MSYS_NO_PATHCONV=1 is required when building the payload with POSIX paths:
# MSYS2/Git Bash auto-converts /c/... argv arguments to C:/... before passing
# them to native Windows executables (like node.exe). Setting MSYS_NO_PATHCONV=1
# disables that conversion so the /c/... POSIX form reaches node and lands in the
# JSON payload as-is — reproducing what Claude Code's Bash tool supplies at runtime.
run_bash_guard_with_cwd() {
  local cmd="$1"; shift
  local proc_cwd="$1"; shift
  local tool_cwd="$1"; shift
  local payload
  payload="$(MSYS_NO_PATHCONV=1 node -e "
    const j={session_id:'test-923-posix',tool_name:'Bash',tool_input:{command:process.argv[1],cwd:process.argv[2]}};
    console.log(JSON.stringify(j));
  " -- "$cmd" "$tool_cwd" 2>/dev/null)"
  if [ -n "$proc_cwd" ]; then
    (cd "$proc_cwd" && echo "$payload" | run_with_timeout env "$@" node "$GUARD_JS" 2>/dev/null)
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

# ── T923-POSIX.A: POSIX toolInput.cwd (main) + git worktree remove → ALLOW ───
# toolInput.cwd is the POSIX form of the main repo (simulates Git Bash behavior).
# process.cwd() is the Windows-form main repo (node can resolve it correctly).
# Before fix: isMainCheckout receives the POSIX path, spawnSync fails with ENOENT,
#   returns false → block branch fires → BLOCK (bug).
# After fix: isMainCheckout normalizes via toWindowsPath → resolves correctly → ALLOW.
POSIX_A_OUT="$(run_bash_guard_with_cwd "git worktree remove \"$TARGET_WIN\"" "$MAIN_REPO" "$MAIN_POSIX" ENFORCE_WORKTREE=on)"
assert_allow "$POSIX_A_OUT" "T923-POSIX.A: POSIX toolInput.cwd (main) + git worktree remove → ALLOW"

# ── T923-POSIX.B: POSIX toolInput.cwd (main) + git -C <main-win> worktree remove → ALLOW ──
# Same as T923-POSIX.A but with explicit -C flag pointing at the main repo.
# toolInput.cwd is POSIX form; -C arg is Windows form (already normalized in payload).
POSIX_B_OUT="$(run_bash_guard_with_cwd "git -C \"$MAIN_WIN\" worktree remove \"$TARGET_WIN\"" "$MAIN_REPO" "$MAIN_POSIX" ENFORCE_WORKTREE=on)"
assert_allow "$POSIX_B_OUT" "T923-POSIX.B: POSIX toolInput.cwd (main) + git -C <main-win> worktree remove → ALLOW"

# ── T923-POSIX.C: POSIX toolInput.cwd (linked) + git worktree remove → BLOCK ──
# SECURITY BOUNDARY: even with a POSIX toolInput.cwd, a linked worktree CWD must
# still be blocked. After the fix normalizes the POSIX path, isMainCheckout should
# correctly detect the linked worktree and return false → block.
POSIX_C_OUT="$(run_bash_guard_with_cwd "git worktree remove \"$TARGET_WIN\"" "$LINKED_WT" "$LINKED_POSIX" ENFORCE_WORKTREE=on)"
assert_block "$POSIX_C_OUT" "T923-POSIX.C: POSIX toolInput.cwd (linked) + git worktree remove → BLOCK"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
