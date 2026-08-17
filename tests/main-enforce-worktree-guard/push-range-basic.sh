# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, git, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-enforce-worktree-push-fix-range.sh (same-repo cases).
# Cases: the `Fix 1: …` family. Cross-repo cases: push-range-cross-repo.sh.

# isAllowedPushAllExcluded(cmd, repoRoot, excludePatterns): `git push` from the
# main checkout is allowed only when every file in every outgoing commit of the
# `<upstream>..HEAD` RANGE is covered by ENFORCE_WORKTREE_EXCLUDE. Scanning the
# net HEAD diff instead would miss a file added and then deleted within the
# range, which is what the `deleted in N+1` case pins.

# Any refspec shape the resolver cannot map to one unambiguous upstream range —
# colon refspecs, refs/heads prefixes, `+` force markers, multiple refspecs,
# `-u origin` with no branch, no upstream at all — must fail closed.

# Fragment-local helpers carry a `pr_` prefix: fragments share one shell.

PR_EXCLUDE="ENFORCE_WORKTREE_EXCLUDE=**/docs/**"

pr_commit() {
    local repo="$1" path="$2" msg="$3"
    mkdir -p "$(dirname "$repo/$path")"
    echo "x" > "$repo/$path"
    git -C "$repo" add "$path"
    git -C "$repo" commit -q -m "$msg"
}

echo "=== Fix 1: isAllowedPushAllExcluded (same-repo) ==="

# --- ALLOW ---
pr_repo="$(setup_repo_with_remote "no-outgoing")"
pr_out="$(run_bash_guard "git push" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision allow "$pr_out" \
    "Fix 1: push with no outgoing commits allows" \
    "Fix 1: push with no outgoing commits should allow"

pr_repo="$(setup_repo_with_remote "all-excl")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_commit "$pr_repo" "docs/b.md" "doc b"
pr_out="$(run_bash_guard "git push" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision allow "$pr_out" \
    "Fix 1: push with all outgoing commits docs/** allows" \
    "Fix 1: push with all-docs outgoing commits should allow"

# Explicit refspec: range is origin/feature..HEAD, not origin/main..HEAD.
pr_repo="$(setup_repo_with_remote "explicit-br")"
git -C "$pr_repo" switch -q -c feature
git -C "$pr_repo" push -q -u origin feature 2>/dev/null
pr_commit "$pr_repo" "docs/a.md" "doc on feature"
pr_out="$(run_bash_guard "git push origin feature" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision allow "$pr_out" \
    "Fix 1: push origin <branch> with EXCLUDE-only commits allows" \
    "Fix 1: push origin <branch> EXCLUDE-only should allow"

pr_repo="$(setup_repo_with_remote "no-args-up")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision allow "$pr_out" \
    "Fix 1: bare 'git push' with upstream + EXCLUDE-only allows" \
    "Fix 1: bare 'git push' with upstream EXCLUDE-only should allow"

# Remote-only form: one remote + a tracking branch resolves to origin/main..HEAD.
pr_repo="$(setup_repo_with_remote "origin-only")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push origin" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision allow "$pr_out" \
    "Fix 1: 'git push origin' with tracking + EXCLUDE-only allows" \
    "Fix 1: 'git push origin' EXCLUDE-only should allow"

pr_repo="$(setup_repo_with_remote "u-origin-br")"
git -C "$pr_repo" switch -q -c feature
git -C "$pr_repo" push -q -u origin feature 2>/dev/null
pr_commit "$pr_repo" "docs/a.md" "doc on feature"
pr_out="$(run_bash_guard "git push -u origin feature" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision allow "$pr_out" \
    "Fix 1: 'git push -u origin <branch>' with EXCLUDE-only allows" \
    "Fix 1: 'git push -u origin <branch>' EXCLUDE-only should allow"

# --- BLOCK ---
pr_repo="$(setup_repo_with_remote "one-src")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_commit "$pr_repo" "src/main.js" "src code"
pr_out="$(run_bash_guard "git push" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: push with one src commit blocks" \
    "Fix 1: push with non-excluded src commit should block"

# Net HEAD diff vs upstream is empty here; only the range scan sees src/main.js.
pr_repo="$(setup_repo_with_remote "src-reverted")"
pr_commit "$pr_repo" "src/main.js" "add src code"
git -C "$pr_repo" rm -q "src/main.js"
git -C "$pr_repo" commit -q -m "remove src code"
pr_out="$(run_bash_guard "git push" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: push with non-excluded file in range (deleted in N+1) blocks" \
    "Fix 1: push with deleted-but-historical src file should block"

pr_repo="$(setup_repo_with_remote "colon-rs")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push origin HEAD:main" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: push with colon refspec blocks (fail-closed)" \
    "Fix 1: push with colon refspec should block (fail-closed)"

pr_repo="$(setup_repo_with_remote "refs-heads")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push origin refs/heads/main" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: push with refs/heads prefix blocks (fail-closed)" \
    "Fix 1: push with refs/heads prefix should block"

pr_repo="$(setup_repo_with_remote "force-mark")"
git -C "$pr_repo" switch -q -c feature
git -C "$pr_repo" push -q -u origin feature 2>/dev/null
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push origin +feature" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: push with '+' force marker blocks (fail-closed)" \
    "Fix 1: push with '+' force marker should block"

pr_repo="$(setup_repo_with_remote "multi-rs")"
git -C "$pr_repo" switch -q -c feature
git -C "$pr_repo" push -q -u origin feature 2>/dev/null
git -C "$pr_repo" switch -q main
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push origin feature main" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: push with multiple refspecs blocks (fail-closed)" \
    "Fix 1: push with multiple refspecs should block"

pr_repo="$(setup_repo_with_remote "u-ambig")"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push -u origin" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: 'git push -u origin' ambiguous blocks (fail-closed)" \
    "Fix 1: 'git push -u origin' (no branch) should block"

# --no-upstream: the remote exists but the branch has no tracking ref.
pr_repo="$(setup_repo_with_remote "no-upstream" --no-upstream)"
pr_commit "$pr_repo" "docs/a.md" "doc a"
pr_out="$(run_bash_guard "git push" "$pr_repo" ENFORCE_WORKTREE=on "$PR_EXCLUDE")"
assert_decision block "$pr_out" \
    "Fix 1: 'git push' with no upstream blocks (fail-closed)" \
    "Fix 1: 'git push' with no upstream should block"
