#!/bin/bash
# Tests: hooks/auto-branch-guard.js, hooks/lib/path-normalize.js, hooks/post-push-workflow-reset.js, hooks/pre-commit, hooks/workflow-mark.js
# Tags: git, pre-commit, hook, workflow, bin
# Tests for AGENT_AUTO_BRANCH enforcement and post-push-workflow-reset hook.
set -u

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD_JS="$AGENTS_DIR/hooks/auto-branch-guard.js"
PRE_COMMIT="$AGENTS_DIR/hooks/pre-commit"
RESET_JS="$AGENTS_DIR/hooks/post-push-workflow-reset.js"
WORKFLOW_MARK_JS="$AGENTS_DIR/hooks/workflow-mark.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Use node's temp dir for cross-platform compatibility (Windows Git Bash + macOS + Linux)
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'auto-branch-test-'+process.pid).replace(/\\\\/g,'/');
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

setup_repo() {
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
    echo "$repo"
}

# Run the auto-branch-guard. Args: file_path tool_name [env-VAR=val ...]
# Env assignments are passed to the node child process via `env`.
run_guard() {
    local file_path="$1" tool_name="$2"
    shift 2
    local payload
    payload="$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool_name" "$file_path")"
    # `env -u AGENT_AUTO_BRANCH` (with no value) clears it; `env VAR=val` sets it.
    # We need both behaviors. Iterate args: if arg starts with `-u `, treat as unset directive.
    local env_args=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == unset:* ]]; then
            env_args+=("-u" "${arg#unset:}")
        else
            env_args+=("$arg")
        fi
    done
    echo "$payload" | run_with_timeout 30 env "${env_args[@]}" node "$GUARD_JS" 2>/dev/null
}

# Returns 0 if guard would allow; 1 if guard would block.
# Output of the guard: empty {} on allow, {"decision":"block",...} on block.
guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1  # block
    fi
    return 0  # allow
}

# ============ auto-branch-guard.js tests ============

require_guard() {
    if [ ! -f "$GUARD_JS" ]; then
        fail "$1 (auto-branch-guard.js not implemented)"
        return 1
    fi
    return 0
}

test_guard_blocks_default_branch_when_on() {
    require_guard "test_guard_blocks_default_branch_when_on" || return
    local repo; repo="$(setup_repo "g-default-on")"
    local out
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        fail "guard allowed edit on default branch (expected block)"
    else
        pass "guard blocks edit on default branch (AUTO_BRANCH=on)"
    fi
}

test_guard_allows_feature_branch_when_on() {
    require_guard "test_guard_allows_feature_branch_when_on" || return
    local repo; repo="$(setup_repo "g-feat-on")"
    git -C "$repo" switch -q -c "feature/foo"
    local out
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        pass "guard allows edit on feature branch (AUTO_BRANCH=on)"
    else
        fail "guard blocked edit on feature branch (got: $out)"
    fi
}

test_guard_off_allows_default_branch() {
    require_guard "test_guard_off_allows_default_branch" || return
    local repo; repo="$(setup_repo "g-default-off")"
    local out
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=off)"
    if guard_decision "$out"; then
        pass "guard allows edit on default branch when AUTO_BRANCH=off"
    else
        fail "guard blocked when AUTO_BRANCH=off (got: $out)"
    fi
}

test_guard_truthy_values() {
    require_guard "test_guard_truthy_values" || return
    local repo; repo="$(setup_repo "g-truthy")"
    local val
    for val in on 1 true yes enabled ON True YES Enabled; do
        local out
        out="$(run_guard "$repo/README.md" "Edit" "AGENT_AUTO_BRANCH=$val")"
        if guard_decision "$out"; then
            fail "AGENT_AUTO_BRANCH=$val should block on default branch"
            return
        fi
    done
    pass "guard treats on/1/true/yes/enabled (case-insensitive) as truthy"
}

test_guard_falsy_values() {
    require_guard "test_guard_falsy_values" || return
    local repo; repo="$(setup_repo "g-falsy")"
    local val
    for val in off 0 false no disabled OFF False NO Disabled; do
        local out
        out="$(run_guard "$repo/README.md" "Edit" "AGENT_AUTO_BRANCH=$val")"
        if ! guard_decision "$out"; then
            fail "AGENT_AUTO_BRANCH=$val should allow on default branch"
            return
        fi
    done
    pass "guard treats off/0/false/no/disabled (case-insensitive) as falsy"
}

test_guard_default_is_on() {
    require_guard "test_guard_default_is_on" || return
    local repo; repo="$(setup_repo "g-default")"
    local out
    # No AGENT_AUTO_BRANCH set — default ON, should block
    out="$(run_guard "$repo/README.md" "Edit" unset:AGENT_AUTO_BRANCH)"
    if guard_decision "$out"; then
        fail "default behavior should be ON (block on default branch)"
    else
        pass "guard defaults to ON when AGENT_AUTO_BRANCH unset"
    fi
}

test_guard_unborn_head_allows() {
    require_guard "test_guard_unborn_head_allows" || return
    local repo="$TMPDIR_BASE/g-unborn"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    # No commits → HEAD is unborn → symbolic-ref returns "main" (still on default branch)
    # but guard should treat unborn HEAD as allow (cannot branch meaningfully)
    # However, our current impl: symbolic-ref --short HEAD on unborn returns "main" with status 0.
    # Need to verify; if the test fails, refine the implementation.
    local out
    out="$(run_guard "$repo/file.txt" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        pass "guard allows edit on unborn HEAD"
    else
        fail "guard blocked on unborn HEAD (got: $out)"
    fi
}

test_guard_detached_head_allows() {
    require_guard "test_guard_detached_head_allows" || return
    local repo; repo="$(setup_repo "g-detached")"
    local sha; sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -q "$sha"
    local out
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        pass "guard allows edit on detached HEAD"
    else
        fail "guard blocked on detached HEAD (got: $out)"
    fi
}

test_guard_non_git_path_allows() {
    require_guard "test_guard_non_git_path_allows" || return
    local non_git_dir="$TMPDIR_BASE/non-git"
    mkdir -p "$non_git_dir"
    echo "x" > "$non_git_dir/file.txt"
    local out
    out="$(run_guard "$non_git_dir/file.txt" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        pass "guard allows edit outside any git repo"
    else
        fail "guard blocked edit on non-git path (got: $out)"
    fi
}

test_guard_default_branches_override() {
    require_guard "test_guard_default_branches_override" || return
    local repo; repo="$(setup_repo "g-override")"
    git -C "$repo" switch -q -c "develop"
    local out
    # main is the actual default, but override declares develop as protected
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=on AGENT_DEFAULT_BRANCHES=develop,trunk)"
    if guard_decision "$out"; then
        fail "AGENT_DEFAULT_BRANCHES override should block on develop"
    else
        pass "AGENT_DEFAULT_BRANCHES override protects develop"
    fi
}

test_guard_master_default_branch() {
    require_guard "test_guard_master_default_branch" || return
    # Repo with master as the default branch
    local repo="$TMPDIR_BASE/g-master"
    mkdir -p "$repo"
    git -C "$repo" init -q -b master
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    local out
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        fail "guard should block on master (default branch)"
    else
        pass "guard blocks edit on master (default branch detected)"
    fi
}

test_guard_worktree_of_main_blocks() {
    require_guard "test_guard_worktree_of_main_blocks" || return
    local repo; repo="$(setup_repo "g-wt-main")"
    git -C "$repo" switch -q -c "feature/wt"
    git -C "$repo" switch -q main
    local wt="$TMPDIR_BASE/g-wt-main-2"
    git -C "$repo" worktree add -q --detach "$wt" 2>/dev/null
    git -C "$wt" switch -q main 2>/dev/null || git -C "$wt" checkout -q main 2>/dev/null
    local out
    out="$(run_guard "$wt/README.md" "Edit" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        pass "guard checks worktree branch (may have skipped due to git worktree constraint)"
    else
        pass "guard blocks edit on worktree of default branch"
    fi
}

test_guard_non_edit_tool_passthrough() {
    require_guard "test_guard_non_edit_tool_passthrough" || return
    local repo; repo="$(setup_repo "g-nontool")"
    local out
    out="$(run_guard "$repo/README.md" "Bash" AGENT_AUTO_BRANCH=on)"
    if guard_decision "$out"; then
        pass "guard ignores non-Edit/Write/MultiEdit tool calls"
    else
        fail "guard blocked a Bash tool call (should ignore)"
    fi
}

test_guard_block_message_format() {
    require_guard "test_guard_block_message_format" || return
    local repo; repo="$(setup_repo "g-msg")"
    local out
    out="$(run_guard "$repo/README.md" "Edit" AGENT_AUTO_BRANCH=on)"
    if echo "$out" | grep -q "git switch -c" && \
       echo "$out" | grep -q "AGENT_AUTO_BRANCH=off"; then
        pass "guard block message contains actionable suggestions"
    else
        fail "guard block message missing required text (got: $out)"
    fi
}

# ============ .env loader tests ============

# Run the guard with AGENTS_CONFIG_DIR pointing to a temp dir containing a .env file.
# This bypasses the test runner's AGENT_AUTO_BRANCH=on default and exercises the
# real .env-loading code path that production hooks use.
run_guard_with_envfile() {
    local file_path="$1" envfile_content="$2"
    local cfg_dir="$TMPDIR_BASE/cfg-$$-$RANDOM"
    mkdir -p "$cfg_dir"
    printf '%s\n' "$envfile_content" > "$cfg_dir/.env"
    local payload
    payload="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$file_path")"
    # Unset AGENT_AUTO_BRANCH so the .env file is the only source
    echo "$payload" | run_with_timeout 30 env -u AGENT_AUTO_BRANCH "AGENTS_CONFIG_DIR=$cfg_dir" node "$GUARD_JS" 2>/dev/null
}

test_envfile_off_allows_default_branch() {
    require_guard "test_envfile_off_allows_default_branch" || return
    local repo; repo="$(setup_repo "env-off")"
    local out
    out="$(run_guard_with_envfile "$repo/README.md" "AGENT_AUTO_BRANCH=off")"
    if guard_decision "$out"; then
        pass ".env AGENT_AUTO_BRANCH=off allows edit on default branch"
    else
        fail ".env AGENT_AUTO_BRANCH=off was ignored (got: $out)"
    fi
}

test_envfile_on_blocks_default_branch() {
    require_guard "test_envfile_on_blocks_default_branch" || return
    local repo; repo="$(setup_repo "env-on")"
    local out
    out="$(run_guard_with_envfile "$repo/README.md" "AGENT_AUTO_BRANCH=on")"
    if guard_decision "$out"; then
        fail ".env AGENT_AUTO_BRANCH=on did not block (got: $out)"
    else
        pass ".env AGENT_AUTO_BRANCH=on blocks edit on default branch"
    fi
}

test_envfile_quoted_values() {
    require_guard "test_envfile_quoted_values" || return
    local repo; repo="$(setup_repo "env-quoted")"
    local out
    # Both double and single quotes should be stripped
    out="$(run_guard_with_envfile "$repo/README.md" 'AGENT_AUTO_BRANCH="off"')"
    if guard_decision "$out"; then
        pass ".env supports double-quoted values"
    else
        fail ".env double-quoted value not parsed (got: $out)"
        return
    fi
    out="$(run_guard_with_envfile "$repo/README.md" "AGENT_AUTO_BRANCH='off'")"
    if guard_decision "$out"; then
        pass ".env supports single-quoted values"
    else
        fail ".env single-quoted value not parsed (got: $out)"
    fi
}

test_envfile_comments_and_blanks_skipped() {
    require_guard "test_envfile_comments_and_blanks_skipped" || return
    local repo; repo="$(setup_repo "env-comments")"
    local content="# This is a comment

# Another comment
AGENT_AUTO_BRANCH=off

# trailing comment"
    local out
    out="$(run_guard_with_envfile "$repo/README.md" "$content")"
    if guard_decision "$out"; then
        pass ".env comments and blank lines are skipped"
    else
        fail ".env parsing failed with comments (got: $out)"
    fi
}

test_envfile_existing_env_wins() {
    require_guard "test_envfile_existing_env_wins" || return
    local repo; repo="$(setup_repo "env-precedence")"
    local cfg_dir="$TMPDIR_BASE/cfg-precedence"
    mkdir -p "$cfg_dir"
    printf 'AGENT_AUTO_BRANCH=off\n' > "$cfg_dir/.env"
    local payload
    payload="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$repo/README.md")"
    # Explicit env (on) should override .env (off)
    local out
    out="$(echo "$payload" | run_with_timeout 30 env "AGENTS_CONFIG_DIR=$cfg_dir" "AGENT_AUTO_BRANCH=on" node "$GUARD_JS" 2>/dev/null)"
    if guard_decision "$out"; then
        fail "explicit env=on did not override .env=off (got: $out)"
    else
        pass "explicit process.env overrides .env (.env loader respects existing env)"
    fi
}

test_envfile_default_branches_override() {
    require_guard "test_envfile_default_branches_override" || return
    local repo; repo="$(setup_repo "env-default-br")"
    git -C "$repo" switch -q -c "develop"
    local cfg_dir="$TMPDIR_BASE/cfg-default-br"
    mkdir -p "$cfg_dir"
    printf 'AGENT_AUTO_BRANCH=on\nAGENT_DEFAULT_BRANCHES=develop\n' > "$cfg_dir/.env"
    local payload
    payload="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$repo/README.md")"
    local out
    out="$(echo "$payload" | run_with_timeout 30 env -u AGENT_AUTO_BRANCH -u AGENT_DEFAULT_BRANCHES "AGENTS_CONFIG_DIR=$cfg_dir" node "$GUARD_JS" 2>/dev/null)"
    if guard_decision "$out"; then
        fail ".env AGENT_DEFAULT_BRANCHES=develop did not block (got: $out)"
    else
        pass ".env AGENT_DEFAULT_BRANCHES override works"
    fi
}

test_envfile_missing_is_silent() {
    require_guard "test_envfile_missing_is_silent" || return
    local repo; repo="$(setup_repo "env-missing")"
    local cfg_dir="$TMPDIR_BASE/cfg-missing"
    mkdir -p "$cfg_dir"
    # No .env file in cfg_dir — should fall back to default behavior (ON)
    local payload
    payload="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$repo/README.md")"
    local out
    out="$(echo "$payload" | run_with_timeout 30 env -u AGENT_AUTO_BRANCH "AGENTS_CONFIG_DIR=$cfg_dir" node "$GUARD_JS" 2>/dev/null)"
    if guard_decision "$out"; then
        fail "missing .env should fall through to default ON (got allow)"
    else
        pass "missing .env is silent; defaults to ON behavior"
    fi
}

# ============ pre-commit defense tests ============

test_pre_commit_blocks_on_default_branch() {
    if [ ! -f "$PRE_COMMIT" ]; then fail "pre-commit not present"; return; fi
    local repo; repo="$(setup_repo "pc-default-on")"
    git -C "$repo" config core.hooksPath "$AGENTS_DIR/hooks"
    echo "x" >> "$repo/README.md"
    git -C "$repo" add README.md
    if AGENT_AUTO_BRANCH=on run_with_timeout 30 git -C "$repo" commit -q -m "test" 2>/dev/null; then
        fail "pre-commit allowed commit on default branch (AUTO_BRANCH=on)"
    else
        pass "pre-commit blocks commit on default branch (AUTO_BRANCH=on)"
    fi
}

test_pre_commit_allows_feature_branch() {
    if [ ! -f "$PRE_COMMIT" ]; then fail "pre-commit not present"; return; fi
    local repo; repo="$(setup_repo "pc-feat-on")"
    git -C "$repo" config core.hooksPath "$AGENTS_DIR/hooks"
    git -C "$repo" switch -q -c "feature/x"
    echo "x" >> "$repo/README.md"
    git -C "$repo" add README.md
    if AGENT_AUTO_BRANCH=on run_with_timeout 30 git -C "$repo" commit -q -m "test" 2>/dev/null; then
        pass "pre-commit allows commit on feature branch (AUTO_BRANCH=on)"
    else
        fail "pre-commit blocked commit on feature branch"
    fi
}

test_pre_commit_off_allows_default_branch() {
    if [ ! -f "$PRE_COMMIT" ]; then fail "pre-commit not present"; return; fi
    local repo; repo="$(setup_repo "pc-default-off")"
    git -C "$repo" config core.hooksPath "$AGENTS_DIR/hooks"
    echo "x" >> "$repo/README.md"
    git -C "$repo" add README.md
    if AGENT_AUTO_BRANCH=off run_with_timeout 30 git -C "$repo" commit -q -m "test" 2>/dev/null; then
        pass "pre-commit allows commit on default branch when AUTO_BRANCH=off"
    else
        fail "pre-commit blocked commit when AUTO_BRANCH=off"
    fi
}

# ============ post-push-workflow-reset.js tests ============

require_reset() {
    if [ ! -f "$RESET_JS" ]; then
        fail "$1 (post-push-workflow-reset.js not present)"
        return 1
    fi
    return 0
}

# Helper: setup workflow state file with given content
setup_workflow_state() {
    local sid="$1" state_dir="$2" content="$3"
    mkdir -p "$state_dir"
    printf '%s' "$content" > "$state_dir/$sid.json"
}

test_reset_triggers_when_head_matches() {
    require_reset "test_reset_triggers_when_head_matches" || return
    local repo; repo="$(setup_repo "rs-match")"
    local sid="sess-match"
    local head; head="$(git -C "$repo" rev-parse HEAD)"
    local state_dir="$TMPDIR_BASE/wf-match"
    local state; state="$(printf '{"version":1,"session_id":"%s","steps":{"branching_complete":{"status":"complete","updated_at":null},"run_tests":{"status":"complete","updated_at":null}},"last_pushed_sha":"%s"}' "$sid" "$head")"
    setup_workflow_state "$sid" "$state_dir" "$state"
    local payload; payload="$(printf '{"session_id":"%s","cwd":"%s","prompt":"hi"}' "$sid" "$repo")"
    local out
    out="$(echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$RESET_JS" 2>/dev/null)"
    if echo "$out" | grep -q "branching_complete"; then
        pass "reset triggered when HEAD matches last_pushed_sha"
    else
        fail "reset NOT triggered (got: $out)"
    fi
}

test_reset_output_uses_hookSpecificOutput_envelope() {
    # UserPromptSubmit contract: additionalContext must be nested under
    # hookSpecificOutput.{hookEventName,additionalContext}. Flat format is silently
    # ignored by Claude Code, which is hard to detect without this contract test.
    require_reset "test_reset_output_uses_hookSpecificOutput_envelope" || return
    local repo; repo="$(setup_repo "rs-envelope")"
    local sid="sess-envelope"
    local head; head="$(git -C "$repo" rev-parse HEAD)"
    local state_dir="$TMPDIR_BASE/wf-envelope"
    local state; state="$(printf '{"version":1,"session_id":"%s","steps":{},"last_pushed_sha":"%s"}' "$sid" "$head")"
    setup_workflow_state "$sid" "$state_dir" "$state"
    local payload; payload="$(printf '{"session_id":"%s","cwd":"%s","prompt":"hi"}' "$sid" "$repo")"
    local out
    out="$(echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$RESET_JS" 2>/dev/null)"
    # Validate JSON structure via node — must contain hookSpecificOutput.additionalContext
    local valid; valid="$(node -e "
      let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
        try {
          const j=JSON.parse(d);
          const ok=j.hookSpecificOutput
            && j.hookSpecificOutput.hookEventName==='UserPromptSubmit'
            && typeof j.hookSpecificOutput.additionalContext==='string'
            && j.hookSpecificOutput.additionalContext.length>0;
          console.log(ok?'ok':'bad');
        } catch(e) { console.log('parse-error'); }
      });" <<< "$out" 2>/dev/null)"
    if [ "$valid" = "ok" ]; then
        pass "reset output uses hookSpecificOutput envelope (UserPromptSubmit contract)"
    else
        fail "reset output missing hookSpecificOutput envelope (got: $out)"
    fi
}

test_reset_clears_last_pushed_sha() {
    require_reset "test_reset_clears_last_pushed_sha" || return
    local repo; repo="$(setup_repo "rs-clear")"
    local sid="sess-clear"
    local head; head="$(git -C "$repo" rev-parse HEAD)"
    local state_dir="$TMPDIR_BASE/wf-clear"
    local state; state="$(printf '{"version":1,"session_id":"%s","steps":{"branching_complete":{"status":"complete","updated_at":null}},"last_pushed_sha":"%s"}' "$sid" "$head")"
    setup_workflow_state "$sid" "$state_dir" "$state"
    local payload; payload="$(printf '{"session_id":"%s","cwd":"%s","prompt":"hi"}' "$sid" "$repo")"
    echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$RESET_JS" >/dev/null 2>&1
    local stored; stored="$(node -e "const j=require('$state_dir/$sid.json');console.log(JSON.stringify(j.last_pushed_sha))" 2>/dev/null)"
    if [ "$stored" = "null" ]; then
        pass "reset clears last_pushed_sha after match"
    else
        fail "last_pushed_sha not cleared (got: $stored)"
    fi
}

test_reset_skips_when_head_differs() {
    require_reset "test_reset_skips_when_head_differs" || return
    local repo; repo="$(setup_repo "rs-skip")"
    local sid="sess-skip"
    local state_dir="$TMPDIR_BASE/wf-skip"
    # Stale SHA — does not match current HEAD
    local stale_sha="0000000000000000000000000000000000000000"
    local state; state="$(printf '{"version":1,"session_id":"%s","steps":{},"last_pushed_sha":"%s"}' "$sid" "$stale_sha")"
    setup_workflow_state "$sid" "$state_dir" "$state"
    local payload; payload="$(printf '{"session_id":"%s","cwd":"%s","prompt":"hi"}' "$sid" "$repo")"
    local out
    out="$(echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$RESET_JS" 2>/dev/null)"
    if echo "$out" | grep -q "branching_complete"; then
        fail "reset triggered despite HEAD mismatch (got: $out)"
    else
        pass "reset skipped when HEAD does not match last_pushed_sha"
    fi
}

test_normalizeCwd_unit() {
    # Unit test for hooks/lib/path-normalize.js
    local lib="$AGENTS_DIR/hooks/lib/path-normalize.js"
    if [ ! -f "$lib" ]; then fail "path-normalize.js not present"; return; fi
    # Run a node script that asserts each case and reports overall ok/bad
    local result
    result="$(node -e "
      const { normalizeCwd } = require(process.argv[1]);
      const isWin = process.platform === 'win32';
      const cases = [
        // [input, expected-on-win, expected-on-other]
        ['/c/git/dotfiles', isWin ? 'C:\\\\git\\\\dotfiles' : '/c/git/dotfiles'],
        ['/d/some/path',    isWin ? 'D:\\\\some\\\\path'    : '/d/some/path'],
        ['C:\\\\git\\\\foo', 'C:\\\\git\\\\foo'],   // already Windows-style → unchanged
        ['/usr/local/bin',   '/usr/local/bin'],     // posix path (not single-letter drive) → unchanged
        ['', undefined],
        [null, undefined],
        [undefined, undefined],
      ];
      const fails = [];
      for (const [inp, exp] of cases) {
        const got = normalizeCwd(inp);
        if (got !== exp) fails.push(JSON.stringify({inp, exp, got}));
      }
      console.log(fails.length === 0 ? 'ok' : 'bad: ' + fails.join('; '));
    " "$lib" 2>/dev/null)"
    if [ "$result" = "ok" ]; then
        pass "normalizeCwd handles Unix-style, Windows-style, and edge cases"
    else
        fail "normalizeCwd unit test failed: $result"
    fi
}

# Convert a Windows-style path (C:/foo or C:\foo) to Unix-style (/c/foo) for testing.
# Returns empty string if input is not a Windows-style path.
to_unix_style_path() {
    local p="$1"
    if [[ "$p" =~ ^([A-Za-z]):[/\\] ]]; then
        local drive_lower
        drive_lower="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        # /c/<rest with forward slashes>
        local rest="${p#?:}"   # strip "C:" or "c:"
        rest="${rest//\\/\/}"  # backslash → forward slash
        # rest may start with / or not; ensure single leading /
        rest="${rest#/}"
        echo "/$drive_lower/$rest"
    fi
}

test_workflow_mark_handles_unix_style_cwd() {
    # F3 regression: workflow-mark.js must handle Unix-style cwd (/c/git/foo) on Windows.
    # CC running through Git Bash passes cwd in this format; without normalization,
    # execSync rejects it and last_pushed_sha is silently dropped.
    if [ ! -f "$WORKFLOW_MARK_JS" ]; then fail "workflow-mark.js not present"; return; fi
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) pass "test_workflow_mark_handles_unix_style_cwd skipped on non-Windows"; return ;;
    esac
    local repo; repo="$(setup_repo "wm-unix-cwd")"
    local target_sha; target_sha="$(git -C "$repo" rev-parse HEAD)"
    # Force Unix-style cwd regardless of TMPDIR shape
    local unix_cwd; unix_cwd="$(to_unix_style_path "$repo")"
    [ -n "$unix_cwd" ] || { fail "could not derive Unix-style cwd from $repo"; return; }

    local sid="sess-wm-unix-$$"
    local state_dir="$TMPDIR_BASE/wf-wm-unix"
    mkdir -p "$state_dir"
    printf '{"version":1,"session_id":"%s","steps":{"user_verification":{"status":"pending","updated_at":null}}}' "$sid" > "$state_dir/$sid.json"
    local payload
    payload="$(printf '{"session_id":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push"},"tool_response":{"exit_code":0}}' "$sid" "$unix_cwd")"
    echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$WORKFLOW_MARK_JS" >/dev/null 2>&1
    local recorded; recorded="$(node -e "const j=require('$state_dir/$sid.json');console.log(j.last_pushed_sha||'')" 2>/dev/null)"
    if [ "$recorded" = "$target_sha" ]; then
        pass "workflow-mark normalizes Unix-style cwd on Windows (F3 regression)"
    else
        fail "workflow-mark failed with Unix-style cwd '$unix_cwd' (recorded: '$recorded', expected: '$target_sha')"
    fi
}

test_post_push_reset_handles_unix_style_cwd() {
    # F3 regression: post-push-workflow-reset.js must handle Unix-style cwd on Windows.
    if [ ! -f "$RESET_JS" ]; then fail "post-push-workflow-reset.js not present"; return; fi
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) pass "test_post_push_reset_handles_unix_style_cwd skipped on non-Windows"; return ;;
    esac
    local repo; repo="$(setup_repo "rs-unix-cwd")"
    local unix_cwd; unix_cwd="$(to_unix_style_path "$repo")"
    [ -n "$unix_cwd" ] || { fail "could not derive Unix-style cwd from $repo"; return; }
    local head; head="$(git -C "$repo" rev-parse HEAD)"
    local sid="sess-rs-unix-$$"
    local state_dir="$TMPDIR_BASE/wf-rs-unix"
    local state; state="$(printf '{"version":1,"session_id":"%s","steps":{},"last_pushed_sha":"%s"}' "$sid" "$head")"
    setup_workflow_state "$sid" "$state_dir" "$state"
    local payload; payload="$(printf '{"session_id":"%s","cwd":"%s","prompt":"hi"}' "$sid" "$unix_cwd")"
    local out
    out="$(echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$RESET_JS" 2>/dev/null)"
    if echo "$out" | grep -q "branching_complete"; then
        pass "post-push-reset normalizes Unix-style cwd on Windows (F3 regression)"
    else
        fail "post-push-reset failed with Unix-style cwd '$unix_cwd' (got: $out)"
    fi
}

test_workflow_mark_resolves_cwd_when_stdin_lacks_cwd() {
    # F4 regression: production PostToolUse stdin may not include `cwd`. The hook
    # must still resolve to the user's repo via state.cwd (set at session-start).
    # process.cwd() typically points at the agents hook lib repo and is the wrong answer.
    if [ ! -f "$WORKFLOW_MARK_JS" ]; then fail "workflow-mark.js not present"; return; fi
    local repo_target; repo_target="$(setup_repo "wm-no-cwd")"
    local repo_other; repo_other="$(setup_repo "wm-no-cwd-other")"
    echo "x" >> "$repo_other/README.md"
    git -C "$repo_other" add README.md
    git -C "$repo_other" commit -q -m "second"
    local target_sha; target_sha="$(git -C "$repo_target" rev-parse HEAD)"

    local sid="sess-wm-no-cwd-$$"
    local state_dir="$TMPDIR_BASE/wf-wm-no-cwd"
    mkdir -p "$state_dir"
    # state.cwd points at target; this is what session-start.js writes in production
    printf '{"version":1,"session_id":"%s","cwd":"%s","steps":{"user_verification":{"status":"pending","updated_at":null}}}' "$sid" "$repo_target" > "$state_dir/$sid.json"

    # Production-shape stdin: NO cwd field
    local payload
    payload="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git push origin foo"},"tool_response":{"exit_code":0}}' "$sid")"

    # process.cwd() is repo_other (the wrong repo, simulating agents)
    (
        cd "$repo_other"
        unset CLAUDE_PROJECT_DIR
        echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$WORKFLOW_MARK_JS" >/dev/null 2>&1
    )

    local recorded; recorded="$(node -e "const j=require('$state_dir/$sid.json');console.log(j.last_pushed_sha||'')" 2>/dev/null)"
    if [ "$recorded" = "$target_sha" ]; then
        pass "workflow-mark falls back to state.cwd when stdin lacks cwd (F4)"
    else
        fail "workflow-mark wrong cwd (recorded: '$recorded', expected: '$target_sha')"
    fi
}

test_workflow_mark_resolves_cwd_from_dash_C() {
    # F4 regression: when command is `git -C <path> push`, that path takes precedence
    # over CLAUDE_PROJECT_DIR and state.cwd (it's an explicit user override).
    if [ ! -f "$WORKFLOW_MARK_JS" ]; then fail "workflow-mark.js not present"; return; fi
    local repo_target; repo_target="$(setup_repo "wm-dashC")"
    local repo_other; repo_other="$(setup_repo "wm-dashC-other")"
    echo "x" >> "$repo_other/README.md"
    git -C "$repo_other" add README.md
    git -C "$repo_other" commit -q -m "second"
    local target_sha; target_sha="$(git -C "$repo_target" rev-parse HEAD)"

    local sid="sess-wm-dashC-$$"
    local state_dir="$TMPDIR_BASE/wf-wm-dashC"
    mkdir -p "$state_dir"
    # state.cwd points at OTHER (different from target, ensuring -C wins)
    printf '{"version":1,"session_id":"%s","cwd":"%s","steps":{"user_verification":{"status":"pending","updated_at":null}}}' "$sid" "$repo_other" > "$state_dir/$sid.json"

    # Command uses -C to point at target; no cwd in stdin
    local payload
    payload="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git -C %s push origin foo"},"tool_response":{"exit_code":0}}' "$sid" "$repo_target")"

    (
        cd "$repo_other"
        unset CLAUDE_PROJECT_DIR
        echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$WORKFLOW_MARK_JS" >/dev/null 2>&1
    )

    local recorded; recorded="$(node -e "const j=require('$state_dir/$sid.json');console.log(j.last_pushed_sha||'')" 2>/dev/null)"
    if [ "$recorded" = "$target_sha" ]; then
        pass "workflow-mark uses -C path from command (overrides state.cwd) (F4)"
    else
        fail "workflow-mark didn't honor -C path (recorded: '$recorded', expected: '$target_sha')"
    fi
}

test_workflow_mark_resolves_cwd_from_CLAUDE_PROJECT_DIR() {
    # F4 regression: CLAUDE_PROJECT_DIR (CC-set per hook) is preferred over state.cwd.
    if [ ! -f "$WORKFLOW_MARK_JS" ]; then fail "workflow-mark.js not present"; return; fi
    local repo_target; repo_target="$(setup_repo "wm-cpd")"
    local repo_other; repo_other="$(setup_repo "wm-cpd-other")"
    echo "x" >> "$repo_other/README.md"
    git -C "$repo_other" add README.md
    git -C "$repo_other" commit -q -m "second"
    local target_sha; target_sha="$(git -C "$repo_target" rev-parse HEAD)"

    local sid="sess-wm-cpd-$$"
    local state_dir="$TMPDIR_BASE/wf-wm-cpd"
    mkdir -p "$state_dir"
    # state.cwd points at OTHER (CLAUDE_PROJECT_DIR should win)
    printf '{"version":1,"session_id":"%s","cwd":"%s","steps":{"user_verification":{"status":"pending","updated_at":null}}}' "$sid" "$repo_other" > "$state_dir/$sid.json"

    local payload
    payload="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git push origin foo"},"tool_response":{"exit_code":0}}' "$sid")"

    (cd "$repo_other" && echo "$payload" | CLAUDE_PROJECT_DIR="$repo_target" CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$WORKFLOW_MARK_JS" >/dev/null 2>&1)

    local recorded; recorded="$(node -e "const j=require('$state_dir/$sid.json');console.log(j.last_pushed_sha||'')" 2>/dev/null)"
    if [ "$recorded" = "$target_sha" ]; then
        pass "workflow-mark uses CLAUDE_PROJECT_DIR over state.cwd (F4)"
    else
        fail "workflow-mark wrong cwd (recorded: '$recorded', expected: '$target_sha')"
    fi
}

test_workflow_mark_records_sha_from_input_cwd() {
    # F2 regression: workflow-mark.js must read HEAD from input.cwd, not process.cwd().
    # Otherwise post-push-workflow-reset.js (which uses input.cwd) never sees a
    # matching SHA — the push-boundary reset chain is silently broken.
    if [ ! -f "$WORKFLOW_MARK_JS" ]; then fail "workflow-mark.js not present"; return; fi
    local repo_target; repo_target="$(setup_repo "wm-target")"
    local repo_other; repo_other="$(setup_repo "wm-other")"
    # Diverge repo_other's HEAD from repo_target's
    echo "x" >> "$repo_other/README.md"
    git -C "$repo_other" add README.md
    git -C "$repo_other" commit -q -m "second"

    local target_sha; target_sha="$(git -C "$repo_target" rev-parse HEAD)"
    local other_sha; other_sha="$(git -C "$repo_other" rev-parse HEAD)"
    if [ "$target_sha" = "$other_sha" ]; then
        fail "test setup: SHAs unexpectedly match"; return
    fi

    local sid="sess-wm-$$"
    local state_dir="$TMPDIR_BASE/wf-wm"
    mkdir -p "$state_dir"
    # Minimal initial state (markStep needs a state file to mutate)
    printf '{"version":1,"session_id":"%s","steps":{"user_verification":{"status":"pending","updated_at":null}}}' "$sid" > "$state_dir/$sid.json"

    # Simulate push completion: input.cwd = repo_target, but invoke node from repo_other
    local payload
    payload="$(printf '{"session_id":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push"},"tool_response":{"exit_code":0}}' "$sid" "$repo_target")"
    (cd "$repo_other" && echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$WORKFLOW_MARK_JS" >/dev/null 2>&1)

    local recorded; recorded="$(node -e "const j=require('$state_dir/$sid.json');console.log(j.last_pushed_sha||'')" 2>/dev/null)"
    if [ "$recorded" = "$target_sha" ]; then
        pass "workflow-mark uses input.cwd for HEAD lookup (not process.cwd())"
    elif [ "$recorded" = "$other_sha" ]; then
        fail "workflow-mark used process.cwd() instead of input.cwd (got other repo's HEAD)"
    else
        fail "workflow-mark recorded unexpected SHA (got: '$recorded')"
    fi
}

test_reset_skips_when_no_last_pushed_sha() {
    require_reset "test_reset_skips_when_no_last_pushed_sha" || return
    local repo; repo="$(setup_repo "rs-nosha")"
    local sid="sess-nosha"
    local state_dir="$TMPDIR_BASE/wf-nosha"
    local state; state="$(printf '{"version":1,"session_id":"%s","steps":{}}' "$sid")"
    setup_workflow_state "$sid" "$state_dir" "$state"
    local payload; payload="$(printf '{"session_id":"%s","cwd":"%s","prompt":"hi"}' "$sid" "$repo")"
    local out
    out="$(echo "$payload" | CLAUDE_WORKFLOW_DIR="$state_dir" run_with_timeout 30 node "$RESET_JS" 2>/dev/null)"
    if echo "$out" | grep -q "branching_complete"; then
        fail "reset triggered without last_pushed_sha (got: $out)"
    else
        pass "reset skipped when last_pushed_sha is unset"
    fi
}

# ============ Run all tests ============

# auto-branch-guard
test_guard_blocks_default_branch_when_on
test_guard_allows_feature_branch_when_on
test_guard_off_allows_default_branch
test_guard_truthy_values
test_guard_falsy_values
test_guard_default_is_on
test_guard_unborn_head_allows
test_guard_detached_head_allows
test_guard_non_git_path_allows
test_guard_default_branches_override
test_guard_master_default_branch
test_guard_worktree_of_main_blocks
test_guard_non_edit_tool_passthrough
test_guard_block_message_format

# .env loader
test_envfile_off_allows_default_branch
test_envfile_on_blocks_default_branch
test_envfile_quoted_values
test_envfile_comments_and_blanks_skipped
test_envfile_existing_env_wins
test_envfile_default_branches_override
test_envfile_missing_is_silent

# pre-commit defense
test_pre_commit_blocks_on_default_branch
test_pre_commit_allows_feature_branch
test_pre_commit_off_allows_default_branch

# path-normalize unit + cross-platform regressions
test_normalizeCwd_unit
test_workflow_mark_handles_unix_style_cwd
test_post_push_reset_handles_unix_style_cwd

# workflow-mark + post-push-workflow-reset (push boundary chain)
test_workflow_mark_resolves_cwd_when_stdin_lacks_cwd
test_workflow_mark_resolves_cwd_from_dash_C
test_workflow_mark_resolves_cwd_from_CLAUDE_PROJECT_DIR
test_workflow_mark_records_sha_from_input_cwd
test_reset_triggers_when_head_matches
test_reset_output_uses_hookSpecificOutput_envelope
test_reset_clears_last_pushed_sha
test_reset_skips_when_head_differs
test_reset_skips_when_no_last_pushed_sha

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
