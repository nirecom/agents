#!/bin/bash
# tests/fix-unblock-branch-d.sh
#
# Tests for the marker-file-gated `git branch -d/-D` exemption in
# hooks/enforce-worktree.js. The marker file is the only authorised path:
# direct ad-hoc invocations are blocked from any worktree, and only matching
# /worktree-end cleanups (which write the marker) are permitted.
#
# Module contract under test (hooks/enforce-worktree.js exports):
#   isBranchDeleteCommand(cmd) -> bool
#   parseBranchDeleteTarget(cmd) -> string | null
#   getWorktreeBaseDir() -> string
#   isAllowedBranchDeleteViaMarker(cmd, repoRoot) -> bool

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
PATTERNS_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"
HOOK_SCRIPT="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'unblock-branch-d-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Unit-test callers
# ─────────────────────────────────────────────────────────────────────────────

call_isBranchDeleteCommand() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.isBranchDeleteCommand(process.argv[1])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_parseTarget() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.parseBranchDeleteTarget(process.argv[1])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_classify() {
    run_with_timeout 30 node -e "
      try {
        const { classify } = require('$PATTERNS_MODULE');
        console.log(classify(process.argv[1]));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_isAllowedMarker() {
    # args: cmd, repoRoot
    run_with_timeout 30 env WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-}" node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.isAllowedBranchDeleteViaMarker(process.argv[1], process.argv[2])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" "$2" 2>/dev/null
}

call_getBaseDir() {
    run_with_timeout 30 env WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-}" HOME="${HOME:-/tmp}" node -e "
      try {
        const m = require('$MODULE');
        console.log(m.getWorktreeBaseDir());
      } catch (e) { console.log('ERROR: ' + e.message); }
    " 2>/dev/null
}

# Run the hook end-to-end, returning the exit-side decision JSON or the
# stderr if blocked. Mirrors the wrapper used in feature-parallel-sessions-*.sh.
run_hook() {
    local payload="$1" cwd="$2"
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 node "$HOOK_SCRIPT" 2>&1)
}

# Build a Bash payload for the PreToolUse hook.
hook_payload_bash() {
    local cmd="$1"
    node -e "
      const c = process.argv[1];
      console.log(JSON.stringify({tool_name:'Bash', tool_input:{command:c}}));
    " -- "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: classify reclassifies -d/-D as write
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_delete_is_write() {
    local r
    r="$(call_classify 'git branch -d fix/foo')"
    if [ "$r" = "write" ]; then
        pass "classify(git branch -d fix/foo) == write"
    else
        fail "classify(git branch -d fix/foo) == $r (expected write)"
    fi
    r="$(call_classify 'git branch -D fix/foo')"
    if [ "$r" = "write" ]; then
        pass "classify(git branch -D fix/foo) == write"
    else
        fail "classify(git branch -D fix/foo) == $r (expected write)"
    fi
    r="$(call_classify 'git -C /path branch -D fix/foo')"
    if [ "$r" = "write" ]; then
        pass "classify(git -C /path branch -D fix/foo) == write"
    else
        fail "classify(git -C ... branch -D ...) == $r (expected write)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: classify does NOT match read-only branch ops or branch names
#         containing "-d" / "-D" as substrings
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_no_false_positive() {
    local r
    r="$(call_classify 'git branch')"
    [ "$r" = "read" ] && pass "classify(git branch) == read" \
                     || fail "classify(git branch) == $r"
    r="$(call_classify 'git branch -a')"
    [ "$r" = "read" ] && pass "classify(git branch -a) == read" \
                     || fail "classify(git branch -a) == $r"
    r="$(call_classify 'git branch --contains HEAD')"
    [ "$r" = "read" ] && pass "classify(git branch --contains) == read" \
                     || fail "classify(git branch --contains) == $r"
    # Branch name token contains substring "-d" — must NOT match (whitespace-anchored)
    r="$(call_classify 'git branch fix-d-foo')"
    [ "$r" = "read" ] && pass "classify(git branch fix-d-foo) == read (no false positive)" \
                     || fail "classify(git branch fix-d-foo) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: isBranchDeleteCommand basic shape detection
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand() {
    local r
    r="$(call_isBranchDeleteCommand 'git branch -D fix/foo')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git branch -D fix/foo)" \
                     || fail "isBranchDeleteCommand(git branch -D fix/foo) == $r"
    r="$(call_isBranchDeleteCommand 'git branch -d fix/foo')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git branch -d fix/foo)" \
                     || fail "isBranchDeleteCommand(git branch -d fix/foo) == $r"
    r="$(call_isBranchDeleteCommand 'git -C /path branch -D fix/foo')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git -C ... branch -D ...)" \
                     || fail "isBranchDeleteCommand(git -C ... branch -D ...) == $r"
    r="$(call_isBranchDeleteCommand 'git branch -m old new')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(git branch -m) == false (rename, not delete)" \
                      || fail "isBranchDeleteCommand(git branch -m) == $r"
    r="$(call_isBranchDeleteCommand 'git status')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(git status) == false" \
                      || fail "isBranchDeleteCommand(git status) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: parseBranchDeleteTarget extracts the target branch name
# ─────────────────────────────────────────────────────────────────────────────

test_parseBranchDeleteTarget() {
    local r
    r="$(call_parseTarget 'git branch -D fix/foo')"
    [ "$r" = '"fix/foo"' ] && pass "parseTarget(git branch -D fix/foo) == fix/foo" \
                          || fail "parseTarget == $r"
    r="$(call_parseTarget 'git -C /repo branch -d feature/x')"
    [ "$r" = '"feature/x"' ] && pass "parseTarget(git -C ... branch -d feature/x) == feature/x" \
                            || fail "parseTarget == $r"
    r="$(call_parseTarget 'git branch -D')"
    [ "$r" = "null" ] && pass "parseTarget(git branch -D <no arg>) == null" \
                      || fail "parseTarget(no arg) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: getWorktreeBaseDir reads env, falls back to ~/git/worktrees,
#         expands leading ~ to homedir
# ─────────────────────────────────────────────────────────────────────────────

test_getWorktreeBaseDir() {
    # Default: WORKTREE_BASE_DIR unset → falls back to <homedir>/git/worktrees.
    # We can't reliably override the resolved homedir cross-platform from a
    # subshell (Windows uses USERPROFILE, POSIX uses HOME), so just verify the
    # structural suffix.
    local r
    WORKTREE_BASE_DIR="" r="$(call_getBaseDir)"
    case "$r" in
        */git/worktrees|*\\git\\worktrees)
            pass "getWorktreeBaseDir() default ends with git/worktrees" ;;
        *) fail "getWorktreeBaseDir() default == $r" ;;
    esac
    # Custom: WORKTREE_BASE_DIR honoured.
    WORKTREE_BASE_DIR="/custom/wts" r="$(call_getBaseDir)"
    case "$r" in
        */custom/wts|*\\custom\\wts) pass "getWorktreeBaseDir() honours WORKTREE_BASE_DIR=/custom/wts" ;;
        *) fail "getWorktreeBaseDir() with custom dir == $r" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: isAllowedBranchDeleteViaMarker — allows when marker matches AND
#         worktree path resolves under WORKTREE_BASE_DIR
# ─────────────────────────────────────────────────────────────────────────────

setup_repo_with_marker() {
    local repo="$1" branch="$2" wtree_path="$3"
    mkdir -p "$repo"
    (cd "$repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init)
    mkdir -p "$repo/.git/info"
    printf '%s\n%s\n' "$branch" "$wtree_path" > "$repo/.git/info/pending-branch-delete"
}

test_marker_allows_matching() {
    local repo="$TMPDIR_BASE/repo-allow"
    local wbase="$TMPDIR_BASE/worktrees"
    mkdir -p "$wbase/foo"
    setup_repo_with_marker "$repo" "fix/foo" "$wbase/foo/agents"

    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarker 'git branch -D fix/foo' "$repo")"
    [ "$r" = "true" ] && pass "marker matches: allow git branch -D fix/foo" \
                     || fail "marker matches but blocked: $r"
}

test_marker_blocks_target_mismatch() {
    local repo="$TMPDIR_BASE/repo-mismatch"
    local wbase="$TMPDIR_BASE/worktrees-mm"
    mkdir -p "$wbase/foo"
    setup_repo_with_marker "$repo" "fix/foo" "$wbase/foo/agents"

    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarker 'git branch -D fix/other' "$repo")"
    [ "$r" = "false" ] && pass "marker target mismatch → blocked" \
                      || fail "marker target mismatch but allowed: $r"
}

test_marker_blocks_wtree_outside_base() {
    local repo="$TMPDIR_BASE/repo-outside"
    local wbase="$TMPDIR_BASE/worktrees-outside"
    local rogue="$TMPDIR_BASE/rogue/foo/agents"
    mkdir -p "$wbase" "$rogue"
    setup_repo_with_marker "$repo" "fix/foo" "$rogue"

    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarker 'git branch -D fix/foo' "$repo")"
    [ "$r" = "false" ] && pass "marker wtree path outside WORKTREE_BASE_DIR → blocked" \
                      || fail "rogue wtree path but allowed: $r"
}

test_marker_missing_blocks() {
    local repo="$TMPDIR_BASE/repo-no-marker"
    mkdir -p "$repo"
    (cd "$repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init)
    # No marker file written.

    WORKTREE_BASE_DIR="$TMPDIR_BASE/wbase-x" r="$(call_isAllowedMarker 'git branch -D fix/foo' "$repo")"
    [ "$r" = "false" ] && pass "no marker → blocked" \
                      || fail "no marker but allowed: $r"
}

test_marker_chained_command_blocked() {
    local repo="$TMPDIR_BASE/repo-chain"
    local wbase="$TMPDIR_BASE/worktrees-chain"
    mkdir -p "$wbase/foo"
    setup_repo_with_marker "$repo" "fix/foo" "$wbase/foo/agents"

    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarker 'git branch -D fix/foo && rm -rf /' "$repo")"
    [ "$r" = "false" ] && pass "chained command rejected even with valid marker" \
                      || fail "chained command allowed: $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: marker survives both LF and CRLF line endings
# ─────────────────────────────────────────────────────────────────────────────

test_marker_crlf_accepted() {
    local repo="$TMPDIR_BASE/repo-crlf"
    local wbase="$TMPDIR_BASE/worktrees-crlf"
    mkdir -p "$repo/.git/info" "$wbase/foo"
    (cd "$repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init)
    printf 'fix/foo\r\n%s/foo/agents\r\n' "$wbase" > "$repo/.git/info/pending-branch-delete"

    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarker 'git branch -D fix/foo' "$repo")"
    [ "$r" = "true" ] && pass "marker with CRLF line endings: allowed" \
                     || fail "marker CRLF rejected: $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: marker lives in shared .git (git-common-dir), readable from a
#         linked worktree as well
# ─────────────────────────────────────────────────────────────────────────────

test_marker_readable_from_linked_worktree() {
    local main="$TMPDIR_BASE/repo-linked-main"
    local linked="$TMPDIR_BASE/worktrees-linked/foo/agents"
    local wbase="$TMPDIR_BASE/worktrees-linked"
    mkdir -p "$main"
    (cd "$main" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init)
    mkdir -p "$wbase/foo"
    git -C "$main" worktree add -q "$linked" -b fix/foo 2>/dev/null

    mkdir -p "$main/.git/info"
    printf 'fix/foo\n%s\n' "$linked" > "$main/.git/info/pending-branch-delete"

    # Hook called from inside the linked worktree.
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarker 'git -C '"$main"' branch -D fix/foo' "$linked")"
    [ "$r" = "true" ] && pass "marker readable from linked worktree (shared .git)" \
                     || fail "marker not found from linked worktree: $r"

    git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: end-to-end via the hook script — branch -d/-D blocked without marker
# ─────────────────────────────────────────────────────────────────────────────

test_e2e_branch_delete_blocked_without_marker() {
    local repo="$TMPDIR_BASE/repo-e2e-block"
    mkdir -p "$repo"
    (cd "$repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init)

    local payload
    payload="$(hook_payload_bash 'git branch -D fix/anything')"
    local out
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$TMPDIR_BASE/wbase-e2e" run_hook "$payload" "$repo")"
    case "$out" in
        *block*"git branch -d/-D blocked"*)
            pass "e2e: git branch -D blocked without marker (reason mentions /worktree-end marker)" ;;
        *)
            fail "e2e: expected block message, got: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: end-to-end via the hook — branch -D allowed with valid marker
# ─────────────────────────────────────────────────────────────────────────────

test_e2e_branch_delete_allowed_with_marker() {
    local repo="$TMPDIR_BASE/repo-e2e-allow"
    local wbase="$TMPDIR_BASE/wbase-e2e-allow"
    mkdir -p "$repo" "$wbase/foo"
    (cd "$repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init)
    mkdir -p "$repo/.git/info"
    printf 'fix/foo\n%s/foo/agents\n' "$wbase" > "$repo/.git/info/pending-branch-delete"

    local payload
    payload="$(hook_payload_bash 'git branch -D fix/foo')"
    local out
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
    # Allowed = empty decision JSON ({}), no "block" key
    case "$out" in
        *"\"decision\":\"block\""*) fail "e2e: marker valid but blocked: $out" ;;
        *) pass "e2e: marker valid → branch -D allowed" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: isBranchDeleteCommand must not false-positive on commit messages
#          where "branch -d" / "branch -D" appears inside a quoted argument.
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_no_FP_in_commit_message() {
    local r
    r="$(call_isBranchDeleteCommand 'git commit -m "branch -d fix/foo"')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(git commit -m \"branch -d fix/foo\") == false" \
                      || fail "isBranchDeleteCommand(commit msg with branch -d) == $r (expected false)"
    r="$(call_isBranchDeleteCommand 'git commit -m "delete branch -D feature/x"')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(commit msg with branch -D) == false" \
                      || fail "isBranchDeleteCommand(commit msg with branch -D) == $r (expected false)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: real `git branch -d/-D` with quoted branch name still detected
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_quoted_branch_value() {
    local r
    r="$(call_isBranchDeleteCommand 'git branch -D "feature/x"')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git branch -D \"feature/x\") == true" \
                     || fail "isBranchDeleteCommand(git branch -D \"feature/x\") == $r (expected true)"
    r="$(call_isBranchDeleteCommand "git branch -d 'fix/foo'")"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git branch -d 'fix/foo') == true" \
                     || fail "isBranchDeleteCommand(git branch -d 'fix/foo') == $r (expected true)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: documented false negative — subcommand token in quotes
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_documented_fn() {
    local r
    r="$(call_isBranchDeleteCommand 'git "branch" -D foo')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(git \"branch\" -D foo) == false (FN-1: documented)" \
                      || fail "isBranchDeleteCommand(git \"branch\" -D foo) == $r (expected false; FN-1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 14: parseBranchDeleteTarget unwraps quoted branch names
# ─────────────────────────────────────────────────────────────────────────────

test_parseBranchDeleteTarget_quoted_branch_names() {
    local r
    r="$(call_parseTarget 'git branch -D "feature/x"')"
    [ "$r" = '"feature/x"' ] && pass "parseTarget(git branch -D \"feature/x\") == feature/x" \
                            || fail "parseTarget(quoted feature/x) == $r"
    r="$(call_parseTarget "git branch -d 'fix/foo'")"
    [ "$r" = '"fix/foo"' ] && pass "parseTarget(git branch -d 'fix/foo') == fix/foo" \
                          || fail "parseTarget(single-quoted fix/foo) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_delete_is_write
test_classify_branch_no_false_positive
test_isBranchDeleteCommand
test_parseBranchDeleteTarget
test_getWorktreeBaseDir
test_marker_allows_matching
test_marker_blocks_target_mismatch
test_marker_blocks_wtree_outside_base
test_marker_missing_blocks
test_marker_chained_command_blocked
test_marker_crlf_accepted
test_marker_readable_from_linked_worktree
test_e2e_branch_delete_blocked_without_marker
test_e2e_branch_delete_allowed_with_marker
test_isBranchDeleteCommand_no_FP_in_commit_message
test_isBranchDeleteCommand_quoted_branch_value
test_isBranchDeleteCommand_documented_fn
test_parseBranchDeleteTarget_quoted_branch_names

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
