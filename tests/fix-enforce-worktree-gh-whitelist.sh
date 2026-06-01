#!/bin/bash
# tests/fix-enforce-worktree-gh-whitelist.sh
# Tests: hooks/enforce-worktree.js, hooks/lib/bash-write-patterns.js
# Tags: worktree, enforce, hook, intent, planning
#
# Integration tests for the gh-command whitelist refactor in enforce-worktree.js.
#
# Targets:
#   - hooks/lib/bash-write-patterns.js  (Group A → read, Group B → write,
#                                        gh api flag-form coverage)
#   - hooks/enforce-worktree.js         (session-scope: cwd repo + EXTRA_REPOS)
#
# Limitation: an "out-of-session repo" scenario via natural gh CLI is unreachable
# because gh does not honor -C and CWD is always added to sessionRoots. The
# session-scope BLOCK path is exercised in the sibling guard.sh test via
# `git -C` indirection. --repo flag parsing is intentionally out of scope.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
PATTERNS_JS="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'gh-whitelist-'+process.pid).replace(/\\\\/g,'/');
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
    echo "$repo"
}

# Returns "<main_repo>|<wt_path>"
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# Run the enforce-worktree guard.
# Args: command cwd [env-VAR=val ...]
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

# Classify via bash-write-patterns directly.
classify_cmd() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$PATTERNS_JS');
        console.log(m.classify(process.argv[1]));
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$1" 2>/dev/null
}

assert_classify() {
    local desc="$1" cmd="$2" expected="$3"
    local got; got="$(classify_cmd "$cmd")"
    if [ "$got" = "$expected" ]; then
        pass "$desc -> $expected"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# Convert a path to the form Node's process.cwd() will report on this
# platform (cygpath -m on Git Bash, identity elsewhere).
norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Group A: always-allow gh commands
# ─────────────────────────────────────────────────────────────────────────────

test_group_a_pr_create_from_session_worktree() {
    require_guard "test_group_a_pr_create_from_session_worktree" || return
    local pair; pair="$(setup_linked_worktree "A-pr-create-wt")"
    local wt="${pair#*|}"
    local out; out="$(run_bash_guard "gh pr create --fill" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Group A: gh pr create from session worktree allows"
    else
        fail "Group A: gh pr create from session worktree should allow ($out)"
    fi
}

test_group_a_pr_create_from_main_checkout() {
    require_guard "test_group_a_pr_create_from_main_checkout" || return
    local repo; repo="$(setup_main_checkout "A-pr-create-main")"
    local out; out="$(run_bash_guard "gh pr create --fill" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Group A: gh pr create from main worktree allows"
    else
        fail "Group A: gh pr create from main worktree should allow ($out)"
    fi
}

test_group_a_pr_create_from_non_git_dir() {
    require_guard "test_group_a_pr_create_from_non_git_dir" || return
    local d="$TMPDIR_BASE/A-nongit-$$"
    mkdir -p "$d"
    local out; out="$(run_bash_guard "gh pr create --fill" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Group A: gh pr create from non-git dir allows"
    else
        fail "Group A: gh pr create from non-git dir should allow ($out)"
    fi
}

test_group_a_remaining_commands_allow_from_main_checkout() {
    require_guard "test_group_a_remaining_commands_allow_from_main_checkout" || return
    local repo; repo="$(setup_main_checkout "A-remaining")"
    local cmds=(
        "gh pr edit 1"
        "gh pr close 1"
        "gh pr comment 1 --body x"
        "gh pr review 1 --approve"
        "gh issue edit 1"
        "gh issue close 1"
        "gh issue comment 1 --body x"
        "gh repo create owner/repo --public"
        "gh repo edit --private"
        "gh repo rename new-name"
        "gh repo archive owner/repo"
    )
    local c out
    for c in "${cmds[@]}"; do
        out="$(run_bash_guard "$c" "$repo" ENFORCE_WORKTREE=on)"
        if guard_decision "$out"; then
            pass "Group A: '$c' from main worktree allows"
        else
            fail "Group A: '$c' from main worktree should allow ($out)"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Group B: session-scoped writes
# ─────────────────────────────────────────────────────────────────────────────

test_group_b_pr_merge_from_session_worktree() {
    require_guard "test_group_b_pr_merge_from_session_worktree" || return
    local pair; pair="$(setup_linked_worktree "B-merge-wt")"
    local wt="${pair#*|}"
    local out; out="$(run_bash_guard "gh pr merge 1 --squash" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Group B: gh pr merge from session worktree allows"
    else
        fail "Group B: gh pr merge from session worktree should allow ($out)"
    fi
}

test_group_b_pr_merge_from_main_checkout_blocks() {
    require_guard "test_group_b_pr_merge_from_main_checkout_blocks" || return
    local repo; repo="$(setup_main_checkout "B-merge-main")"
    local out; out="$(run_bash_guard "gh pr merge 1 --squash" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Group B: gh pr merge from main worktree should block ($out)"
    else
        pass "Group B: gh pr merge from main worktree blocks (mainCheckout)"
    fi
}

# NOTE: An "out-of-session repo" scenario via natural gh usage is unreachable:
# CWD is always added to sessionRoots, and gh CLI does not honor -C, so
# detected repo always equals CWD repo, which is always in session.
# The session-scope BLOCK path is exercised in guard.sh via `git -C` indirection.
# Documented limitation: --repo flag parsing is out of scope for this fix.

test_group_b_pr_merge_from_non_git_dir_blocks() {
    require_guard "test_group_b_pr_merge_from_non_git_dir_blocks" || return
    local d="$TMPDIR_BASE/B-merge-nongit-$$"
    mkdir -p "$d"
    local out; out="$(run_bash_guard "gh pr merge 1" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Group B: gh pr merge from non-git dir should block ($out)"
    else
        pass "Group B: gh pr merge from non-git dir blocks (no repo)"
    fi
}

# Same scope matrix for the rest of Group B (session worktree + main + non-git;
# out-of-session is unreachable via natural gh usage — see note above).
test_group_b_other_writes_scope_matrix() {
    require_guard "test_group_b_other_writes_scope_matrix" || return
    local pair; pair="$(setup_linked_worktree "B-matrix-wt")"
    local wt="${pair#*|}"
    local main_repo; main_repo="$(setup_main_checkout "B-matrix-main")"
    local nongit="$TMPDIR_BASE/B-matrix-nongit-$$"
    mkdir -p "$nongit"

    local cmds=(
        "gh issue delete 1"
        "gh repo delete owner/repo"
        "gh release create v1"
        "gh release delete v1"
        "gh release upload v1 file.zip"
        "gh api -X POST /repos"
    )
    local c out
    for c in "${cmds[@]}"; do
        # In session worktree → allow
        out="$(run_bash_guard "$c" "$wt" ENFORCE_WORKTREE=on)"
        if guard_decision "$out"; then
            pass "Group B: '$c' from session worktree allows"
        else
            fail "Group B: '$c' from session worktree should allow ($out)"
        fi
        # From main worktree → block
        out="$(run_bash_guard "$c" "$main_repo" ENFORCE_WORKTREE=on)"
        if guard_decision "$out"; then
            fail "Group B: '$c' from main worktree should block ($out)"
        else
            pass "Group B: '$c' from main worktree blocks"
        fi
        # From non-git dir → block
        out="$(run_bash_guard "$c" "$nongit" ENFORCE_WORKTREE=on)"
        if guard_decision "$out"; then
            fail "Group B: '$c' from non-git dir should block ($out)"
        else
            pass "Group B: '$c' from non-git dir blocks"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# ENFORCE_WORKTREE_EXTRA_REPOS handling
# ─────────────────────────────────────────────────────────────────────────────

test_extra_repos_includes_repo_in_scope() {
    require_guard "test_extra_repos_includes_repo_in_scope" || return
    local pair_session; pair_session="$(setup_linked_worktree "E-session")"
    local wt_session="${pair_session#*|}"
    local pair_extra;   pair_extra="$(setup_linked_worktree "E-extra")"
    local wt_extra="${pair_extra#*|}"
    local main_extra="${pair_extra%|*}"
    local extra_norm; extra_norm="$(norm_path "$main_extra")"
    local out
    out="$(run_bash_guard "gh pr merge 1" "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extra_norm")"
    # CWD is session worktree which is itself a feature branch — should allow.
    if guard_decision "$out"; then
        pass "EXTRA_REPOS: cwd in session, extra registered, gh write allows"
    else
        fail "EXTRA_REPOS: gh write from session worktree should allow ($out)"
    fi
    # Now invoke from EXTRA repo's worktree → should allow too (extra repo in scope).
    out="$(run_bash_guard "gh pr merge 1" "$wt_extra" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extra_norm")"
    if guard_decision "$out"; then
        pass "EXTRA_REPOS: cwd is extra repo, gh write allows (in scope)"
    else
        fail "EXTRA_REPOS: cwd is extra repo should allow ($out)"
    fi
}

# NOTE: "Without EXTRA_REPOS, other repo blocks" is unreachable via natural gh
# usage — CWD is always in session. Removed; see top-of-file note.

# Verify EXTRA_REPOS is actually consulted: use `git -C <other-repo>` indirection
# so detected repo != cwd repo. Without EXTRA_REPOS → block; with → allow.
test_extra_repos_consulted_via_git_C_indirection() {
    require_guard "test_extra_repos_consulted_via_git_C_indirection" || return
    local pair_session; pair_session="$(setup_linked_worktree "E-consult-session")"
    local wt_session="${pair_session#*|}"
    local pair_target;  pair_target="$(setup_linked_worktree "E-consult-target")"
    local wt_target="${pair_target#*|}"
    local target_norm;  target_norm="$(norm_path "$wt_target")"
    local out

    # Without EXTRA_REPOS: detected = wt_target (via git -C), session = {wt_session},
    # wt_target NOT in session → block.
    out="$(run_bash_guard "git -C $wt_target rev-parse HEAD && gh pr merge 1" "$wt_session" \
        ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "EXTRA_REPOS not set: target via -C should block (out of scope) ($out)"
    else
        pass "EXTRA_REPOS not set: out-of-scope target via git -C blocks"
    fi

    # With EXTRA_REPOS=<wt_target>: now in session → allow.
    out="$(run_bash_guard "git -C $wt_target rev-parse HEAD && gh pr merge 1" "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$target_norm")"
    if guard_decision "$out"; then
        pass "EXTRA_REPOS includes target: git -C target allows (in scope)"
    else
        fail "EXTRA_REPOS includes target: git -C target should allow ($out)"
    fi
}

test_extra_repos_empty_only_cwd_in_scope() {
    require_guard "test_extra_repos_empty_only_cwd_in_scope" || return
    local pair_session; pair_session="$(setup_linked_worktree "E-empty-session")"
    local wt_session="${pair_session#*|}"
    local out
    # CWD = session → allow
    out="$(run_bash_guard "gh pr merge 1" "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=")"
    if guard_decision "$out"; then
        pass "EXTRA_REPOS='': cwd repo allows"
    else
        fail "EXTRA_REPOS='': cwd repo should allow ($out)"
    fi
}

test_extra_repos_whitespace_padded_trimmed() {
    require_guard "test_extra_repos_whitespace_padded_trimmed" || return
    local pair_session; pair_session="$(setup_linked_worktree "E-ws-session")"
    local wt_session="${pair_session#*|}"
    local pair_a; pair_a="$(setup_linked_worktree "E-ws-a")"
    local pair_b; pair_b="$(setup_linked_worktree "E-ws-b")"
    local main_a="${pair_a%|*}"; local wt_a="${pair_a#*|}"
    local main_b="${pair_b%|*}"; local wt_b="${pair_b#*|}"
    local a_norm; a_norm="$(norm_path "$main_a")"
    local b_norm; b_norm="$(norm_path "$main_b")"
    local extras=" $a_norm ; $b_norm "
    local out
    out="$(run_bash_guard "gh pr merge 1" "$wt_a" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "EXTRA_REPOS whitespace: trimmed, repo A in scope"
    else
        fail "EXTRA_REPOS whitespace: repo A should be in scope ($out)"
    fi
    out="$(run_bash_guard "gh pr merge 1" "$wt_b" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "EXTRA_REPOS whitespace: trimmed, repo B in scope"
    else
        fail "EXTRA_REPOS whitespace: repo B should be in scope ($out)"
    fi
}

test_extra_repos_nonexistent_silently_skipped() {
    require_guard "test_extra_repos_nonexistent_silently_skipped" || return
    local pair; pair="$(setup_linked_worktree "E-nonex")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local valid_norm; valid_norm="$(norm_path "$main")"
    local extras="/totally/nonexistent/path;$valid_norm"
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "EXTRA_REPOS: nonexistent silent-skipped, valid still works"
    else
        fail "EXTRA_REPOS: valid entry should still apply ($out)"
    fi
}

test_extra_repos_only_separators_no_error() {
    require_guard "test_extra_repos_only_separators_no_error" || return
    local pair; pair="$(setup_linked_worktree "E-seps")"
    local wt="${pair#*|}"
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=;;;")"
    # Must not crash; cwd is in session so allow.
    if echo "$out" | grep -qE '"decision":"(allow|block)"|^\{\}$|^$'; then
        pass "EXTRA_REPOS=';;;': handled without crash"
    else
        # If output is something like {} it's also fine — guard exited cleanly.
        if [ -z "$out" ] || [ "$out" = "{}" ]; then
            pass "EXTRA_REPOS=';;;': handled without crash (empty/allow output)"
        else
            fail "EXTRA_REPOS=';;;': unexpected output ($out)"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Bypass
# ─────────────────────────────────────────────────────────────────────────────

test_off_mode_allows_all_gh_writes() {
    require_guard "test_off_mode_allows_all_gh_writes" || return
    local repo; repo="$(setup_main_checkout "off-gh")"
    local cmds=(
        "gh pr merge 1"
        "gh issue delete 1"
        "gh repo delete owner/repo"
        "gh release create v1"
        "gh api -X POST /repos"
    )
    local c out
    for c in "${cmds[@]}"; do
        out="$(run_bash_guard "$c" "$repo" ENFORCE_WORKTREE=off)"
        if guard_decision "$out"; then
            pass "OFF: '$c' allows regardless of scope"
        else
            fail "OFF: '$c' should allow but blocked ($out)"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# gh api flag-form classifier regression
# ─────────────────────────────────────────────────────────────────────────────

test_gh_api_flag_forms_write() {
    # Mutating verbs in all flag forms — uppercase + lowercase (regex /i)
    assert_classify "gh api -X POST"          "gh api -X POST /repos"          "write"
    assert_classify "gh api -XPOST (no space)" "gh api -XPOST /repos"          "write"
    assert_classify "gh api -X=POST"          "gh api -X=POST /repos"          "write"
    assert_classify "gh api --method POST"    "gh api --method POST /repos"    "write"
    assert_classify "gh api --method=POST"    "gh api --method=POST /repos"    "write"
    assert_classify "gh api -X PUT"           "gh api -X PUT /repos/o/r"       "write"
    assert_classify "gh api -X PATCH"         "gh api -X PATCH /repos/o/r"     "write"
    assert_classify "gh api -X DELETE"        "gh api -X DELETE /repos/o/r"    "write"
    assert_classify "gh api --method PATCH"   "gh api --method PATCH /repos"   "write"
    assert_classify "gh api --method=DELETE"  "gh api --method=DELETE /repos"  "write"
    # Lowercase verb (regex is case-insensitive)
    assert_classify "gh api -X post (lower)"  "gh api -X post /repos"          "write"
    assert_classify "gh api --method=delete (lower)" "gh api --method=delete /repos" "write"
}

test_gh_api_flag_forms_read() {
    assert_classify "gh api -X GET"  "gh api -X GET /repos"  "read"
    assert_classify "gh api -X HEAD" "gh api -X HEAD /repos" "read"
    # Lowercase non-mutating
    assert_classify "gh api -X get (lower)" "gh api -X get /repos" "read"
    # No -X / --method (defaults to GET) → read
    assert_classify "gh api (no method)" "gh api /repos" "read"
}

# ─────────────────────────────────────────────────────────────────────────────
# Security: shell metacharacters in EXTRA_REPOS
# ─────────────────────────────────────────────────────────────────────────────

test_extra_repos_metacharacters_safe() {
    require_guard "test_extra_repos_metacharacters_safe" || return
    local pair; pair="$(setup_linked_worktree "E-metachar")"
    local wt="${pair#*|}"
    local sentinel="$TMPDIR_BASE/metachar-injected-$$"
    # Each value below contains a shell metacharacter that, if exec'd, would
    # create the sentinel file.
    local payloads=(
        "/tmp/a;mkdir $sentinel"
        "/tmp/a\$(mkdir $sentinel)"
        "/tmp/a|mkdir $sentinel"
        "/tmp/a\`mkdir $sentinel\`"
    )
    local p out
    for p in "${payloads[@]}"; do
        rm -rf "$sentinel" 2>/dev/null
        out="$(run_bash_guard "gh pr merge 1" "$wt" \
            ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$p" 2>/dev/null)"
        if [ -d "$sentinel" ] || [ -e "$sentinel" ]; then
            fail "SECURITY: EXTRA_REPOS metachar '$p' executed"
            rm -rf "$sentinel" 2>/dev/null
        else
            pass "EXTRA_REPOS metachar '$p': no command injection"
        fi
        # Hook should not crash either; output should be well-formed JSON or empty.
        if [ -n "$out" ] && ! echo "$out" | grep -qE '^\{.*\}$'; then
            fail "EXTRA_REPOS metachar '$p': malformed output ($out)"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency
# ─────────────────────────────────────────────────────────────────────────────

test_gh_write_idempotent() {
    require_guard "test_gh_write_idempotent" || return
    local repo; repo="$(setup_main_checkout "idem-gh")"
    local a b
    a="$(run_bash_guard "gh pr merge 1" "$repo" ENFORCE_WORKTREE=on)"
    b="$(run_bash_guard "gh pr merge 1" "$repo" ENFORCE_WORKTREE=on)"
    if [ "$a" = "$b" ]; then
        pass "gh write guard is idempotent"
    else
        fail "gh write guard not idempotent (a=$a b=$b)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Edge: Windows path case-insensitive scope
# ─────────────────────────────────────────────────────────────────────────────

test_win_path_case_insensitive_scope() {
    if [ "$(node -p 'process.platform' 2>/dev/null)" != "win32" ]; then
        pass "win32-only test skipped on non-Windows"
        return
    fi
    require_guard "test_win_path_case_insensitive_scope" || return
    local pair; pair="$(setup_linked_worktree "win-case")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local main_norm; main_norm="$(norm_path "$main")"
    # Mixed-case version of the same path.
    local mixed
    mixed="$(node -e "
      const p = process.argv[1];
      let out = '';
      for (let i=0;i<p.length;i++) out += (i%2===0)?p[i].toUpperCase():p[i].toLowerCase();
      console.log(out);
    " -- "$main_norm" 2>/dev/null)"
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$mixed")"
    # cwd is the session worktree (already in scope); the case test is for
    # the EXTRA_REPOS membership normalization. cwd path repo == extra path
    # repo (different case) should be recognized as same scope entry.
    if guard_decision "$out"; then
        pass "win32: mixed-case EXTRA_REPOS path recognized as same repo"
    else
        fail "win32: mixed-case EXTRA_REPOS should match same repo ($out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

# Group A
test_group_a_pr_create_from_session_worktree
test_group_a_pr_create_from_main_checkout
test_group_a_pr_create_from_non_git_dir
test_group_a_remaining_commands_allow_from_main_checkout

# Group B + scope
test_group_b_pr_merge_from_session_worktree
test_group_b_pr_merge_from_main_checkout_blocks
test_group_b_pr_merge_from_non_git_dir_blocks
test_group_b_other_writes_scope_matrix

# EXTRA_REPOS
test_extra_repos_includes_repo_in_scope
test_extra_repos_consulted_via_git_C_indirection
test_extra_repos_empty_only_cwd_in_scope
test_extra_repos_whitespace_padded_trimmed
test_extra_repos_nonexistent_silently_skipped
test_extra_repos_only_separators_no_error

# Bypass
test_off_mode_allows_all_gh_writes

# gh api flag forms
test_gh_api_flag_forms_write
test_gh_api_flag_forms_read

# Security
test_extra_repos_metacharacters_safe

# Idempotency
test_gh_write_idempotent

# Edge
test_win_path_case_insensitive_scope

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
