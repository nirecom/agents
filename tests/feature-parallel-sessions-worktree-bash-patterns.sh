#!/bin/bash
# tests/feature-parallel-sessions-worktree-bash-patterns.sh
# Tests: agents/bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create-dispatch.sh, hooks/lib/bash-write-patterns.js, hooks/pre-commit, hooks/pre-commit.
# Tags: git, pre-commit, hook, issue-create, github
#
# Implementation complete. Tests verify the production contract.

# Implementation tracked in: ~/.workflow-plans/intent-20260505-211305-detail.md
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
    # Previously a documented false positive (write); fixed by #460 (posix-redir kind + STRIP_KINDS).
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
    assert_classify "gh issue create + heredoc body" "$cmd2" "write"

    assert_classify "gh pr edit plain body" 'gh pr edit 1 --body "x"' "read"
}

test_gh_group_a_with_redirect_still_write() {
    # redirect (posix-redirect) is not in QUOTING_ONLY → override does not apply
    assert_classify "gh pr create + redirect to file" \
        'gh pr create --body "x" > out.txt' "write"
}

test_gh_group_a_heredoc_body_with_write_pattern_is_read() {
    # Case 1: gh pr create heredoc body containing git push
    local cmd1
    cmd1=$(printf 'gh pr create --body "$(cat <<EOF\ngit push origin main\nEOF\n)"')
    assert_classify "gh pr create heredoc body with git push is read" "$cmd1" "read"

    # Case 2: gh issue create heredoc body containing rm -rf
    local cmd2
    cmd2=$(printf 'gh issue create --title "T" --body "$(cat <<EOF\nrm -rf /tmp/x\nEOF\n)"')
    assert_classify "gh issue create heredoc body with rm -rf is write" "$cmd2" "write"

    # Case 3: gh pr edit heredoc body containing npm install
    local cmd3
    cmd3=$(printf 'gh pr edit 1 --body "$(cat <<EOF\nnpm install\nEOF\n)"')
    assert_classify "gh pr edit heredoc body with npm install is read" "$cmd3" "read"

    # Case 4: gh repo edit heredoc body containing posix redirect char
    local cmd4
    cmd4=$(printf 'gh repo edit --description "$(cat <<EOF\n> file.txt\nEOF\n)"')
    assert_classify "gh repo edit heredoc body with redirect char is read" "$cmd4" "read"

    # Case 5: <<-EOF (tab-indented closing) heredoc body containing git commit
    local cmd5
    cmd5=$(printf 'gh pr create --body "$(cat <<-EOF\n\tgit commit -m x\n\tEOF\n)"')
    assert_classify "gh pr create <<-EOF heredoc body with git commit is read" "$cmd5" "read"

    # Case 6: heredoc body with write pattern + external redirect — external redirect wins
    local cmd6
    cmd6=$(printf 'gh pr create --body "$(cat <<EOF\ngit push origin\nEOF\n)" > out.txt')
    assert_classify "gh pr create heredoc body with write pattern plus external redirect is write" "$cmd6" "write"

    # Case 7: non-Group-A command with heredoc body containing git push — no override
    local cmd7
    cmd7=$(printf 'echo "$(cat <<EOF\ngit push\nEOF\n)"')
    assert_classify "non-group-a heredoc body with git push is write" "$cmd7" "write"

    # Case 8: gh pr create heredoc body containing tee -a
    local cmd8
    cmd8=$(printf 'gh pr create --body "$(cat <<EOF\ntee -a foo\nEOF\n)"')
    assert_classify "gh pr create heredoc body with tee -a is read" "$cmd8" "read"

    # Case 9: #369 original repro
    local cmd9
    cmd9=$(printf 'gh issue create --title "T" --body "$(cat <<EOF\nThis is the background.\ngit push origin main\nMore text.\nEOF\n)"')
    assert_classify "gh issue create heredoc body #369 original repro" "$cmd9" "write"

    # Case 10: lazy-match regression — body contains "this is not EOF" as inner line
    local cmd10
    cmd10=$(printf 'gh pr create --body "$(cat <<EOF\nthis is not EOF\ngit push\nEOF\n)"')
    assert_classify "gh pr create heredoc body lazy-match regression with inner EOF-like line" "$cmd10" "read"

    # Case 11: `bash <<EOF` (interpreter heredoc, not cat) — must remain write
    local cmd11
    cmd11=$(printf 'gh pr create --body "$(bash <<EOF\nrm -rf /tmp/x\nEOF\n)"')
    assert_classify "gh pr create with interpreter heredoc (bash <<EOF rm -rf) is write" "$cmd11" "write"

    # Case 12: unquoted heredoc body with command substitution — must remain write
    local cmd12
    cmd12=$(printf 'gh pr create --body "$(cat <<EOF\n$(rm -rf /tmp/x)\nEOF\n)"')
    assert_classify "gh pr create unquoted heredoc body with command substitution is write" "$cmd12" "write"

    # Case 13: quoted heredoc body with literal $() — safe to strip → read
    local cmd13
    cmd13=$(printf "gh pr create --body \"\$(cat <<'EOF'\n\$(rm -rf /tmp/x)\nEOF\n)\"")
    assert_classify "gh pr create quoted heredoc body with literal dollar-paren is read" "$cmd13" "read"

    # Case 14: `cat <<EOF > out.txt` — rest-of-line redirect on opener must remain visible → write
    local cmd14
    cmd14=$(printf 'gh pr create --body "x"; cat <<EOF > out.txt\nbody\nEOF')
    assert_classify "cat heredoc with rest-of-line redirect after opener is write" "$cmd14" "write"

    # Case 15: unquoted heredoc body with backticks — must remain write
    local cmd15
    cmd15=$(printf 'gh pr create --body "$(cat <<EOF\n`rm -rf /tmp/x`\nEOF\n)"')
    assert_classify "gh pr create unquoted heredoc body with backticks is write" "$cmd15" "write"
}

# ============ Group A inline-body stripping (#596) ============
# Fix #596: classify() must strip inline --body "..." / --title "..." values from
# Group A commands (gh pr/issue/repo create/edit/...) AND from known dispatch
# invocations (e.g. bash .../bin/github-issues/issue-create-dispatch.sh) before
# re-scanning for git/file-op write patterns.

test_gh_group_a_inline_body_stripping() {
    # gh issue create: always write (#672 — sanctioned via /issue-create skill only)
    assert_classify "gh issue create --body containing 'git commit'" \
        'gh issue create --body "git commit"' "write"
    assert_classify "gh issue create --body containing 'git push origin main'" \
        'gh issue create --body "git push origin main"' "write"
    assert_classify "gh issue create --body containing ISSUE_CLOSE_SKILL prefix" \
        'gh issue create --body "ISSUE_CLOSE_SKILL=1 git commit -m fix"' "write"

    # Known dispatch script: absolute POSIX path
    assert_classify "bash <abs path>/issue-create-dispatch.sh ... --body 'git commit'" \
        'bash "/absolute/path/bin/github-issues/issue-create-dispatch.sh" --verdict none -- --title "T" --body "git commit"' "read"

    # Known dispatch script: Windows absolute path form
    assert_classify "bash <C:/...>/issue-create-dispatch.sh ... --body 'git commit'" \
        'bash "C:/git/agents/bin/github-issues/issue-create-dispatch.sh" --verdict none -- --body "git commit"' "read"

    # Edge: empty body — still write (gh issue create is always write)
    assert_classify "gh issue create --body ''" \
        'gh issue create --body ""' "write"

    # Edge: body contains only safe text — still write
    assert_classify "gh issue create --body 'normal body text'" \
        'gh issue create --body "normal body text"' "write"

    # Edge: --body-file — still write (gh issue create is always write)
    assert_classify "gh issue create --body-file /path/to/file.md" \
        'gh issue create --body-file /path/to/file.md' "write"

    # Security: real git commit (no Group A prefix) must remain write
    assert_classify "real 'git commit -m' must remain write" \
        'git commit -m "message"' "write"

    # Security: unknown bash script invocation must NOT get the known-path
    # heredoc-body stripping override. Use a `cat <<EOF` heredoc body as the
    # probe: stripHeredocBody only runs for known paths / Group A, so an
    # unknown-path heredoc body remains visible to the classifier and matches
    # the here-doc pattern → write.
    # (#692 note: a quoted "git commit" probe is no longer reliable here —
    #  general stripQuotedArgs now removes git verbs from quoted args, so
    #  known and unknown paths look identical at that layer.)
    local probe_unknown_tmp
    probe_unknown_tmp=$(printf 'bash /tmp/issue-create-dispatch.sh --body "$(cat <<EOF\ngit commit\nEOF\n)"')
    assert_classify "bash /tmp/issue-create-dispatch.sh (unknown path) heredoc body stays visible → write" \
        "$probe_unknown_tmp" "write"
    local probe_unknown_rel
    probe_unknown_rel=$(printf 'bash ./fake-issue-create.sh --body "$(cat <<EOF\ngit commit\nEOF\n)"')
    assert_classify "bash ./fake-issue-create.sh (unknown path) heredoc body stays visible → write" \
        "$probe_unknown_rel" "write"
}

# ============ #692: git-verb quoted-args false positive (Bug B) ============
# grep / rg / cat / echo with quoted git verbs (e.g. `grep -n "git push" file`)
# must NOT be misclassified as write. Achieved by adding "git" to STRIP_KINDS
# so kind:"git" patterns scan the stripped (quote-removed) command.
test_git_kind_strips_quoted_args() {
    # Read cases — git verbs inside quoted args
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

    # Write cases — real git invocations remain classified as write
    assert_classify "real git commit -m" \
        'git commit -m "test"' "write"
    assert_classify "real git push origin main" \
        'git push origin main' "write"
    assert_classify "real git checkout -- file" \
        'git checkout -- file.txt' "write"
    assert_classify "real git stash push" \
        'git stash push -m "wip"' "write"
    assert_classify "real git -C path commit" \
        'git -C /path commit -m x' "write"
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

# ============ posix-redir kind: quoted >/>>/tee must not false-positive (#460) ============

test_quoted_arg_no_false_positive_posix_redir() {
    assert_classify 'grep -nE "pattern > match" file.txt (#460 repro)' \
        'grep -nE "pattern > match" file.txt' "read"
    assert_classify 'doc-append --subject "x > y"' \
        'doc-append --subject "x > y"' "read"
    assert_classify 'doc-append --subject "echo a >> b"' \
        'doc-append --subject "echo a >> b"' "read"
    assert_classify 'gh issue comment quoted > in body' \
        'gh issue comment 369 --body "use > to redirect"' "read"
    assert_classify "echo 'a > b' (single-quoted redirect char)" \
        "echo 'a > b'" "read"
    assert_classify 'doc-append --subject "tee output"' \
        'doc-append --subject "tee output"' "read"
    assert_classify 'echo "tee file"' \
        'echo "tee file"' "read"
}

# Regression guard: real unquoted redirects and tee must remain "write" after fix.

test_unquoted_redirect_and_tee_still_write() {
    assert_classify "echo hi > out.txt" 'echo hi > out.txt' "write"
    assert_classify "echo hi >> out.txt" 'echo hi >> out.txt' "write"
    assert_classify "echo hi | tee out.txt" 'echo hi | tee out.txt' "write"
    assert_classify "tee out.txt" 'tee out.txt' "write"
    assert_classify "cmd 2>&1 (FD-to-FD, null-sink form not applicable)" 'cmd 2>&1' "read"
    assert_classify "cmd 2>/dev/null" 'cmd 2>/dev/null' "read"
    assert_classify "cmd 2>/dev/null | grep x" 'cmd 2>/dev/null | grep x' "read"
}

# /dev/null inside $(...) command substitution must not be classified as write (#359).

test_devnull_inside_command_substitution() {
    assert_classify 'echo $(grep x file 2>/dev/null)' \
        'echo $(grep x file 2>/dev/null)' "read"
    assert_classify 'echo $(grep x file >/dev/null)' \
        'echo $(grep x file >/dev/null)' "read"
    assert_classify 'echo $(echo x > out.txt) (real redirect inside $() stays write)' \
        'echo $(echo x > out.txt)' "write"
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
test_gh_group_a_heredoc_body_with_write_pattern_is_read
test_gh_group_a_inline_body_stripping
test_git_kind_strips_quoted_args
test_git_update_ref_write
test_git_commit_subcommand_position
test_quoted_arg_no_false_positive_file_op
test_interpreter_c_always_write
test_cosmetic_quote_file_op_documented_fn
test_heredoc_still_classified_after_strip
test_quoted_arg_no_false_positive_posix_redir
test_unquoted_redirect_and_tee_still_write
test_devnull_inside_command_substitution

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
