# Basic write/read cases, error inputs, edge, idempotency, security, export shape.

# ============ Normal-block cases ============
#
# Post-#1296/#1400/#1401 retire: the rm/cp/mv/posix-redir/pwsh/git WRITE_PATTERNS
# entries were removed from classify(). Each such command's local-write blocking
# now lives at the enforce-worktree fast-allow gate via an IR predicate. The
# migrated contract is: classify()=="read" AND the matching isXWriteIR() is true
# (assert_write_ir). Commands whose patterns were NOT retired (sed -i / perl -i /
# patch / touch / pwsh-encoded / heredoc / here-string / interpreter-c) still
# classify()=="write" (assert_classify), because their detection never moved to
# the IR predicate layer.

# STILL-WRITE cases: classify() still returns "write" (patterns not retired).
STILL_WRITE_CASES=(
    'grep <<<"input"'      # here-string (posix kind, not retired)
    '-EncodedCommand abc'  # pwsh-encoded (not retired)
    '-enc abc'
    '--% Set-Content foo'  # ps-stop-parsing (not retired)
    "sed -i 's/a/b/' f"    # file-op sed-inplace (not retired)
    'perl -i.bak f'        # file-op perl-inplace (not retired)
    'patch -p1 < x'        # file-op patch (not retired)
    'touch f'              # file-op touch (not retired)
    # pwsh-ALIAS forms (sc/ac/ni/ri) keep their WRITE_PATTERNS entries — only the
    # full cmdlet forms (Set-Content / New-Item / …) were retired to the IR layer.
    'sc foo'
    'ac foo'
    'ni foo'
    'ri foo'
)

# RETIRED posix-redir writes: classify=read + isPosixRedirWriteIR=true.
POSIX_REDIR_CASES=(
    'echo x > foo'
    'cat a >> b'
    'tee -a foo'
    'cmd 1> out'
    'cmd 2> err'
    'cmd &> all'
)

# RETIRED pwsh writes: classify=read + isPwshWriteIR=true.
PWSH_CASES=(
    'Set-Content -Path foo -Value x'
    'Add-Content foo x'
    'Out-File foo'
    'New-Item foo'
    'Remove-Item foo'
)

# RETIRED file-op writes (rm/mv/cp): classify=read + isFileOpWriteIR=true.
FILEOP_CASES=(
    'rm foo'
    'mv a b'
    'cp a b'
)

# RETIRED git writes: classify=read + isGitWriteIR=true.
# NOTE: gh WRITE commands (Group B: pr merge, release create/edit/delete/upload,
# api -X POST/PUT/PATCH/DELETE, issue create/delete, repo delete) are NOT here.
# gh operations write to GitHub, not the LOCAL worktree, so classify() returns
# "read" AND no local-write IR predicate matches — gh write enforcement is owned
# solely by isGhWriteIR at the enforce-worktree gh session-scope gate. See READ_CASES.
GIT_WRITE_CASES=(
    'git commit -m x'
    'git push'
    'git merge x'
    'git merge-file a.txt base.txt b.txt'
    'git rebase x'
    'git reset --hard HEAD~1'
    'git am'
    'git cherry-pick x'
    'git revert x'
    'git checkout -- f'
    'git restore f'
    'git stash push'
    'git stash pop'
    'git worktree add /tmp/w'
    'git worktree remove /tmp/w'
    'git tag -d v1'
    'git tag v1.0'
)

test_heredoc_token_classified_write() {
    local cmd='cat <<EOF
hello
EOF'
    assert_classify "heredoc <<EOF" "$cmd" "write"
    assert_classify "heredoc <<-EOF" 'cat <<-EOF
x
EOF' "write"
}

test_write_cases() {
    local c
    for c in "${STILL_WRITE_CASES[@]}"; do
        assert_classify "still-write[$c]" "$c" "write"
    done
    for c in "${POSIX_REDIR_CASES[@]}"; do
        assert_write_ir "posix-redir[$c]" "$c" posix
    done
    for c in "${PWSH_CASES[@]}"; do
        assert_write_ir "pwsh[$c]" "$c" pwsh
    done
    for c in "${FILEOP_CASES[@]}"; do
        assert_write_ir "fileop[$c]" "$c" fileop
    done
    for c in "${GIT_WRITE_CASES[@]}"; do
        assert_write_ir "git-write[$c]" "$c" git
    done
}

# ============ Normal-allow: each should classify as "read" ============

READ_CASES=(
    'git status'
    'git log'
    'git fetch'
    'git diff'
    'git show'
    'gh pr view 1'
    'gh pr list'
    'gh issue view 1'
    'ls'
    'cat foo'
    'grep x foo'
    'echo hello'
    'pwd'
    'which node'
    'Get-Content foo'
    'git tag -l'
    'git tag --list'
    # Group A (always-allow gh commands) — fix/enforce-worktree-gh-whitelist
    'gh pr create --fill'
    'gh pr edit 1'
    'gh pr close 1'
    'gh pr comment 1'
    'gh pr review 1'
    'gh issue edit 1'
    'gh issue close 1'
    'gh issue comment 1'
    'gh repo create'
    'gh repo edit --private'
    'gh repo rename new-name'
    'gh repo archive owner/repo'
    # Group B gh WRITE commands (#1296): these write to GitHub, not the LOCAL worktree.
    # classify()'s contract is local-write detection, so they return "read". gh write
    # enforcement is handled separately by isGhWriteIR at the enforce-worktree gh gate.
    'gh pr merge 1'
    'gh release create v1'
    'gh api -X POST /repos'
    'gh api -X PUT /repos/o/r'
    'gh api -X PATCH /repos/o/r'
    'gh api -X DELETE /repos/o/r'
    'gh issue create'
    'gh issue delete 1'
    'gh repo delete owner/repo'
    'gh release edit v1'
    'gh release delete v1'
    'gh release upload v1 file.zip'
    'gh api --method POST /repos'
    'gh api --method DELETE /repos/o/r'
    'gh api -XDELETE /repos/o/r'
    'gh api --method=DELETE /repos/o/r'
    'gh api -X=POST /repos'
    # /dev/null null-sink — read-only redirects must not be classified as write
    'git status 2>/dev/null'
    'ls >/dev/null'
    'cmd &>/dev/null'
    'grep pattern file 2>/dev/null'
    # Bug 3: git-commit regex must not false-positive on filenames containing "commit"
    'git log -- hooks/pre-commit'
    'git log -- pre-commit.js'
    'git log --grep="commit message"'
    'git diff -- pre-commit'
)

test_read_cases() {
    local c
    for c in "${READ_CASES[@]}"; do
        assert_classify "read[$c]" "$c" "read"
    done
}

# ============ Error / non-string inputs ============

test_classify_null() {
    local got; got="$(classify_cmd "__NULL__")"
    if [ "$got" = "read" ]; then
        pass "classify(null) -> read (fail-open)"
    else
        fail "classify(null) expected 'read', got '$got'"
    fi
}

test_classify_undefined() {
    local got; got="$(classify_cmd "__UNDEF__")"
    if [ "$got" = "read" ]; then
        pass "classify(undefined) -> read (fail-open)"
    else
        fail "classify(undefined) expected 'read', got '$got'"
    fi
}

test_classify_number() {
    local got; got="$(classify_cmd "__NUM__")"
    if [ "$got" = "read" ]; then
        pass "classify(123) -> read (fail-open)"
    else
        fail "classify(123) expected 'read', got '$got'"
    fi
}

test_classify_empty() {
    assert_classify "classify('')" "" "read"
}

# ============ Edge cases ============

test_compound_command() {
    # Retired file-op: `rm` in a later segment. classify=read, isFileOpWriteIR
    # sees the segment (unquoted `&&` splits it into its own segment).
    assert_write_ir "compound 'cd /tmp && rm foo'" 'cd /tmp && rm foo' fileop
}

test_quoted_false_positive_documented() {
    assert_classify "quoted '>' inside double-quotes (#460 fixed)" 'echo "a > b"' "read"
}

test_unicode_command() {
    # Retired posix-redir. classify=read, isPosixRedirWriteIR=true.
    assert_write_ir "unicode redirect" 'echo 絵文字 > foo' posix
}

test_very_long_command() {
    local long; long="$(printf 'a%.0s' $(seq 1 10240))"
    assert_classify "10KB command (no write tokens)" "echo $long" "read"
    # Retired posix-redir. classify=read, isPosixRedirWriteIR=true.
    assert_write_ir "10KB command (with write token)" "echo $long > foo" posix
}

test_multiline_command() {
    local cmd='echo a
echo b > c'
    # Retired posix-redir in a later line. classify=read, isPosixRedirWriteIR=true.
    assert_write_ir "multi-line with redirect" "$cmd" posix
}

# ============ Idempotency ============

test_idempotency() {
    # Idempotency = same input yields the same output across repeated calls.
    # Read-cmd idempotency (unchanged): `git status` → read both times.
    local a b
    a="$(classify_cmd 'git status')"
    b="$(classify_cmd 'git status')"
    if [ "$a" = "$b" ] && [ "$a" = "read" ]; then
        pass "classify is idempotent (read)"
    else
        fail "classify not idempotent: a=$a b=$b"
    fi
    # Retired-write idempotency: `rm foo` now classifies "read" (file-op pattern
    # retired — write-detection moved to isFileOpWriteIR). The pre-#1296 pin
    # expected "write"; that was stale, NOT a non-idempotency bug (both calls
    # already agreed). We now assert classify() is idempotent at its true value
    # ("read") AND that isFileOpWriteIR is likewise idempotent (both "true").
    a="$(classify_cmd 'rm foo')"
    b="$(classify_cmd 'rm foo')"
    local p1 p2
    p1="$(pred_targets isFileOpWriteIR 'rm foo')"
    p2="$(pred_targets isFileOpWriteIR 'rm foo')"
    if [ "$a" = "$b" ] && [ "$a" = "read" ] && [ "$p1" = "$p2" ] && [ "$p1" = "true" ]; then
        pass "classify + isFileOpWriteIR idempotent for retired file-op (read + true)"
    else
        fail "retired file-op not idempotent: classify a=$a b=$b; isFileOpWriteIR p1=$p1 p2=$p2"
    fi
}

# ============ Security ============

test_security_compound_destructive() {
    # Retired file-op `rm` in a later `;` segment. classify=read, isFileOpWriteIR
    # sees the segment → the destructive compound still reaches the scope pipeline.
    assert_write_ir "git status; rm -rf /" 'git status; rm -rf /' fileop
}

test_security_encoded_bypass() {
    # pwsh-encoded pattern was NOT retired → classify still returns "write".
    assert_classify "PowerShell -enc bypass" '-enc SQBuAHYAbwBrAGUA' "write"
}

test_documented_python_false_negative() {
    assert_classify "python -c open() (documented FN)" 'python -c "open(\"f\",\"w\").write(\"x\")"' "read"
}

# ============ WRITE_PATTERNS export ============

test_write_patterns_export() {
    local result
    result="$(run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const ok = Array.isArray(m.WRITE_PATTERNS) && m.WRITE_PATTERNS.length > 0
          && m.WRITE_PATTERNS.every(p => p && typeof p.name === 'string'
              && p.regex instanceof RegExp && typeof p.kind === 'string');
        console.log(ok ? 'ok' : 'bad');
      } catch (e) { console.log('ERROR: ' + e.message); }
    " 2>/dev/null)"
    if [ "$result" = "ok" ]; then
        pass "WRITE_PATTERNS exported as array of {name, regex, kind}"
    else
        fail "WRITE_PATTERNS export shape wrong: $result"
    fi
}
