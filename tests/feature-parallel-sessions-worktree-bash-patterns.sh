#!/bin/bash
# tests/feature-parallel-sessions-worktree-bash-patterns.sh
#
# Implementation complete. Tests verify the production contract.

# Implementation tracked in: ~/.claude/plans/intent-20260505-211305-detail.md
#
# Targets: hooks/lib/bash-write-patterns.js

set -u

AGENTS_DIR="/c/git/worktrees/parallel-sessions-worktree/agents"
# Convert to Windows-native path for Node.js require() on Windows (cygpath -m gives C:/... form)
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'pst-bp-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Classify a command. Prints "read", "write", or "ERROR: ...".
classify_cmd() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.classify;
        const arg = process.argv[1];
        let v;
        if (arg === '__NULL__') v = null;
        else if (arg === '__UNDEF__') v = undefined;
        else if (arg === '__NUM__') v = 123;
        else v = arg;
        console.log(fn(v));
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$1" 2>/dev/null
}

assert_classify() {
    local desc="$1" cmd="$2" expected="$3"
    local got
    got="$(classify_cmd "$cmd")"
    if [ "$got" = "$expected" ]; then
        pass "$desc -> $expected"
    else
        fail "$desc: expected '$expected', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

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
    'git rebase x'
    'git reset --hard HEAD~1'
    'git am'
    'git cherry-pick x'
    'git revert x'
    'git branch -d x'
    'git branch -D x'
    'git checkout -- f'
    'git restore f'
    'git stash push'
    'git stash pop'
    'git stash drop'
    'git worktree add /tmp/w'
    'git worktree remove /tmp/w'
    'gh pr create --fill'
    'gh pr edit 1'
    'gh pr close 1'
    'gh pr merge 1'
    'gh pr comment 1'
    'gh pr review 1'
    'gh issue create'
    'gh release create v1'
    'gh repo create'
    'gh api -X POST /repos'
    'gh api -X PUT /repos/o/r'
    'gh api -X PATCH /repos/o/r'
    'gh api -X DELETE /repos/o/r'
    'gh repo delete owner/repo'
    'gh repo edit --private'
    'git tag -d v1'
    'git tag v1.0'
)

# Heredoc: skip true heredoc shell parsing in tests; use literal substring assertion
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
    # Contract: graceful fail-open -> "read"
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
    # Documented limitation: quoted '>' inside echo is still treated as write.
    assert_classify "quoted '>' (documented FP)" 'echo "a > b"' "write"
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
    # Documented limitation: python -c "open(...)" cannot be detected.
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

test_heredoc_quoted_tokens() {
    # <<'EOF' and <<"EOF" (no-interpolation variants) still contain << token -> write
    assert_classify "heredoc <<'EOF' (single-quoted token)" "cat <<'EOF'
hello
EOF" "write"
    assert_classify "heredoc <<\"EOF\" (double-quoted token)" 'cat <<"EOF"
hello
EOF' "write"
}

test_fd_redirect_documented_fp() {
    # Documented false positive: FD-to-FD redirects (2>&1, 1>&2) contain '>'
    # and are classified as write by the pattern, even though no file is written.
    assert_classify "2>&1 (documented FP - no file write)" 'cmd 2>&1' "write"
    assert_classify "1>&2 (documented FP - no file write)" 'cmd 1>&2' "write"
}

test_newline_injection_write() {
    # Safe first token but write token on embedded newline line
    local cmd
    cmd="$(printf 'echo x\nrm foo')"
    assert_classify "newline-embedded rm" "$cmd" "write"
}

test_git_config_flag_commit_write() {
    # git -c flag before mutating subcommand is still write
    assert_classify "git -c config flag + commit" 'git -c core.safecrlf=false commit -m x' "write"
}

# ============ Run all ============

test_write_cases
test_heredoc_token_classified_write
test_read_cases
test_classify_null
test_classify_undefined
test_classify_number
test_classify_empty
test_compound_command
test_quoted_false_positive_documented
test_unicode_command
test_very_long_command
test_multiline_command
test_idempotency
test_security_compound_destructive
test_security_encoded_bypass
test_documented_python_false_negative
test_write_patterns_export
test_heredoc_quoted_tokens
test_fd_redirect_documented_fp
test_newline_injection_write
test_git_config_flag_commit_write

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
