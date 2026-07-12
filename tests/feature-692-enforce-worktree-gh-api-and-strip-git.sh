#!/usr/bin/env bash
# tests/feature-692-enforce-worktree-gh-api-and-strip-git.sh
# Tests: hooks/enforce-worktree.js, hooks/lib/bash-write-patterns.js
# Tags: enforce-worktree, classify, gh-api, strip-quoted-args, issue-close, step-6h
#
# Regression tests for issue #692:
#   Bug A — `gh api -X PUT repos/o/r/contents/...` from main worktree must be
#           allowed when cwd is in session scope (required by /worktree-end
#           Step 6h's COMPOSE_DOC_APPEND_SKILL=1 → bin/compose-doc-append-entry
#           call which runs `gh api -X PUT` from MAIN_ROOT).
#   Bug B — kind:"git" classify() patterns must scan the stripped (quote-
#           removed) command so `grep -n "git push" file` is not misclassified
#           as a write. Achieved by adding "git" to STRIP_KINDS.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE="$(mktemp -d)/feature-692-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ─────────────────────────────────────────────────────────────────────────────
# Bug B — classify() regression: git verbs inside quoted args
# ─────────────────────────────────────────────────────────────────────────────

CLASSIFY_HELPER="$TMPDIR_BASE/classify-helper.js"
cat > "$CLASSIFY_HELPER" <<'NODE_HELPER'
const path = require("path");
const lib = path.join(process.argv[2], "hooks", "lib", "bash-write-patterns");
const { classify } = require(lib);
process.stdout.write(classify(process.argv[3]));
NODE_HELPER

classify() {
    local cmd="$1"
    node "$CLASSIFY_HELPER" "$AGENTS_DIR" "$cmd"
}

# isGitWriteIR helper: post-canary5-6git the git-write SSOT moved OUT of
# classify()/WRITE_PATTERNS (#1401 retire) INTO isGitWriteIR (IR-based). A real
# git write now classifies "read"; detection is via isGitWriteIR === true.
is_git_write() {
    local cmd="$1"
    node -e '
const path = require("path");
const { isGitWriteIR } = require(path.join(process.argv[1], "hooks", "lib", "bash-write-patterns", "patterns"));
const { parse } = require(path.join(process.argv[1], "hooks", "lib", "command-ir"));
process.stdout.write(String(isGitWriteIR(parse(process.argv[2]))));
' "$AGENTS_DIR" "$cmd"
}

assert_classify() {
    local label="$1" cmd="$2" expected="$3"
    local got
    got="$(classify "$cmd")"
    if [ "$got" = "$expected" ]; then
        pass "B: $label → $expected"
    else
        fail "B: $label → expected '$expected', got '$got' (cmd: $cmd)"
    fi
}

# Assert a real git write: post-retire SSOT is classify=="read" + isGitWriteIR==true.
assert_git_write() {
    local label="$1" cmd="$2"
    local c g
    c="$(classify "$cmd")"
    g="$(is_git_write "$cmd")"
    if [ "$c" = "read" ] && [ "$g" = "true" ]; then
        pass "B: $label → git-write (classify=read + isGitWriteIR=true)"
    else
        fail "B: $label → expected classify=read+isGitWriteIR=true, got classify='$c' isGitWriteIR='$g' (cmd: $cmd)"
    fi
}

test_b_grep_with_quoted_git_verbs_is_read() {
    assert_classify "grep -n \"git push\" file"             'grep -n "git push" file.md' "read"
    assert_classify "grep -n \"git push|git commit\" path"  'grep -n "git push|git commit" path/to/file' "read"
    assert_classify "grep -nE \"git push\" docs/foo.md"     'grep -nE "git push" docs/foo.md' "read"
    assert_classify "rg \"git commit\" ."                   'rg "git commit" .' "read"
    assert_classify "cat README.md | grep \"git push\""     'cat README.md | grep "git push"' "read"
    assert_classify "echo \"Run git commit -m test\""       'echo "Run git commit -m test"' "read"
    assert_classify "echo \"git rebase steps\""             'echo "git rebase steps"' "read"
    assert_classify "echo \"git merge instructions\""       'echo "git merge instructions"' "read"
    assert_classify "printf \"git reset --hard ...\""       'printf "git reset --hard ..."' "read"
}

# Post-canary5-6git: git-write detection SSOT moved from classify()/WRITE_PATTERNS
# to isGitWriteIR (#1401 retire). Real git writes now classify "read" and are
# detected via isGitWriteIR === true. These rows preserve the ORIGINAL intent
# (real git writes are still detected as writes) re-pointed to the new SSOT.
test_b_real_git_commands_remain_write() {
    assert_git_write "real git commit -m"            'git commit -m "test"'
    assert_git_write "real git push origin main"     'git push origin main'
    assert_git_write "real git checkout -- file"     'git checkout -- file.txt'
    assert_git_write "real git stash push"           'git stash push -m "wip"'
    assert_git_write "real git -C path commit"       'git -C /path commit -m x'
    assert_git_write "real git rebase main"          'git rebase main'
    assert_git_write "real git merge feature"        'git merge feature'
    assert_git_write "real git reset --hard HEAD"    'git reset --hard HEAD'
    assert_git_write "real git update-ref"           'git update-ref refs/heads/x HEAD'
}

# ─────────────────────────────────────────────────────────────────────────────
# Bug A — enforce-worktree.js positive regression: gh api docs writes
# from main worktree (cwd in session-scope) are allowed.
# Validates the path used by /worktree-end Step 6h via
#   COMPOSE_DOC_APPEND_SKILL=1 bin/compose-doc-append-entry → gh api -X PUT.
# ─────────────────────────────────────────────────────────────────────────────

setup_main_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial" 2>/dev/null
    echo "$repo"
}

run_bash_guard() {
    local cmd="$1" cwd="$2"
    shift 2
    local env_args=()
    local kv
    for kv in "$@"; do env_args+=("$kv"); done
    # Hook reads JSON payload from stdin AND inspects process.cwd() — must cd to target.
    local payload
    payload="$(node -e '
const data = { tool_name: "Bash", tool_input: { command: process.argv[1] }, cwd: process.argv[2] };
process.stdout.write(JSON.stringify(data));
' -- "$cmd" "$cwd")"
    ( cd "$cwd" && env -i PATH="$PATH" HOME="${HOME:-$TMPDIR_BASE}" \
        "${env_args[@]}" \
        node "$AGENTS_DIR/hooks/enforce-worktree.js" <<< "$payload" )
}

guard_allows() {
    # The hook prints `{}` (empty JSON) for allow, or `{"decision":"block",...}` for block.
    local out="$1"
    [[ "$out" != *'"decision":"block"'* ]]
}

test_a_gh_api_contents_put_from_main_worktree_allows() {
    local repo; repo="$(setup_main_repo "A-contents-put")"
    local cmd='gh api -X PUT repos/owner/repo/contents/docs/history.md -F message=docs -F content=base64data'
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_allows "$out"; then
        pass "A: gh api -X PUT contents/ from main worktree (cwd in session) allows"
    else
        fail "A: gh api -X PUT contents/ from main worktree should allow ($out)"
    fi
}

test_a_gh_api_git_data_post_from_main_worktree_allows() {
    local repo; repo="$(setup_main_repo "A-git-data-post")"
    local cmd='gh api -X POST repos/owner/repo/git/blobs -f content=text -f encoding=utf-8'
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_allows "$out"; then
        pass "A: gh api -X POST git/blobs from main worktree (cwd in session) allows"
    else
        fail "A: gh api -X POST git/blobs from main worktree should allow ($out)"
    fi
}

test_a_gh_api_git_data_patch_from_main_worktree_allows() {
    local repo; repo="$(setup_main_repo "A-git-data-patch")"
    local cmd='gh api -X PATCH repos/owner/repo/git/refs/heads/main -f sha=abcdef'
    local out; out="$(run_bash_guard "$cmd" "$repo" ENFORCE_WORKTREE=on)"
    if guard_allows "$out"; then
        pass "A: gh api -X PATCH git/refs from main worktree (cwd in session) allows"
    else
        fail "A: gh api -X PATCH git/refs from main worktree should allow ($out)"
    fi
}

test_a_gh_api_put_blocked_when_cwd_not_in_session() {
    # When cwd is a non-git directory, no sessionRoots are derived → block.
    local nongit="$TMPDIR_BASE/A-nongit-$$"
    mkdir -p "$nongit"
    local cmd='gh api -X PUT repos/owner/repo/contents/docs/history.md -F message=docs'
    local out; out="$(run_bash_guard "$cmd" "$nongit" ENFORCE_WORKTREE=on)"
    if guard_allows "$out"; then
        fail "A: gh api -X PUT from non-git dir should block ($out)"
    else
        pass "A: gh api -X PUT from non-git dir blocks (no repo root)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Runner
# ─────────────────────────────────────────────────────────────────────────────

echo "=== feature-692: enforce-worktree gh api + classify() strip git ==="
echo ""

test_b_grep_with_quoted_git_verbs_is_read
test_b_real_git_commands_remain_write

test_a_gh_api_contents_put_from_main_worktree_allows
test_a_gh_api_git_data_post_from_main_worktree_allows
test_a_gh_api_git_data_patch_from_main_worktree_allows
test_a_gh_api_put_blocked_when_cwd_not_in_session

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
