# Heredoc-quoted tokens, FD redirect, newline injection, git -c flag,
# /dev/null compound, git-branch mutate/name/delete, #692 git-kind strip,
# git-update-ref, git-commit subcommand position, git-merge-base read vs write.
# Tags: scope:common

test_heredoc_quoted_tokens() {
    assert_classify "heredoc <<'EOF' (single-quoted token)" "cat <<'EOF'
hello
EOF" "write"
    assert_classify "heredoc <<\"EOF\" (double-quoted token)" 'cat <<"EOF"
hello
EOF' "write"
}

test_fd_redirect_documented_fp() {
    # FD-to-FD redirects do not write to a file; correctly classified as read.
    assert_classify "2>&1 (FD-to-FD, no file write)" 'cmd 2>&1' "read"
    assert_classify "1>&2 (FD-to-FD, no file write)" 'cmd 1>&2' "read"
}

test_newline_injection_write() {
    local cmd
    cmd="$(printf 'echo x\nrm foo')"
    # `rm` sits on a LATER LINE. In bash a newline is a command separator, but the
    # IR segment splitter does NOT split on newline — so `echo x\nrm foo` parses as
    # ONE `echo` segment with `rm` as an argv token, and isFileOpWriteIR (which is
    # per-segment/command-position) does NOT fire. isNewlineInjectedWriteIR strips
    # heredoc bodies, splits on unquoted newlines, and re-parses each line — this
    # restores the pre-#1296 coverage (the retired file-op regex's `[\s]` prefix
    # matched the newline). classify=read + isNewlineInjectedWriteIR=true.
    assert_write_ir "newline-embedded rm" "$cmd" newline
}

test_git_config_flag_commit_write() {
    # Retired git write. classify=read, isGitWriteIR sees `commit` past the -c flag.
    assert_write_ir "git -c config flag + commit" 'git -c core.safecrlf=false commit -m x' git
}

test_dev_null_compound() {
    # Retired file-op `rm` after a null-sink read segment. classify=read, isFileOpWriteIR=true.
    assert_write_ir "compound: read 2>/dev/null; rm foo" 'git status 2>/dev/null; rm foo' fileop
    assert_classify "compound: read 2>/dev/null && read" 'git status 2>/dev/null && git log' "read"
    assert_classify ">>/dev/null append null-sink" 'cmd >>/dev/null' "read"
    # Retired posix-redir: /dev/null/foo is a real in-scope file (not the null sink).
    # classify=read, isPosixRedirWriteIR=true.
    assert_write_ir "redirect to /dev/null/foo (not null-sink)" 'cmd > /dev/null/foo' posix
    assert_classify ">/dev/null 2>&1 (null-sink + FD-to-FD, read)" 'cmd >/dev/null 2>&1' "read"
}

test_git_branch_mutate_writes() {
    # Retired git writes (branch rename/copy). classify=read, isGitWriteIR=true.
    assert_write_ir "branch -m rename" 'git branch -m main feat' git
    assert_write_ir "branch -M force-rename" 'git branch -M old new' git
    assert_write_ir "branch -c copy" 'git branch -c base feat' git
    assert_write_ir "branch -C force-copy" 'git branch -C old new' git
}

test_git_branch_name_no_false_positive() {
    assert_classify "branch agents-env-consolidate (literal -d in name)" \
        'git branch agents-env-consolidate' "read"
    assert_classify "branch --list feat/agents-env-consolidate" \
        'git branch --list feat/agents-env-consolidate' "read"
    assert_classify "branch --contains HEAD" 'git branch --contains HEAD' "read"
}

test_git_branch_delete_writes() {
    # Retired git writes (branch delete). classify=read, isGitWriteIR=true.
    assert_write_ir "branch -d soft-delete is write" \
        'git branch -d already-merged' git
    assert_write_ir "branch -D force-delete is write" \
        'git branch -D fix/planner-drafts-context' git
    assert_write_ir "git -C path branch -D is write" \
        'git -C /path branch -D x' git
    assert_write_ir "git -C path branch -d is write" \
        'git -C /path branch -d x' git
}

# ============ #692: git-verb quoted-args false positive (Bug B) ============
test_git_kind_strips_quoted_args() {
    assert_classify "grep with quoted 'git push'" \
        'grep -n "git push" file.md' "read"
    assert_classify "grep with quoted 'git push|git commit'" \
        'grep -n "git push|git commit" path/to/file' "read"
    assert_classify "grep -E with quoted 'git push'" \
        'grep -nE "git push" docs/foo.md' "read"
    assert_classify "rg with quoted 'git commit'" \
        'rg "git commit" .' "read"
    assert_classify "cat | grep with quoted 'git push'" \
        'cat README.md | grep "git push"' "read"
    assert_classify "echo with quoted 'git commit -m test'" \
        'echo "Run git commit -m test"' "read"

    # Real git writes: classify=read (git WRITE_PATTERNS retired), isGitWriteIR=true.
    # The quoted-arg-strip false-positive guard above (read cases) still holds via
    # classify; the genuine writes are now caught by the IR predicate.
    assert_write_ir "real git commit -m" \
        'git commit -m "test"' git
    assert_write_ir "real git push origin main" \
        'git push origin main' git
    assert_write_ir "real git checkout -- file" \
        'git checkout -- file.txt' git
    assert_write_ir "real git stash push" \
        'git stash push -m "wip"' git
    assert_write_ir "real git -C path commit" \
        'git -C /path commit -m x' git
}

test_git_update_ref_write() {
    # Retired git writes (update-ref). classify=read, isGitWriteIR=true.
    assert_write_ir "git update-ref create" \
        'git update-ref refs/heads/feat HEAD' git
    assert_write_ir "git update-ref delete" \
        'git update-ref -d refs/heads/old' git
    assert_write_ir "git -C path update-ref" \
        'git -C /path update-ref refs/heads/feat HEAD' git
}

# ============ Bug 3: git-commit regex must require commit at subcommand position =====
test_git_commit_subcommand_position() {
    # Retired git writes at subcommand position. classify=read, isGitWriteIR=true.
    assert_write_ir "git commit -m" 'git commit -m x' git
    assert_write_ir "git -c <kv> commit -m" \
        'git -c core.safecrlf=false commit -m x' git
    assert_write_ir "git --no-pager commit -m" \
        'git --no-pager commit -m x' git
    assert_classify "git log -- hooks/pre-commit (filename pathspec)" \
        'git log -- hooks/pre-commit' "read"
    assert_classify "git log -- pre-commit.js (filename pathspec)" \
        'git log -- pre-commit.js' "read"
    assert_classify "git log --grep=\"commit message\"" \
        'git log --grep="commit message"' "read"
    assert_classify "git diff -- pre-commit (filename pathspec)" \
        'git diff -- pre-commit' "read"
}

# ============ #1095: git merge-base / merge-tree → read; merge-file → write ============
test_git_merge_base_read() {
    # FIXED BEHAVIOR (#1095):
    # git merge-base, merge-tree are read-only plumbing — classify as "read".
    # git merge-file writes merge results to its first file argument — classify as "write".
    assert_classify "git merge-base --is-ancestor HEAD origin/main → read" \
        'git merge-base --is-ancestor HEAD origin/main' "read"
    assert_classify "git merge-tree base branch1 branch2 → read" \
        'git merge-tree base branch1 branch2' "read"
    # merge-file writes results → retired git write: classify=read, isGitWriteIR=true.
    assert_write_ir "git merge-file a.txt b.txt c.txt → write" \
        'git merge-file a.txt b.txt c.txt' git
    assert_classify "git -C /path merge-base A B → read" \
        'git -C /path merge-base A B' "read"

    # git merge (the porcelain) is a write → retired: classify=read, isGitWriteIR=true.
    assert_write_ir "git merge --ff-only origin/main → write" \
        'git merge --ff-only origin/main' git
    assert_write_ir "git merge origin/main → write" \
        'git merge origin/main' git
    assert_write_ir "git -C /path merge origin/main → write" \
        'git -C /path merge origin/main' git
}

# ============ #1024: git stash drop/clear (ref-only) → read; push/pop/apply → write ============
test_git_stash_reclassify() {
    # NEW BEHAVIOR (will fail until bash-write-patterns.js git-stash-write is fixed):
    # drop/clear delete a stash ref without touching tracked files — read.
    # list/show are also read; subcommand-position match avoids FP on
    # `git stash list --grep=apply`.
    assert_classify "git stash drop → read" \
        'git stash drop' "read"
    assert_classify "git stash clear → read" \
        'git stash clear' "read"
    assert_classify "git stash drop stash@{0} → read" \
        'git stash drop stash@{0}' "read"
    assert_classify "git stash list --grep=apply → read" \
        'git stash list --grep=apply' "read"
    assert_classify "git stash show -p → read" \
        'git stash show -p' "read"
    assert_classify "git stash (bare) → read" \
        'git stash' "read"

    # push/pop/apply rewrite the working tree → retired git write:
    # classify=read, isGitWriteIR=true.
    assert_write_ir "git stash push -m x → write" \
        'git stash push -m x' git
    assert_write_ir "git stash pop → write" \
        'git stash pop' git
    assert_write_ir "git stash apply → write" \
        'git stash apply' git
    assert_write_ir "git -C /some/path stash push → write" \
        'git -C /some/path stash push' git
}
