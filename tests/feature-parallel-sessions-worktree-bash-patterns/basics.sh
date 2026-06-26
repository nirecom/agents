# Basic write/read cases, error inputs, edge, idempotency, security, export shape.

# ============ Normal-block: each should classify as "write" ============

WRITE_CASES=(
    'echo x > foo'
    'cat a >> b'
    'tee -a foo'
    'cmd 1> out'
    'cmd 2> err'
    'cmd &> all'
    'grep <<<"input"'
    'Set-Content -Path foo -Value x'
    'Add-Content foo x'
    'Out-File foo'
    'New-Item foo'
    'Remove-Item foo'
    'sc foo'
    'ac foo'
    'ni foo'
    'ri foo'
    '-EncodedCommand abc'
    '-enc abc'
    '--% Set-Content foo'
    'rm foo'
    'mv a b'
    'cp a b'
    "sed -i 's/a/b/' f"
    'perl -i.bak f'
    'patch -p1 < x'
    'touch f'
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
    'gh pr merge 1'
    'gh release create v1'
    'gh api -X POST /repos'
    'gh api -X PUT /repos/o/r'
    'gh api -X PATCH /repos/o/r'
    'gh api -X DELETE /repos/o/r'
    # gh issue create: sanctioned via /issue-create skill only (#672).
    'gh issue create'
    # Group B (session-scoped writes) — added in fix/enforce-worktree-gh-whitelist
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
    for c in "${WRITE_CASES[@]}"; do
        assert_classify "write[$c]" "$c" "write"
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
    assert_classify "compound 'cd /tmp && rm foo'" 'cd /tmp && rm foo' "write"
}

test_quoted_false_positive_documented() {
    assert_classify "quoted '>' inside double-quotes (#460 fixed)" 'echo "a > b"' "read"
}

test_unicode_command() {
    assert_classify "unicode redirect" 'echo 絵文字 > foo' "write"
}

test_very_long_command() {
    local long; long="$(printf 'a%.0s' $(seq 1 10240))"
    assert_classify "10KB command (no write tokens)" "echo $long" "read"
    assert_classify "10KB command (with write token)" "echo $long > foo" "write"
}

test_multiline_command() {
    local cmd='echo a
echo b > c'
    assert_classify "multi-line with redirect" "$cmd" "write"
}

# ============ Idempotency ============

test_idempotency() {
    local a b
    a="$(classify_cmd 'git status')"
    b="$(classify_cmd 'git status')"
    if [ "$a" = "$b" ] && [ "$a" = "read" ]; then
        pass "classify is idempotent (read)"
    else
        fail "classify not idempotent: a=$a b=$b"
    fi
    a="$(classify_cmd 'rm foo')"
    b="$(classify_cmd 'rm foo')"
    if [ "$a" = "$b" ] && [ "$a" = "write" ]; then
        pass "classify is idempotent (write)"
    else
        fail "classify not idempotent: a=$a b=$b"
    fi
}

# ============ Security ============

test_security_compound_destructive() {
    assert_classify "git status; rm -rf /" 'git status; rm -rf /' "write"
}

test_security_encoded_bypass() {
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
