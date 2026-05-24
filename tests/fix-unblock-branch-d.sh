#!/bin/bash
# tests/fix-unblock-branch-d.sh
#
# Tests for the worktree-list-gated `git branch -d/-D` decision in
# hooks/enforce-worktree.js. After retiring the pending-branch-delete-
# marker mechanism (#503), the hook decides allow/block from
# `git worktree list --porcelain`:
#   - branch is NOT registered to any linked worktree → ALLOW
#   - branch IS currently checked out in a linked worktree → BLOCK
#     (with a reason that mentions /worktree-end and `git worktree prune`)
# Linked worktrees themselves are not subject to the main-worktree
# branch-delete block. Shell chaining is rejected. Registry-fetch
# failure is fail-closed.
#
# Module contract under test (hooks/enforce-worktree.js exports):
#   isBranchDeleteCommand(cmd) -> bool
#   parseBranchDeleteTarget(cmd) -> string | null

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
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

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

# Run the hook end-to-end. Mirrors the wrapper used in feature-parallel-sessions-*.sh.
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
# Test 5: structural smoke — module exports are callable.
#         (getWorktreeBaseDir is no longer required by the new design; we
#         keep a lightweight smoke check that the module loads without
#         throwing under the test harness.)
# ─────────────────────────────────────────────────────────────────────────────

test_module_loads() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const ok = (typeof m.isBranchDeleteCommand === 'function') &&
                   (typeof m.parseBranchDeleteTarget === 'function');
        console.log(ok ? 'OK' : 'MISSING_EXPORT');
      } catch (e) { console.log('ERROR: ' + e.message); }
    " 2>/dev/null)"
    [ "$r" = "OK" ] && pass "module exports isBranchDeleteCommand & parseBranchDeleteTarget" \
                   || fail "module load: $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Worktree-list-based decision helpers
# ─────────────────────────────────────────────────────────────────────────────

# Initialise a bare-ish source repo (single commit on main).
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
}

# Add a linked worktree at $2 on a new branch $3 from repo $1.
add_linked_worktree() {
    local repo="$1" wpath="$2" branch="$3"
    (cd "$repo" && git worktree add -q "$wpath" -b "$branch" 2>/dev/null)
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 — main worktree, branch `foo` NOT registered to any linked worktree
#      → ALLOW (the new worktree-list policy lets the delete through)
# ─────────────────────────────────────────────────────────────────────────────

test_T6_allow_when_branch_not_in_worktree_list() {
    local repo="$TMPDIR_BASE/t6-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T6 expected ALLOW; got block: $out" ;;
        *)
            pass "T6 main-worktree + unregistered branch → ALLOW" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T7 — main worktree, branch `foo` IS currently checked out in a linked
#      worktree → BLOCK; reason must mention /worktree-end and
#      `git worktree prune`
# ─────────────────────────────────────────────────────────────────────────────

test_T7_block_when_branch_in_linked_worktree() {
    local repo="$TMPDIR_BASE/t7-repo"
    local wpath="$TMPDIR_BASE/t7-wt"
    init_repo "$repo"
    add_linked_worktree "$repo" "$wpath" "foo"

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            case "$out" in
                *worktree-end*|*"worktree prune"*)
                    pass "T7 main + linked worktree using branch → BLOCK with worktree-end/prune hint" ;;
                *)
                    fail "T7 blocked but reason missing worktree-end / git worktree prune: $out" ;;
            esac
            ;;
        *)
            fail "T7 expected BLOCK; got: $out" ;;
    esac

    # Cleanup
    git -C "$repo" worktree remove --force "$wpath" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Layout note (T8 / T8b / T8c — WORKTREE_END_SKILL inline cmd-string prefix on -D):
#   Force-delete `git branch -D foo` requires the cmd-string to begin with the
#   exact inline prefix `WORKTREE_END_SKILL=1 git -C <path> branch -D <branch>`.
#   The hook inspects the raw command (not process.env), mirroring
#   ISSUE_CLOSE_SKILL. Only /worktree-end Step 6f emits this exact shape.
#   T8  = -D with full inline prefix shape       → ALLOW
#   T8b = -D without prefix (bare cmd)            → BLOCK with reason mentioning the prefix
#   T8c = -D with combined flags `-Df` (no prefix)→ BLOCK (force-detection covers combined flags)
# ─────────────────────────────────────────────────────────────────────────────

# T8 — `-D` with inline prefix matching Step 6f shape (feature-typed branch)
#      → ALLOW even on unmerged branch (squash-merge produces commits that
#      --merged HEAD does not see).

test_T8_allow_force_delete_with_inline_prefix() {
    local repo="$TMPDIR_BASE/t8-repo"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t checkout -q -b feature/foo && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m "divergent" && \
        git -c user.email=t@example.com -c user.name=t checkout -q main)

    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/foo")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T8 expected ALLOW for inline-prefix -D on feature/foo; got block: $out" ;;
        *)
            pass "T8 inline WORKTREE_END_SKILL=1 prefix + -D on feature/foo → ALLOW" ;;
    esac
}

# T8b — `-D` WITHOUT inline prefix (bare cmd) → BLOCK with reason mentioning
#       `WORKTREE_END_SKILL`.

test_T8b_block_force_delete_without_inline_prefix() {
    local repo="$TMPDIR_BASE/t8b-repo"
    init_repo "$repo"
    (cd "$repo" && git branch feature/foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -D feature/foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            case "$out" in
                *"WORKTREE_END_SKILL"*)
                    pass "T8b main + -D without inline prefix → BLOCK with WORKTREE_END_SKILL reason" ;;
                *)
                    fail "T8b blocked but reason missing 'WORKTREE_END_SKILL': $out" ;;
            esac
            ;;
        *)
            fail "T8b expected BLOCK for -D without inline prefix; got: $out" ;;
    esac
}

# T8c — combined-flag force forms (`-Df`, `-d -f`) without inline prefix → BLOCK.
#       Validates that force-detection covers all option spellings, not just
#       the literal `-D` short flag.

# T8d — inline prefix + non-feature-typed branch (e.g. `main`, `release/v2`,
#       bare `foo`) → BLOCK. The bypass shape allow-list requires the branch
#       to match <type>/<task-name> where type is one of the rules/branch.md
#       allowed types. Defense-in-depth: even with the prefix, force-deleting
#       `main` or `release/*` is refused.

test_T8d_block_inline_prefix_with_non_feature_branch() {
    local repo="$TMPDIR_BASE/t8d-repo"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t branch foo 2>/dev/null && \
        git -c user.email=t@example.com -c user.name=t branch release/v2 2>/dev/null)

    # Form 1: bare branch name
    local payload1 out1
    payload1="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D foo")"
    out1="$(ENFORCE_WORKTREE=on run_hook "$payload1" "$repo")"
    case "$out1" in
        *"\"decision\":\"block\""*)
            pass "T8d inline prefix + bare 'foo' → BLOCK (non-feature type)" ;;
        *)
            fail "T8d expected BLOCK for inline-prefix on bare 'foo'; got: $out1" ;;
    esac

    # Form 2: release/* (not in allowed type set)
    local payload2 out2
    payload2="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D release/v2")"
    out2="$(ENFORCE_WORKTREE=on run_hook "$payload2" "$repo")"
    case "$out2" in
        *"\"decision\":\"block\""*)
            pass "T8d inline prefix + 'release/v2' → BLOCK (release not in allowed types)" ;;
        *)
            fail "T8d expected BLOCK for inline-prefix on 'release/v2'; got: $out2" ;;
    esac
}

test_T8c_block_combined_force_flags_without_prefix() {
    local repo="$TMPDIR_BASE/t8c-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    # Form 1: -d -f (separate force flag)
    local payload1 out1
    payload1="$(hook_payload_bash 'git branch -d -f foo')"
    out1="$(ENFORCE_WORKTREE=on run_hook "$payload1" "$repo")"
    case "$out1" in
        *"\"decision\":\"block\""*)
            pass "T8c form '-d -f' blocked without inline prefix" ;;
        *)
            fail "T8c form '-d -f' should BLOCK without inline prefix; got: $out1" ;;
    esac

    # Form 2: --force long flag
    local payload2 out2
    payload2="$(hook_payload_bash 'git branch -d --force foo')"
    out2="$(ENFORCE_WORKTREE=on run_hook "$payload2" "$repo")"
    case "$out2" in
        *"\"decision\":\"block\""*)
            pass "T8c form '-d --force' blocked without inline prefix" ;;
        *)
            fail "T8c form '-d --force' should BLOCK without inline prefix; got: $out2" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T9 — shell-chained form `git branch -d foo && echo x` → BLOCK
#      (hasShellChaining rejects it regardless of worktree-list state)
# ─────────────────────────────────────────────────────────────────────────────

test_T9_block_shell_chained() {
    local repo="$TMPDIR_BASE/t9-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo && echo x')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            pass "T9 shell-chained branch-delete → BLOCK" ;;
        *)
            fail "T9 expected BLOCK for shell-chained command; got: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — from a LINKED worktree, `git branch -d foo` (foo is not any
#       worktree's branch) → ALLOW. Main-worktree branch-delete gate does
#       not apply to writes issued from linked worktrees.
# ─────────────────────────────────────────────────────────────────────────────

test_T10_allow_from_linked_worktree() {
    local repo="$TMPDIR_BASE/t10-repo"
    local wpath="$TMPDIR_BASE/t10-wt"
    init_repo "$repo"
    add_linked_worktree "$repo" "$wpath" "feature/work"
    # Create another branch `foo` that is NOT checked out anywhere
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$wpath")"
    case "$out" in
        *"\"decision\":\"block\""*)
            # Linked worktrees on feature branches should NOT be blocked by
            # the branch-delete guard.
            fail "T10 expected ALLOW from linked worktree; got block: $out" ;;
        *)
            pass "T10 linked-worktree branch-delete on unregistered branch → ALLOW" ;;
    esac

    git -C "$repo" worktree remove --force "$wpath" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T11 — repoRoot null (path outside any git repo) → ALLOW
#       Matches the existing line 1647 policy ("not in a git repo → allow").
# ─────────────────────────────────────────────────────────────────────────────

test_T11_allow_when_outside_git_repo() {
    local nonrepo="$TMPDIR_BASE/t11-nonrepo"
    mkdir -p "$nonrepo"

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$nonrepo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T11 expected ALLOW outside any git repo; got block: $out" ;;
        *)
            pass "T11 outside git repo → ALLOW (matches existing line 1647 policy)" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T12 — `git worktree list --porcelain` fails → BLOCK (fail-closed)
#       Simulated by making the .git directory unreadable.
# ─────────────────────────────────────────────────────────────────────────────

test_T12_fail_closed_on_registry_fetch_failure() {
    local repo="$TMPDIR_BASE/t12-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    # Snapshot repoRoot detection BEFORE we break .git so that the hook
    # still treats this as inside a git repo, but the worktree-list call
    # then fails.
    chmod -R 000 "$repo/.git" 2>/dev/null || true

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    # Use the repo path as cwd; if findRepoRoot needs .git accessible it
    # may resolve to null — accept either BLOCK or fail-closed signal.
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo" 2>&1)"
    chmod -R u+rwX "$repo/.git" 2>/dev/null || true

    case "$out" in
        *"\"decision\":\"block\""*)
            pass "T12 worktree-list failure → BLOCK (fail-closed)" ;;
        *)
            # On Windows / when running as a privileged user, chmod 000 is
            # ineffective and the call may succeed; document as known-skip
            # rather than spurious failure.
            case "$(uname -s 2>/dev/null)" in
                MINGW*|MSYS*|CYGWIN*)
                    pass "T12 skipped (Windows chmod 000 ineffective; can't simulate)" ;;
                *)
                    fail "T12 expected BLOCK on registry-fetch failure; got: $out" ;;
            esac
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T13: isBranchDeleteCommand must not false-positive on commit messages
#      where "branch -d" / "branch -D" appears inside a quoted argument.
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_no_FP_in_commit_message() {
    local r
    r="$(call_isBranchDeleteCommand 'git commit -m "branch -d fix/foo"')"
    [ "$r" = "false" ] && pass "T13 isBranchDeleteCommand(git commit -m \"branch -d fix/foo\") == false" \
                      || fail "T13 isBranchDeleteCommand(commit msg with branch -d) == $r (expected false)"
    r="$(call_isBranchDeleteCommand 'git commit -m "delete branch -D feature/x"')"
    [ "$r" = "false" ] && pass "T13 isBranchDeleteCommand(commit msg with branch -D) == false" \
                      || fail "T13 isBranchDeleteCommand(commit msg with branch -D) == $r (expected false)"
}

# ─────────────────────────────────────────────────────────────────────────────
# T14: real `git branch -d/-D` with quoted branch name still detected
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_quoted_branch_value() {
    local r
    r="$(call_isBranchDeleteCommand 'git branch -D "feature/x"')"
    [ "$r" = "true" ] && pass "T14 isBranchDeleteCommand(git branch -D \"feature/x\") == true" \
                     || fail "T14 isBranchDeleteCommand(git branch -D \"feature/x\") == $r (expected true)"
    r="$(call_isBranchDeleteCommand "git branch -d 'fix/foo'")"
    [ "$r" = "true" ] && pass "T14 isBranchDeleteCommand(git branch -d 'fix/foo') == true" \
                     || fail "T14 isBranchDeleteCommand(git branch -d 'fix/foo') == $r (expected true)"
}

# ─────────────────────────────────────────────────────────────────────────────
# T15: documented false negative — subcommand token in quotes
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_documented_fn() {
    local r
    r="$(call_isBranchDeleteCommand 'git "branch" -D foo')"
    [ "$r" = "false" ] && pass "T15 isBranchDeleteCommand(git \"branch\" -D foo) == false (FN-1: documented)" \
                      || fail "T15 isBranchDeleteCommand(git \"branch\" -D foo) == $r (expected false; FN-1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# T16: parseBranchDeleteTarget unwraps quoted branch names
# ─────────────────────────────────────────────────────────────────────────────

test_parseBranchDeleteTarget_quoted_branch_names() {
    local r
    r="$(call_parseTarget 'git branch -D "feature/x"')"
    [ "$r" = '"feature/x"' ] && pass "T16 parseTarget(git branch -D \"feature/x\") == feature/x" \
                            || fail "T16 parseTarget(quoted feature/x) == $r"
    r="$(call_parseTarget "git branch -d 'fix/foo'")"
    [ "$r" = '"fix/foo"' ] && pass "T16 parseTarget(git branch -d 'fix/foo') == fix/foo" \
                          || fail "T16 parseTarget(single-quoted fix/foo) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_delete_is_write
test_classify_branch_no_false_positive
test_isBranchDeleteCommand
test_parseBranchDeleteTarget
test_module_loads
test_T6_allow_when_branch_not_in_worktree_list
test_T7_block_when_branch_in_linked_worktree
test_T8_allow_force_delete_with_inline_prefix
test_T8b_block_force_delete_without_inline_prefix
test_T8c_block_combined_force_flags_without_prefix
test_T8d_block_inline_prefix_with_non_feature_branch
test_T9_block_shell_chained
test_T10_allow_from_linked_worktree
test_T11_allow_when_outside_git_repo
test_T12_fail_closed_on_registry_fetch_failure
test_isBranchDeleteCommand_no_FP_in_commit_message
test_isBranchDeleteCommand_quoted_branch_value
test_isBranchDeleteCommand_documented_fn
test_parseBranchDeleteTarget_quoted_branch_names

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
