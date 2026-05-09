#!/bin/bash
# tests/fix-enforce-worktree-bundle-a.sh
#
# Integration tests for hooks/enforce-worktree.js — Bug 1 (EXCLUDE in PreToolUse)
# and Bug 2 (session-scope check for Edit/Write/MultiEdit + Bash file targets).
#
# Bug 1: ENFORCE_WORKTREE_EXCLUDE was not honoured in the PreToolUse hook,
#        so files matching the EXCLUDE glob were blocked at the hook level
#        even though pre-commit allowed them.
# Bug 2: Edit/Write/MultiEdit + Bash branches lacked a session-scope check,
#        so writes to non-session repos (e.g., ~/.claude/projects/.../*.md)
#        were blocked even though they're outside the session scope.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'bundle-a-int-'+process.pid).replace(/\\\\/g,'/');
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

require_guard() {
    if [ ! -f "$GUARD_JS" ]; then
        fail "$1 (enforce-worktree.js not present)"
        return 1
    fi
    return 0
}

# Returns 0 if allow, 1 if block.
guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# Convert path to Node-friendly form.
norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    norm_path "$repo"
}

# Returns "<main_repo>|<wt_path>" (both norm_path-converted).
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    wt="$(norm_path "$wt")"
    echo "$main|$wt"
}

# Run guard for a Bash command.
# Args: cmd cwd [env-VAR=val ...]
run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Run guard for an Edit tool call.
# Args: file_path cwd [env-VAR=val ...]
run_edit_guard() {
    local fp="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Edit',
                  tool_input:{ file_path: process.argv[1], old_string:'x', new_string:'y' } };
      console.log(JSON.stringify(j));
    " -- "$fp" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Run guard for a Write tool call.
run_write_guard() {
    local fp="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Write',
                  tool_input:{ file_path: process.argv[1], content:'x' } };
      console.log(JSON.stringify(j));
    " -- "$fp" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Run guard for a MultiEdit tool call.
# Args: edits_json cwd [env-VAR=val ...]
# edits_json is a JSON-formatted array of edit objects (each with file_path,
# old_string, new_string). Pass as a single string.
run_multiedit_guard() {
    local edits_json="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const edits = JSON.parse(process.argv[1]);
      const j = { session_id:'test', tool_name:'MultiEdit',
                  tool_input:{ file_path: edits[0] && edits[0].file_path || '', edits } };
      console.log(JSON.stringify(j));
    " -- "$edits_json" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Bug 2: session-scope check for Edit/Write/MultiEdit + Bash file targets
# ─────────────────────────────────────────────────────────────────────────────

test_bug2_edit_non_session_repo_allows() {
    require_guard "test_bug2_edit_non_session_repo_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-edit-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-edit-non-sess")"
    local out; out="$(run_edit_guard "$non_sess/README.md" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Edit on non-session repo file allows"
    else
        fail "Bug 2: Edit on non-session repo file should allow ($out)"
    fi
}

test_bug2_edit_non_repo_path_allows() {
    require_guard "test_bug2_edit_non_repo_path_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-edit-non-repo-sess")"
    local plain="$TMPDIR_BASE/plain-file.txt"
    echo "x" > "$plain"
    plain="$(norm_path "$plain")"
    local out; out="$(run_edit_guard "$plain" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Edit on non-repo path allows"
    else
        fail "Bug 2: Edit on non-repo path should allow ($out)"
    fi
}

test_bug2_multiedit_all_non_session_allows() {
    require_guard "test_bug2_multiedit_all_non_session_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-me-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-me-non-sess")"
    local edits
    edits="$(node -e "
      const a = process.argv[1];
      console.log(JSON.stringify([
        { file_path: a + '/a.md', old_string: 'a', new_string: 'b' },
        { file_path: a + '/b.md', old_string: 'a', new_string: 'b' },
      ]));
    " -- "$non_sess" 2>/dev/null)"
    local out; out="$(run_multiedit_guard "$edits" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: MultiEdit all-non-session edits allow"
    else
        fail "Bug 2: MultiEdit all-non-session edits should allow ($out)"
    fi
}

test_bug2_bash_redirect_non_session_allows() {
    # Critical Codex case: redirect target is in non-session repo, cwd is in
    # session repo. Without the fix, findRepoRootForBash returns the cwd repo
    # (in-session main checkout) and the write is blocked. With the fix, the
    # extracted redirect target is checked against session scope and the
    # non-session target allows.
    require_guard "test_bug2_bash_redirect_non_session_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-rdr-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-rdr-non-sess")"
    local cmd="echo x > $non_sess/README.md"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Bash redirect to non-session file allows"
    else
        fail "Bug 2: Bash redirect to non-session file should allow ($out)"
    fi
}

test_bug2_bash_tee_non_session_allows() {
    require_guard "test_bug2_bash_tee_non_session_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-tee-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-tee-non-sess")"
    local cmd="cmd | tee $non_sess/README.md"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Bash tee to non-session file allows"
    else
        fail "Bug 2: Bash tee to non-session file should allow ($out)"
    fi
}

test_bug2_bash_pwsh_non_session_allows() {
    require_guard "test_bug2_bash_pwsh_non_session_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-pwsh-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-pwsh-non-sess")"
    local cmd="Set-Content -Path $non_sess/README.md -Value x"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Bash Set-Content on non-session file allows"
    else
        fail "Bug 2: Bash Set-Content on non-session file should allow ($out)"
    fi
}

test_bug2_bash_redirect_non_repo_path_allows() {
    require_guard "test_bug2_bash_redirect_non_repo_path_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-rdr-non-repo-sess")"
    local target="$TMPDIR_BASE/plain.txt"
    target="$(norm_path "$target")"
    local cmd="echo x > $target"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Bash redirect to non-repo path allows"
    else
        fail "Bug 2: Bash redirect to non-repo path should allow ($out)"
    fi
}

test_bug2_bash_redirect_mixed_blocks() {
    # Invariant: if ANY target is in-session main checkout, block.
    # Use stdout=in-session, stderr=non-session redirect — both are extracted.
    require_guard "test_bug2_bash_redirect_mixed_blocks" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-mix-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-mix-non-sess")"
    local cmd="cat $in_sess/README.md > $in_sess/out.md 2>> $non_sess/log.md"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Bug 2: Bash mixed redirects (in-session present) should block ($out)"
    else
        pass "Bug 2: Bash mixed redirects with in-session target blocks"
    fi
}

test_bug2_bash_git_c_non_session_allows() {
    # `git -C <non-session> commit -m x` — the parsed -C target is non-session,
    # so the write is outside session scope and must allow.
    require_guard "test_bug2_bash_git_c_non_session_allows" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-gitc-in-sess")"
    local non_sess; non_sess="$(setup_main_checkout "B2-gitc-non-sess")"
    local cmd="git -C $non_sess commit -m x"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Bug 2: Bash git -C non-session commit allows"
    else
        fail "Bug 2: Bash git -C non-session commit should allow ($out)"
    fi
}

test_bug2_regression_edit_in_session_main_blocks() {
    # Regression: main checkout writes are still blocked even with session-scope.
    require_guard "test_bug2_regression_edit_in_session_main_blocks" || return
    local in_sess; in_sess="$(setup_main_checkout "B2-reg-in-sess")"
    local out; out="$(run_edit_guard "$in_sess/README.md" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Regression: Edit on in-session main checkout should block ($out)"
    else
        pass "Regression: Edit on in-session main checkout blocks"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Bug 1: ENFORCE_WORKTREE_EXCLUDE honoured in PreToolUse
# ─────────────────────────────────────────────────────────────────────────────

test_bug1_edit_exclude_allows() {
    require_guard "test_bug1_edit_exclude_allows" || return
    local repo; repo="$(setup_main_checkout "B1-edit-excl")"
    local out; out="$(run_edit_guard "$repo/.env.local" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        pass "Bug 1: Edit excluded file (.env.local) allows"
    else
        fail "Bug 1: Edit excluded file should allow ($out)"
    fi
}

test_bug1_edit_exclude_mismatch_blocks() {
    require_guard "test_bug1_edit_exclude_mismatch_blocks" || return
    local repo; repo="$(setup_main_checkout "B1-edit-mis")"
    local out; out="$(run_edit_guard "$repo/secret.md" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        fail "Bug 1: Edit non-excluded file should block ($out)"
    else
        pass "Bug 1: Edit non-excluded file blocks"
    fi
}

test_bug1_write_exclude_allows() {
    require_guard "test_bug1_write_exclude_allows" || return
    local repo; repo="$(setup_main_checkout "B1-write-excl")"
    local out; out="$(run_write_guard "$repo/.env.local" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        pass "Bug 1: Write excluded file allows"
    else
        fail "Bug 1: Write excluded file should allow ($out)"
    fi
}

test_bug1_multiedit_all_excluded_allows() {
    require_guard "test_bug1_multiedit_all_excluded_allows" || return
    local repo; repo="$(setup_main_checkout "B1-me-all-excl")"
    local edits
    edits="$(node -e "
      const a = process.argv[1];
      console.log(JSON.stringify([
        { file_path: a + '/a.local', old_string: 'a', new_string: 'b' },
        { file_path: a + '/b.local', old_string: 'a', new_string: 'b' },
      ]));
    " -- "$repo" 2>/dev/null)"
    local out; out="$(run_multiedit_guard "$edits" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.local")"
    if guard_decision "$out"; then
        pass "Bug 1: MultiEdit all excluded files allows"
    else
        fail "Bug 1: MultiEdit all excluded files should allow ($out)"
    fi
}

test_bug1_multiedit_partial_exclude_blocks() {
    require_guard "test_bug1_multiedit_partial_exclude_blocks" || return
    local repo; repo="$(setup_main_checkout "B1-me-part-excl")"
    local edits
    edits="$(node -e "
      const a = process.argv[1];
      console.log(JSON.stringify([
        { file_path: a + '/a.local', old_string: 'a', new_string: 'b' },
        { file_path: a + '/normal.md', old_string: 'a', new_string: 'b' },
      ]));
    " -- "$repo" 2>/dev/null)"
    local out; out="$(run_multiedit_guard "$edits" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.local")"
    if guard_decision "$out"; then
        fail "Bug 1: MultiEdit partial-excluded should block ($out)"
    else
        pass "Bug 1: MultiEdit partial-excluded (one non-excluded file) blocks"
    fi
}

test_bug1_bash_redirect_exclude_allows() {
    require_guard "test_bug1_bash_redirect_exclude_allows" || return
    local repo; repo="$(setup_main_checkout "B1-rdr-excl")"
    local cmd="echo x > $repo/.env.local"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        pass "Bug 1: Bash redirect to excluded file allows"
    else
        fail "Bug 1: Bash redirect to excluded file should allow ($out)"
    fi
}

test_bug1_bash_redirect_exclude_mismatch_blocks() {
    require_guard "test_bug1_bash_redirect_exclude_mismatch_blocks" || return
    local repo; repo="$(setup_main_checkout "B1-rdr-mis")"
    local cmd="echo x > $repo/secret.md"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        fail "Bug 1: Bash redirect non-excluded should block ($out)"
    else
        pass "Bug 1: Bash redirect non-excluded blocks"
    fi
}

test_bug1_bash_tee_exclude_allows() {
    require_guard "test_bug1_bash_tee_exclude_allows" || return
    local repo; repo="$(setup_main_checkout "B1-tee-excl")"
    local cmd="cmd | tee $repo/.env.local"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        pass "Bug 1: Bash tee to excluded file allows"
    else
        fail "Bug 1: Bash tee to excluded file should allow ($out)"
    fi
}

test_bug1_bash_pwsh_exclude_allows() {
    require_guard "test_bug1_bash_pwsh_exclude_allows" || return
    local repo; repo="$(setup_main_checkout "B1-pwsh-excl")"
    local cmd="Set-Content -Path $repo/.env.local -Value x"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        pass "Bug 1: Bash Set-Content on excluded file allows"
    else
        fail "Bug 1: Bash Set-Content on excluded file should allow ($out)"
    fi
}

test_bug1_bash_git_commit_all_staged_excluded_allows() {
    require_guard "test_bug1_bash_git_commit_all_staged_excluded_allows" || return
    local repo; repo="$(setup_main_checkout "B1-commit-all-excl")"
    # Stage a single file matching the exclude.
    echo "content" > "$repo/.env.local"
    git -C "$repo" add .env.local
    local cmd="git commit -m x"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        pass "Bug 1: git commit with all staged files excluded allows"
    else
        fail "Bug 1: git commit with all staged excluded should allow ($out)"
    fi
}

test_bug1_bash_git_commit_partial_staged_blocks() {
    require_guard "test_bug1_bash_git_commit_partial_staged_blocks" || return
    local repo; repo="$(setup_main_checkout "B1-commit-part")"
    echo "x" > "$repo/.env.local"
    echo "y" > "$repo/normal.md"
    git -C "$repo" add .env.local normal.md
    local cmd="git commit -m x"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=.env.local")"
    if guard_decision "$out"; then
        fail "Bug 1: git commit with partial-excluded staged should block ($out)"
    else
        pass "Bug 1: git commit with partial-excluded staged blocks"
    fi
}

test_bug1_bash_unsupported_write_failclosed() {
    # No file targets extractable from `npm install` → fail-closed (block).
    require_guard "test_bug1_bash_unsupported_write_failclosed" || return
    local repo; repo="$(setup_main_checkout "B1-unsup-fc")"
    local cmd="npm install"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=node_modules/**")"
    if guard_decision "$out"; then
        fail "Bug 1: unsupported write should fail-closed ($out)"
    else
        pass "Bug 1: unsupported write fails-closed (block)"
    fi
}

test_bug1_bash_parse_failure_failclosed() {
    require_guard "test_bug1_bash_parse_failure_failclosed" || return
    local repo; repo="$(setup_main_checkout "B1-parsef-fc")"
    # Single-quoted to keep $VAR literal in the command string.
    local cmd='echo x > $VAR'
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.md")"
    if guard_decision "$out"; then
        fail "Bug 1: parse-failure write should fail-closed ($out)"
    else
        pass "Bug 1: parse-failure (\$VAR) fails-closed (block)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Regression: EXCLUDE unset → main-checkout writes still blocked
# ─────────────────────────────────────────────────────────────────────────────

test_regression_exclude_unset_blocks_main() {
    require_guard "test_regression_exclude_unset_blocks_main" || return
    local repo; repo="$(setup_main_checkout "REG-no-excl")"
    local out; out="$(run_edit_guard "$repo/README.md" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Regression: Edit on main checkout (no EXCLUDE) should block ($out)"
    else
        pass "Regression: Edit on main checkout (no EXCLUDE) blocks"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Security
# ─────────────────────────────────────────────────────────────────────────────

test_security_exclude_metacharacters() {
    # Shell metacharacters in EXCLUDE must not execute. The hook should
    # complete cleanly (allow or block) without crashing.
    require_guard "test_security_exclude_metacharacters" || return
    local repo; repo="$(setup_main_checkout "SEC-meta")"
    local sentinel="$TMPDIR_BASE/sec-meta-sentinel-$$"
    rm -rf "$sentinel" 2>/dev/null
    local payload="; mkdir $sentinel"
    local out; out="$(run_edit_guard "$repo/README.md" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=$payload")"
    if [ -d "$sentinel" ] || [ -e "$sentinel" ]; then
        fail "SECURITY: EXCLUDE metachar executed shell"
        rm -rf "$sentinel" 2>/dev/null
    else
        pass "SECURITY: EXCLUDE metachar not executed"
    fi
    # Output should be well-formed JSON (allow or block).
    if echo "$out" | grep -qE '^\{.*\}$'; then
        pass "SECURITY: EXCLUDE metachar produces well-formed output"
    else
        fail "SECURITY: EXCLUDE metachar produced malformed output ($out)"
    fi
}

test_security_staged_filename_injection() {
    # Tricky staged filename containing a `;` — must not crash, and since
    # the literal name doesn't match EXCLUDE, the commit is blocked.
    require_guard "test_security_staged_filename_injection" || return
    local repo; repo="$(setup_main_checkout "SEC-staged")"
    # Create a benign-but-tricky filename. Avoid path separators.
    local tricky="trick;name.md"
    echo "data" > "$repo/$tricky"
    git -C "$repo" add "$tricky"
    local cmd="git commit -m x"
    local out; out="$(run_bash_guard "$cmd" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.local")"
    # Output should be JSON; the staged file does not match exclude so it should block.
    if guard_decision "$out"; then
        fail "SECURITY: staged tricky-name without exclude match should block ($out)"
    else
        pass "SECURITY: staged tricky-name without exclude match blocks (no crash)"
    fi
}

test_security_compound_command_sequencing() {
    require_guard "test_security_compound_command_sequencing" || return

    # Test 1: Semicolon compound command blocks
    local in_sess; in_sess="$(setup_main_checkout "SEC-comp-semi")"
    local non_sess; non_sess="$(setup_main_checkout "SEC-comp-semi-ns")"
    local cmd="echo x > $non_sess/README.md; rm $in_sess/README.md"
    local out; out="$(run_bash_guard "$cmd" "$in_sess" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "SECURITY: compound ';' cmd should block to prevent rm side-effect ($out)"
    else
        pass "SECURITY: compound ';' cmd with non-session redirect blocks"
    fi

    # Test 2: && compound command blocks
    local in_sess2; in_sess2="$(setup_main_checkout "SEC-comp-and")"
    local non_sess2; non_sess2="$(setup_main_checkout "SEC-comp-and-ns")"
    local cmd2="echo x > $non_sess2/README.md && rm $in_sess2/README.md"
    local out2; out2="$(run_bash_guard "$cmd2" "$in_sess2" ENFORCE_WORKTREE=on)"
    if guard_decision "$out2"; then
        fail "SECURITY: compound '&&' cmd should block to prevent rm side-effect ($out2)"
    else
        pass "SECURITY: compound '&&' cmd with non-session redirect blocks"
    fi

    # Test 3: Simple (non-compound) redirect to non-session still allows
    local in_sess3; in_sess3="$(setup_main_checkout "SEC-comp-simple")"
    local non_sess3; non_sess3="$(setup_main_checkout "SEC-comp-simple-ns")"
    local cmd3="echo x > $non_sess3/README.md"
    local out3; out3="$(run_bash_guard "$cmd3" "$in_sess3" ENFORCE_WORKTREE=on)"
    if guard_decision "$out3"; then
        pass "SECURITY: simple redirect to non-session still allows"
    else
        fail "SECURITY: simple redirect should still allow after compound fix ($out3)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency
# ─────────────────────────────────────────────────────────────────────────────

test_idempotency() {
    require_guard "test_idempotency" || return
    local repo; repo="$(setup_main_checkout "IDEM")"
    local a b
    a="$(run_edit_guard "$repo/README.md" "$repo" ENFORCE_WORKTREE=on)"
    b="$(run_edit_guard "$repo/README.md" "$repo" ENFORCE_WORKTREE=on)"
    if [ "$a" = "$b" ]; then
        pass "Edit guard is idempotent"
    else
        fail "Edit guard not idempotent (a=$a b=$b)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

# Bug 2
test_bug2_edit_non_session_repo_allows
test_bug2_edit_non_repo_path_allows
test_bug2_multiedit_all_non_session_allows
test_bug2_bash_redirect_non_session_allows
test_bug2_bash_tee_non_session_allows
test_bug2_bash_pwsh_non_session_allows
test_bug2_bash_redirect_non_repo_path_allows
test_bug2_bash_redirect_mixed_blocks
test_bug2_bash_git_c_non_session_allows
test_bug2_regression_edit_in_session_main_blocks

# Bug 1
test_bug1_edit_exclude_allows
test_bug1_edit_exclude_mismatch_blocks
test_bug1_write_exclude_allows
test_bug1_multiedit_all_excluded_allows
test_bug1_multiedit_partial_exclude_blocks
test_bug1_bash_redirect_exclude_allows
test_bug1_bash_redirect_exclude_mismatch_blocks
test_bug1_bash_tee_exclude_allows
test_bug1_bash_pwsh_exclude_allows
test_bug1_bash_git_commit_all_staged_excluded_allows
test_bug1_bash_git_commit_partial_staged_blocks
test_bug1_bash_unsupported_write_failclosed
test_bug1_bash_parse_failure_failclosed

# Regression
test_regression_exclude_unset_blocks_main

# Security
test_security_exclude_metacharacters
test_security_staged_filename_injection
test_security_compound_command_sequencing

# Idempotency
test_idempotency

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
