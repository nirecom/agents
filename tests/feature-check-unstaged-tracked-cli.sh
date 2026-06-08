#!/bin/bash
# tests/feature-check-unstaged-tracked-cli.sh
# Tests: bin/check-unstaged-tracked.sh, hooks/workflow-gate/staged-evidence.js
# Tags: cli, bin, unstaged-tracked, gate2, git
#
# E2E tests for bin/check-unstaged-tracked.sh.
# Expected red until #269 lands the CLI.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_SH="${AGENTS_DIR}/bin/check-unstaged-tracked.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'cliunstaged-'+process.pid).replace(/\\\\/g,'/');
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
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_cli() {
    if [ ! -f "$CLI_SH" ]; then
        fail "$1 (bin/check-unstaged-tracked.sh not present)"
        return 1
    fi
    return 0
}

# Build a repo with an initial commit; echo raw path (suitable for cd).
init_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/seed.txt"
    git -C "$repo" add seed.txt
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Run the CLI with separated stdout / stderr / rc capture.
CLI_STDOUT=""
CLI_STDERR=""
CLI_RC=0
run_cli() {
    local stdout_file="$TMPDIR_BASE/cli.out.$RANDOM"
    local stderr_file="$TMPDIR_BASE/cli.err.$RANDOM"
    CLI_RC=0
    AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 bash "$CLI_SH" "$@" \
        >"$stdout_file" 2>"$stderr_file" || CLI_RC=$?
    CLI_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    CLI_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

# ============================================================================
# Tests
# ============================================================================

# 1. clean repo, explicit arg → exit 0, stdout empty
test_1_clean_explicit_arg() {
    require_cli "1" || return
    local repo; repo="$(init_repo "clean1")"
    run_cli "$repo"
    if [ "$CLI_RC" -ne 0 ]; then
        fail "1: clean+explicit → expected exit 0, got $CLI_RC" "stderr: $CLI_STDERR"
        return
    fi
    if [ -z "$CLI_STDOUT" ]; then
        pass "1: clean repo + explicit arg → exit 0, stdout empty"
    else
        fail "1: clean repo → expected empty stdout" "stdout: $CLI_STDOUT"
    fi
}

# 2. dirty single file → exit 1, stdout contains the file (exactly one line)
test_2_dirty_single() {
    require_cli "2" || return
    local repo; repo="$(init_repo "dirty1")"
    echo "src" > "$repo/app.js"
    git -C "$repo" add app.js
    git -C "$repo" commit -q -m "add app.js"
    echo "edit" >> "$repo/app.js"
    run_cli "$repo"
    if [ "$CLI_RC" -ne 1 ]; then
        fail "2: dirty single → expected exit 1, got $CLI_RC" "stdout: $CLI_STDOUT  stderr: $CLI_STDERR"
        return
    fi
    local line_count
    line_count="$(printf '%s\n' "$CLI_STDOUT" | grep -c .)"
    if [ "$line_count" -ne 1 ]; then
        fail "2: dirty single → expected exactly 1 stdout line, got $line_count" "stdout: $CLI_STDOUT"
        return
    fi
    if ! echo "$CLI_STDOUT" | grep -q 'app.js'; then
        fail "2: dirty single → stdout should contain 'app.js'" "stdout: $CLI_STDOUT"
        return
    fi
    pass "2: dirty single file → exit 1, stdout has 1 line containing 'app.js'"
}

# 3. dirty 3 files → exit 1, stdout has 3 lines containing each file
test_3_dirty_three() {
    require_cli "3" || return
    local repo; repo="$(init_repo "dirty3")"
    echo "a" > "$repo/a.js"
    echo "b" > "$repo/b.js"
    echo "c" > "$repo/c.js"
    git -C "$repo" add a.js b.js c.js
    git -C "$repo" commit -q -m "add abc"
    echo "1" >> "$repo/a.js"
    echo "2" >> "$repo/b.js"
    echo "3" >> "$repo/c.js"
    run_cli "$repo"
    if [ "$CLI_RC" -ne 1 ]; then
        fail "3: dirty 3 → expected exit 1, got $CLI_RC" "stdout: $CLI_STDOUT  stderr: $CLI_STDERR"
        return
    fi
    local actual expected
    actual="$(printf '%s\n' "$CLI_STDOUT" | sed '/^$/d' | sort)"
    expected="$(printf '%s\n' "a.js" "b.js" "c.js" | sort)"
    if [ "$actual" = "$expected" ]; then
        pass "3: dirty 3 files → exit 1, stdout enumerates a.js/b.js/c.js"
    else
        fail "3: dirty 3 → stdout mismatch" "actual: $actual  expected: $expected"
    fi
}

# 4. default cwd: with no arg, CLI uses $PWD
test_4_default_cwd_via_pwd() {
    require_cli "4" || return
    local repo_clean; repo_clean="$(init_repo "pwdclean")"
    local repo_dirty; repo_dirty="$(init_repo "pwddirty")"
    echo "src" > "$repo_dirty/app.js"
    git -C "$repo_dirty" add app.js
    git -C "$repo_dirty" commit -q -m "add app.js"
    echo "edit" >> "$repo_dirty/app.js"

    local stdout_file stderr_file rc
    rc=0
    stdout_file="$TMPDIR_BASE/pwdclean.out"; stderr_file="$TMPDIR_BASE/pwdclean.err"
    (cd "$repo_clean" && AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 bash "$CLI_SH") >"$stdout_file" 2>"$stderr_file" || rc=$?
    if [ "$rc" -ne 0 ] || [ -n "$(cat "$stdout_file")" ]; then
        fail "4a: default cwd clean → expected exit 0 + empty stdout" "rc=$rc stdout=$(cat "$stdout_file") stderr=$(cat "$stderr_file")"
        return
    fi

    rc=0
    stdout_file="$TMPDIR_BASE/pwddirty.out"; stderr_file="$TMPDIR_BASE/pwddirty.err"
    (cd "$repo_dirty" && AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 bash "$CLI_SH") >"$stdout_file" 2>"$stderr_file" || rc=$?
    if [ "$rc" -ne 1 ]; then
        fail "4b: default cwd dirty → expected exit 1" "rc=$rc stdout=$(cat "$stdout_file") stderr=$(cat "$stderr_file")"
        return
    fi
    if ! grep -q 'app.js' "$stdout_file"; then
        fail "4b: default cwd dirty → expected stdout to mention app.js" "$(cat "$stdout_file")"
        return
    fi
    pass "4: default cwd → exit 0 in clean, exit 1 + filename in dirty"
}

# 5. usage error: 2 positional args → exit 2, stderr matches Usage:
test_5_usage_error_two_args() {
    require_cli "5" || return
    local repo; repo="$(init_repo "usage")"
    run_cli "$repo" "extra-arg"
    if [ "$CLI_RC" -ne 2 ]; then
        fail "5: 2 args → expected exit 2, got $CLI_RC" "stdout: $CLI_STDOUT  stderr: $CLI_STDERR"
        return
    fi
    if echo "$CLI_STDERR" | grep -q '^Usage:'; then
        pass "5: usage error (2 args) → exit 2, stderr matches Usage:"
    else
        fail "5: usage error → stderr should start with 'Usage:'" "$CLI_STDERR"
    fi
}

# 6. non-git directory → exit 3, stderr non-empty
test_6_non_git_dir() {
    require_cli "6" || return
    local d="$TMPDIR_BASE/not-a-repo"
    mkdir -p "$d"
    run_cli "$d"
    if [ "$CLI_RC" -ne 3 ]; then
        fail "6: non-git dir → expected exit 3, got $CLI_RC" "stdout: $CLI_STDOUT  stderr: $CLI_STDERR"
        return
    fi
    if [ -n "$CLI_STDERR" ]; then
        pass "6: non-git dir → exit 3 + non-empty stderr"
    else
        fail "6: non-git dir → expected non-empty stderr" "stderr was empty"
    fi
}

run_all() {
    test_1_clean_explicit_arg
    test_2_dirty_single
    test_3_dirty_three
    test_4_default_cwd_via_pwd
    test_5_usage_error_two_args
    test_6_non_git_dir
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_CLI_UNSTAGED_INNER:-}" ]; then
        _CLI_UNSTAGED_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
