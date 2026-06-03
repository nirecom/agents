#!/bin/bash
# tests/enforce-worktree-backup-path.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/shared-cmd-utils.js
# Tags: worktree, enforce, hook, backup, parsefailure
#
# Tests the parseFailure cp bypass (Insertion Point 2) in hooks/enforce-worktree.js.
# When a cp command has unresolvable $VAR tokens in its args, collectBashWriteTargets
# sets parseFailure=true and the command falls through to the main-checkout block
# fail-closed path. The fix adds a skill-prefix bypass:
#   if (parseFailure && hasWorktreeEndSkillPrefix(cmd) && /\.worktree-backup/.test(cmd)) done();
#
# BP5 will FAIL until the source fix is applied.
# BP6 should PASS even before the fix (fail-closed is current behavior).
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_SCRIPT="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$1"'; exec @ARGV' -- "${@:2}"; fi
}

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t bptest)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT

# Set up a minimal git repo (main worktree, no linked worktrees)
REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then REPO_N="$(cygpath -m "$REPO")"; else REPO_N="$REPO"; fi

run_hook() {
    local payload="$1" cwd="$2"
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 node "$HOOK_SCRIPT" 2>&1)
}

hook_payload_bash() {
    local cmd="$1"
    node -e "
      const c = process.argv[1];
      console.log(JSON.stringify({tool_name:'Bash', tool_input:{command:c}}));
    " -- "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# BP5 — parseFailure cp + WORKTREE_END_SKILL=1 prefix + .worktree-backup literal
#        → ALLOW after fix (skill-prefix bypass at parseFailure path)
#        FAILS until source change is applied.
# ─────────────────────────────────────────────────────────────────────────────
# The cmd has $WORKTREE (unresolvable token → parseFailure=true) AND
# .worktree-backup literally in the destination path segment.
BP5_CMD='WORKTREE_END_SKILL=1 cp -p "$WORKTREE/WORKTREE_NOTES.md" ".worktree-backup/$BRANCH/WORKTREE_NOTES.md"'
payload="$(hook_payload_bash "$BP5_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*)
        fail "BP5 WORKTREE_END_SKILL=1 cp with parseFailure + .worktree-backup → expected ALLOW; got block (fix not yet applied)" ;;
    *)
        pass "BP5 WORKTREE_END_SKILL=1 cp parseFailure + .worktree-backup → ALLOW" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# BP6 — same cp but WITHOUT WORKTREE_END_SKILL=1 prefix → BLOCK (fail-closed)
#        Should PASS even before source changes (current behavior is fail-closed).
# ─────────────────────────────────────────────────────────────────────────────
BP6_CMD='cp -p "$WORKTREE/WORKTREE_NOTES.md" ".worktree-backup/$BRANCH/WORKTREE_NOTES.md"'
payload="$(hook_payload_bash "$BP6_CMD")"
out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$REPO_N")"
case "$out" in
    *'"decision":"block"'*)
        pass "BP6 cp parseFailure without prefix → BLOCK (fail-closed)" ;;
    *)
        fail "BP6 expected BLOCK for cp without skill prefix; got: $out" ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
