#!/bin/bash
# tests/feature-parallel-sessions-worktree-bash-patterns.sh
#
# Implementation complete. Tests verify the production contract.

# Implementation tracked in: ~/.claude/plans/intent-20260505-211305-detail.md
#
# Targets: hooks/lib/bash-write-patterns.js

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    'git checkout -- f'
    'git restore f'
    'git stash push'
    'git stash pop'
    'git stash drop'
    'git worktree add /tmp/w'
    'git worktree remove /tmp/w'
    'gh pr merge 1'
    'gh release create v1'
    'gh api -X POST /repos'
    'gh api -X PUT /repos/o/r'
    'gh api -X PATCH /repos/o/r'
    'gh api -X DELETE /repos/o/r'
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
    # Group A (always-allow gh commands) — fix/enforce-worktree-gh-whitelist
    # These are reclassified from "write" to "read" so the worktree guard
    # never blocks them, regardless of cwd / branch / session scope.
    'gh pr create --fill'
    'gh pr edit 1'
    'gh pr close 1'
    'gh pr comment 1'
    'gh pr review 1'
    'gh issue create'
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
    # `git log -- <pathspec>` and `git diff -- <pathspec>` are read-only even when
    # pathspec contains the literal token "commit" (e.g., hooks/pre-commit).
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

test_dev_null_compound() {
    # null-sink followed by actual write — rm catches it
    assert_classify "compound: read 2>/dev/null; rm foo" 'git status 2>/dev/null; rm foo' "write"
    # null-sink followed by another read command — stays read
    assert_classify "compound: read 2>/dev/null && read" 'git status 2>/dev/null && git log' "read"
    # append form to /dev/null is also null-sink
    assert_classify ">>/dev/null append null-sink" 'cmd >>/dev/null' "read"
    # subpath /dev/null/foo is a real file (not null-sink) — must remain write
    assert_classify "redirect to /dev/null/foo (not null-sink)" 'cmd > /dev/null/foo' "write"
    # stdout to /dev/null with 2>&1 — 2>&1 documented FP preserved
    assert_classify ">/dev/null 2>&1 (documented FP preserved)" 'cmd >/dev/null 2>&1' "write"
}

test_git_branch_mutate_writes() {
    assert_classify "branch -m rename" 'git branch -m main feat' "write"
    assert_classify "branch -M force-rename" 'git branch -M old new' "write"
    assert_classify "branch -c copy" 'git branch -c base feat' "write"
    assert_classify "branch -C force-copy" 'git branch -C old new' "write"
}

test_git_branch_name_no_false_positive() {
    assert_classify "branch agents-env-consolidate (literal -d in name)" \
        'git branch agents-env-consolidate' "read"
    assert_classify "branch --list feat/agents-env-consolidate" \
        'git branch --list feat/agents-env-consolidate' "read"
    assert_classify "branch --contains HEAD" 'git branch --contains HEAD' "read"
}

test_git_branch_delete_writes() {
    # -d/-D were briefly classified as read in PR #20; reverted because
    # the read/write taxonomy is location-axis thinking, while the right
    # axis for branch deletion is target-axis. Now: -d/-D are write, gated
    # exclusively by enforce-worktree's marker-file exemption written by
    # /worktree-end. Direct ad-hoc invocations from any worktree are blocked.
    assert_classify "branch -d soft-delete is write" \
        'git branch -d already-merged' "write"
    assert_classify "branch -D force-delete is write" \
        'git branch -D fix/planner-drafts-context' "write"
    assert_classify "git -C path branch -D is write" \
        'git -C /path branch -D x' "write"
    assert_classify "git -C path branch -d is write" \
        'git -C /path branch -d x' "write"
}

test_gh_group_a_with_heredoc_classified_read() {
    local cmd1='gh pr create --body "$(cat <<'"'"'EOF'"'"'
body text
EOF
)"'
    assert_classify "gh pr create + heredoc body" "$cmd1" "read"

    local cmd2='gh issue create --title T --body "$(cat <<EOF
content
EOF
)"'
    assert_classify "gh issue create + heredoc body" "$cmd2" "read"

    assert_classify "gh pr edit plain body" 'gh pr edit 1 --body "x"' "read"
}

test_gh_group_a_with_redirect_still_write() {
    # redirect (posix-redirect) is not in QUOTING_ONLY → override does not apply
    assert_classify "gh pr create + redirect to file" \
        'gh pr create --body "x" > out.txt' "write"
}

test_git_update_ref_write() {
    assert_classify "git update-ref create" \
        'git update-ref refs/heads/feat HEAD' "write"
    assert_classify "git update-ref delete" \
        'git update-ref -d refs/heads/old' "write"
    assert_classify "git -C path update-ref" \
        'git -C /path update-ref refs/heads/feat HEAD' "write"
}

# ============ Bug 3: git-commit regex must require commit at subcommand position =====
# Old regex /\bgit\b.*\bcommit\b/ false-positives on filenames like hooks/pre-commit.
# New regex must allow `git -<flag> [arg] commit` (subcommand position) as write,
# but treat `commit` appearing only inside a pathspec/grep arg as read.
test_git_commit_subcommand_position() {
    # Real commits — must be classified as write
    assert_classify "git commit -m" 'git commit -m x' "write"
    assert_classify "git -c <kv> commit -m" \
        'git -c core.safecrlf=false commit -m x' "write"
    assert_classify "git --no-pager commit -m" \
        'git --no-pager commit -m x' "write"
    # Read-only commands where "commit" appears as a filename or grep value
    assert_classify "git log -- hooks/pre-commit (filename pathspec)" \
        'git log -- hooks/pre-commit' "read"
    assert_classify "git log -- pre-commit.js (filename pathspec)" \
        'git log -- pre-commit.js' "read"
    assert_classify "git log --grep=\"commit message\"" \
        'git log --grep="commit message"' "read"
    assert_classify "git diff -- pre-commit (filename pathspec)" \
        'git diff -- pre-commit' "read"
}

# ============ Quoted-arg stripping for file-op patterns ============
# After stripQuotedArgs is applied to file-op kind patterns, write tokens
# (cp/mv/rm/touch) appearing only inside quoted arguments must not cause
# false-positive write classification.

test_quoted_arg_no_false_positive_file_op() {
    assert_classify "doc-append --subject \"cp files\"" \
        'doc-append --subject "cp files"' "read"
    assert_classify "doc-append --subject \"mv old new\"" \
        'doc-append --subject "mv old new"' "read"
    assert_classify "doc-append --subject \"rm tmp\"" \
        'doc-append --subject "rm tmp"' "read"
    assert_classify "doc-append --subject \"touch file.txt\"" \
        'doc-append --subject "touch file.txt"' "read"
}

# Interpreter -c / -Command always classifies as write regardless of payload.

test_interpreter_c_always_write() {
    assert_classify 'bash -c "rm foo"' 'bash -c "rm foo"' "write"
    assert_classify 'sh -c "echo hello"' 'sh -c "echo hello"' "write"
    assert_classify 'pwsh -Command "Get-Content foo"' 'pwsh -Command "Get-Content foo"' "write"
    assert_classify 'zsh -c "ls"' 'zsh -c "ls"' "write"
}

# Documented FN: command name itself wrapped in quotes — strip removes it
# entirely, leaving no token to match. Result is "read".

test_cosmetic_quote_file_op_documented_fn() {
    assert_classify '"cp" src dst (FN-1: command-name quoted)' \
        '"cp" src dst' "read"
}

# Heredoc detection must survive the quoted-arg stripping pass.

test_heredoc_still_classified_after_strip() {
    assert_classify 'cat <<EOF (post-strip)' 'cat <<EOF' "write"
    assert_classify "cat <<'EOF' (post-strip)" "cat <<'EOF'" "write"
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
test_dev_null_compound
test_git_branch_mutate_writes
test_git_branch_name_no_false_positive
test_git_branch_delete_writes
test_gh_group_a_with_heredoc_classified_read
test_gh_group_a_with_redirect_still_write
test_git_update_ref_write
test_git_commit_subcommand_position
test_quoted_arg_no_false_positive_file_op
test_interpreter_c_always_write
test_cosmetic_quote_file_op_documented_fn
test_heredoc_still_classified_after_strip

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
