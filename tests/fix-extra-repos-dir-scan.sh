#!/bin/bash
# tests/fix-extra-repos-dir-scan.sh
#
# Integration tests for the directory-scan fallback in getSessionRepoRoots()
# (enforce-worktree.js).
#
# New behaviour under test:
#   If an ENFORCE_WORKTREE_EXTRA_REPOS entry is NOT itself a git repo root, scan
#   its immediate subdirectories (depth 1 only) for git repos and add those.
#   This lets users write ENFORCE_WORKTREE_EXTRA_REPOS=C:\git instead of listing
#   every individual repo.
#
# Tests labelled [NEW] exercise the new dir-scan path and are EXPECTED TO FAIL
# until the implementation is in place (TDD red phase).
# Tests labelled [EXISTING] verify unchanged/error/regression behaviour and
# MUST PASS with the current code.

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
const d=path.join(os.tmpdir(),'dir-scan-'+process.pid).replace(/\\\\/g,'/');
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

# Returns 0 if guard explicitly allowed, 1 if blocked, 2 if malformed/empty
# (e.g. hook crash, missing JSON output, timeout). Tests must distinguish a
# real allow ({}) from infrastructure failure.
guard_decision() {
    local out="$1"
    if [ -z "$out" ]; then
        return 2
    fi
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    if echo "$out" | grep -qE '^\{\s*\}\s*$|"decision"\s*:'; then
        return 0
    fi
    return 2
}

# Convert path for Node on this platform.
norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# Create a git repo at path with at least one commit.
make_git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" commit -q --allow-empty -m "initial"
}

# Create a main (non-linked) checkout. Returns the repo path.
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    make_git_repo "$repo"
    echo "$repo/README.md" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --amend --no-edit
    echo "$repo"
}

# Returns "<main_repo>|<wt_path>"
setup_linked_worktree() {
    local name="$1"
    local main
    main="$(setup_main_checkout "$name-main")"
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

# ─────────────────────────────────────────────────────────────────────────────
# Helper: create a parent dir containing N git repos and M non-git subdirs.
# Usage: make_parent_with_repos <parent> <repo-names...>
# Non-git subdirs must be created separately.
# ─────────────────────────────────────────────────────────────────────────────
make_parent_with_repos() {
    local parent="$1"; shift
    mkdir -p "$parent"
    for name in "$@"; do
        make_git_repo "$parent/$name"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# N1 [NEW] — Parent dir with 2 git repos in subdirs → both repos allowed for
#            gh writes when EXTRA_REPOS points to the parent.
# ─────────────────────────────────────────────────────────────────────────────
test_N1_parent_dir_two_repos_allowed() {
    require_guard "N1" || return

    local parent="$TMPDIR_BASE/N1-parent-$$"
    make_parent_with_repos "$parent" "repoA" "repoB"

    # Session anchor: a linked worktree of an UNRELATED repo (not in parent).
    # CWD is here, so cwdRoot=wt_session — the target repo is only in scope
    # if dir-scan actually fires. Without dir-scan, gh writes targeting
    # parent/repoA via git -C would block.
    local pair; pair="$(setup_linked_worktree "N1-session")"
    local wt_session="${pair#*|}"

    local parent_norm; parent_norm="$(norm_path "$parent")"
    local repoA_norm; repoA_norm="$(norm_path "$parent/repoA")"
    local repoB_norm; repoB_norm="$(norm_path "$parent/repoB")"

    local out
    out="$(run_bash_guard \
        "git -C \"$repoA_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$parent_norm")"
    if guard_decision "$out"; then
        pass "N1: parent dir scan — repoA reachable via git -C, gh write allows [NEW]"
    else
        fail "N1: parent dir scan — repoA should be in scope ($out) [NEW]"
    fi

    out="$(run_bash_guard \
        "git -C \"$repoB_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$parent_norm")"
    if guard_decision "$out"; then
        pass "N1: parent dir scan — repoB reachable via git -C, gh write allows [NEW]"
    else
        fail "N1: parent dir scan — repoB should be in scope ($out) [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# N2 [NEW] — Mixed: individual repo path + parent dir in EXTRA_REPOS.
# ─────────────────────────────────────────────────────────────────────────────
test_N2_mixed_individual_and_parent() {
    require_guard "N2" || return

    # Individual extra repo (main checkout — direct entry, not via dir-scan).
    local main_individual="$TMPDIR_BASE/N2-individual"
    make_git_repo "$main_individual"

    # Parent dir containing another repo.
    local parent="$TMPDIR_BASE/N2-parent-$$"
    make_parent_with_repos "$parent" "child"

    # Session anchor: unrelated repo. CWD here; targets reached via git -C.
    local pair_session; pair_session="$(setup_linked_worktree "N2-session")"
    local wt_session="${pair_session#*|}"

    local individual_norm; individual_norm="$(norm_path "$main_individual")"
    local parent_norm; parent_norm="$(norm_path "$parent")"
    local child_norm; child_norm="$(norm_path "$parent/child")"
    local extras="$individual_norm;$parent_norm"

    local out
    # Individual entry (direct, not dir-scan).
    out="$(run_bash_guard \
        "git -C \"$individual_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "N2: mixed — individual repo (direct entry) in scope, allows [NEW]"
    else
        fail "N2: mixed — individual repo should be in scope ($out) [NEW]"
    fi

    # Child reached via parent dir-scan.
    out="$(run_bash_guard \
        "git -C \"$child_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "N2: mixed — child-via-parent scan in scope, allows [NEW]"
    else
        fail "N2: mixed — child-via-parent scan should be in scope ($out) [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# N3 [NEW] — Spaces after comma in EXTRA_REPOS trimmed correctly.
#            e.g. "repoA, parentDir" — space before parentDir must be stripped.
# ─────────────────────────────────────────────────────────────────────────────
test_N3_space_after_comma_trimmed() {
    require_guard "N3" || return

    local main_a="$TMPDIR_BASE/N3-repoA"
    make_git_repo "$main_a"

    local parent="$TMPDIR_BASE/N3-parent-$$"
    make_parent_with_repos "$parent" "child"

    local pair_session; pair_session="$(setup_linked_worktree "N3-session")"
    local wt_session="${pair_session#*|}"

    local a_norm; a_norm="$(norm_path "$main_a")"
    local parent_norm; parent_norm="$(norm_path "$parent")"
    local child_norm; child_norm="$(norm_path "$parent/child")"
    # Intentional spaces around semicolon-separated entries.
    local extras=" $a_norm ; $parent_norm "

    local out
    out="$(run_bash_guard \
        "git -C \"$child_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "N3: space-after-comma trimmed — child-via-parent in scope [NEW]"
    else
        fail "N3: space-after-comma — child-via-parent should be in scope ($out) [NEW]"
    fi

    out="$(run_bash_guard \
        "git -C \"$a_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "N3: space-after-comma trimmed — repoA (direct) still in scope [NEW]"
    else
        fail "N3: space-after-comma — repoA should be in scope ($out) [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# N4 [NEW] — Parent dir with no git repos in subdirs → no-op, no error.
# ─────────────────────────────────────────────────────────────────────────────
test_N4_parent_with_no_git_repos_noop() {
    require_guard "N4" || return

    local parent="$TMPDIR_BASE/N4-empty-parent-$$"
    mkdir -p "$parent/subdir1" "$parent/subdir2"
    # No git repos inside — only plain directories.

    local pair; pair="$(setup_linked_worktree "N4-session")"
    local wt="${pair#*|}"

    local parent_norm; parent_norm="$(norm_path "$parent")"

    # Guard must still function — session wt is in scope → allow.
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$parent_norm")"
    if guard_decision "$out"; then
        pass "N4: parent with no git repos — no-op, session wt still allowed [NEW]"
    else
        # Could block because wt is still in session scope via CWD.
        # A block here would mean CWD repo not detected — that's a bug in base code.
        fail "N4: parent with no git repos — session wt should still be allowed ($out) [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# N5 [NEW] — Parent dir has git repos AND non-git dirs → only git repos added.
# ─────────────────────────────────────────────────────────────────────────────
test_N5_parent_mixed_git_and_nongit() {
    require_guard "N5" || return

    local parent="$TMPDIR_BASE/N5-parent-$$"
    make_parent_with_repos "$parent" "git-repo"
    mkdir -p "$parent/plain-dir" "$parent/another-plain"

    local pair_session; pair_session="$(setup_linked_worktree "N5-session")"
    local wt_session="${pair_session#*|}"

    local parent_norm; parent_norm="$(norm_path "$parent")"
    local gitrepo_norm; gitrepo_norm="$(norm_path "$parent/git-repo")"

    # Git-repo subdir should be reachable via dir-scan; non-git plain dirs are skipped.
    local out; out="$(run_bash_guard \
        "git -C \"$gitrepo_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$parent_norm")"
    if guard_decision "$out"; then
        pass "N5: mixed parent — git repo subdir in scope [NEW]"
    else
        fail "N5: mixed parent — git repo subdir should be in scope ($out) [NEW]"
    fi

    # Guard must not crash due to plain dirs in the parent.
    local crash_check; crash_check="$(run_bash_guard "gh pr merge 1" "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$parent_norm" 2>&1)"
    if echo "$crash_check" | grep -qiE 'unhandled|throw|Error:|TypeError'; then
        fail "N5: mixed parent — guard threw an error ($crash_check) [NEW]"
    else
        pass "N5: mixed parent — guard did not crash on plain subdirs [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# E1 [EXISTING] — Nonexistent path silently skipped; guard still functions.
# ─────────────────────────────────────────────────────────────────────────────
test_E1_nonexistent_path_silently_skipped() {
    require_guard "E1" || return

    local pair; pair="$(setup_linked_worktree "E1-session")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local valid_norm; valid_norm="$(norm_path "$main")"

    local extras="/totally/nonexistent/path/$$;$valid_norm"
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    if guard_decision "$out"; then
        pass "E1: nonexistent path silently skipped, valid entry still works [EXISTING]"
    else
        fail "E1: nonexistent path should be skipped; valid entry should allow ($out) [EXISTING]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# E2 [EXISTING] — EXTRA_REPOS empty/unset → only CWD repo in scope.
# ─────────────────────────────────────────────────────────────────────────────
test_E2_extra_repos_unset_only_cwd() {
    require_guard "E2" || return

    local pair; pair="$(setup_linked_worktree "E2-session")"
    local wt="${pair#*|}"

    # With EXTRA_REPOS empty — CWD is the session wt, which IS a worktree → allow.
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=")"
    if guard_decision "$out"; then
        pass "E2: EXTRA_REPOS='', cwd session wt allows [EXISTING]"
    else
        fail "E2: EXTRA_REPOS='', cwd session wt should allow ($out) [EXISTING]"
    fi

    # Without the env var at all (don't pass it) — same expectation.
    out="$(run_bash_guard "gh pr merge 1" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "E2: EXTRA_REPOS unset, cwd session wt allows [EXISTING]"
    else
        fail "E2: EXTRA_REPOS unset, cwd session wt should allow ($out) [EXISTING]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# E3 [EXISTING] — File path (not a directory) in EXTRA_REPOS → silently skipped.
# ─────────────────────────────────────────────────────────────────────────────
test_E3_file_path_silently_skipped() {
    require_guard "E3" || return

    local pair; pair="$(setup_linked_worktree "E3-session")"
    local main="${pair%|*}"; local wt="${pair#*|}"

    # A real file inside the main repo.
    local file_path="$main/README.md"
    local file_norm; file_norm="$(norm_path "$file_path")"
    local main_norm; main_norm="$(norm_path "$main")"

    # file_path is not a git repo root → current code: resolveRepoRoot(file_path)
    # would cd to the file itself which may or may not fail — either way, the
    # feature wt (CWD) is always in scope via CWD root, so guard should allow.
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$file_norm;$main_norm")"
    if guard_decision "$out"; then
        pass "E3: file path in EXTRA_REPOS skipped, valid entry still works [EXISTING]"
    else
        fail "E3: file path should be skipped/handled; valid entry should allow ($out) [EXISTING]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# E4 [EXISTING] — Empty directory as parent → no repos found, no error.
# ─────────────────────────────────────────────────────────────────────────────
test_E4_empty_dir_no_repos_no_error() {
    require_guard "E4" || return

    local empty_dir="$TMPDIR_BASE/E4-empty-$$"
    mkdir -p "$empty_dir"

    local pair; pair="$(setup_linked_worktree "E4-session")"
    local wt="${pair#*|}"

    local empty_norm; empty_norm="$(norm_path "$empty_dir")"

    # With an empty dir as EXTRA_REPOS: no repos discovered. CWD is session wt → allow.
    local out; out="$(run_bash_guard "gh pr merge 1" "$wt" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$empty_norm")"
    if guard_decision "$out"; then
        pass "E4: empty dir in EXTRA_REPOS — no error, session wt still allows [EXISTING]"
    else
        fail "E4: empty dir should be handled gracefully; session wt should allow ($out) [EXISTING]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# IDEM1 [EXISTING] — Same parent dir listed twice → repos added only once (Set dedup).
# ─────────────────────────────────────────────────────────────────────────────
test_IDEM1_duplicate_parent_deduped() {
    require_guard "IDEM1" || return

    local parent="$TMPDIR_BASE/IDEM1-parent-$$"
    make_parent_with_repos "$parent" "repo1"

    local pair_session; pair_session="$(setup_linked_worktree "IDEM1-session")"
    local wt_session="${pair_session#*|}"

    local parent_norm; parent_norm="$(norm_path "$parent")"
    local repo1_norm; repo1_norm="$(norm_path "$parent/repo1")"
    # List the same parent twice.
    local extras="$parent_norm;$parent_norm"

    # Two runs must produce identical output (no duplication side-effects).
    local out1 out2
    out1="$(run_bash_guard \
        "git -C \"$repo1_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"
    out2="$(run_bash_guard \
        "git -C \"$repo1_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$extras")"

    if [ "$out1" = "$out2" ]; then
        pass "IDEM1: duplicate parent — identical output (Set dedup, idempotent) [NEW]"
    else
        fail "IDEM1: duplicate parent — outputs differ (out1=$out1 out2=$out2) [NEW]"
    fi

    # Also verify that repo1 is actually in scope (new dir-scan behaviour).
    if guard_decision "$out1"; then
        pass "IDEM1: duplicate parent — repo1 in scope, allows [NEW]"
    else
        fail "IDEM1: duplicate parent — repo1 should be in scope ($out1) [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SEC1 [EXISTING] — Shell metacharacters in EXTRA_REPOS path → not shell-executed.
# ─────────────────────────────────────────────────────────────────────────────
test_SEC1_metacharacters_not_shell_executed() {
    require_guard "SEC1" || return

    local pair; pair="$(setup_linked_worktree "SEC1-session")"
    local wt="${pair#*|}"
    local sentinel="$TMPDIR_BASE/sec1-injected-$$"

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
            fail "SEC1: metachar '$p' was shell-executed [EXISTING]"
            rm -rf "$sentinel" 2>/dev/null
        else
            pass "SEC1: metachar '$p' not executed [EXISTING]"
        fi
        # Output must be well-formed JSON or empty — no crash.
        if [ -n "$out" ] && ! echo "$out" | grep -qE '^\{.*\}$'; then
            fail "SEC1: metachar '$p' produced malformed output ($out) [EXISTING]"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# INT1 [NEW] — EXTRA_REPOS=parent-dir, gh pr merge targeting subdir repo → allowed.
#              Tests via git -C indirection so detected repo is the subdir repo.
# ─────────────────────────────────────────────────────────────────────────────
test_INT1_extra_repos_parent_gh_merge_allowed() {
    require_guard "INT1" || return

    local parent="$TMPDIR_BASE/INT1-parent-$$"
    make_parent_with_repos "$parent" "target-repo"

    local pair_session; pair_session="$(setup_linked_worktree "INT1-session")"
    local wt_session="${pair_session#*|}"

    local parent_norm; parent_norm="$(norm_path "$parent")"
    local target_norm; target_norm="$(norm_path "$parent/target-repo")"

    # Use git -C to make detected repo = target-repo inside parent.
    # With EXTRA_REPOS=parent, dir-scan should add target-repo → allow.
    local out; out="$(run_bash_guard \
        "git -C \"$target_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXTRA_REPOS=$parent_norm")"
    if guard_decision "$out"; then
        pass "INT1: EXTRA_REPOS=parent, gh pr merge targeting subdir repo allows [NEW]"
    else
        fail "INT1: EXTRA_REPOS=parent, subdir repo should be in scope ($out) [NEW]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INT2 [EXISTING] — EXTRA_REPOS not set, gh pr merge targeting different repo via
#                   git -C → blocked (regression guard for existing behaviour).
# ─────────────────────────────────────────────────────────────────────────────
test_INT2_no_extra_repos_git_C_different_repo_blocked() {
    require_guard "INT2" || return

    local pair_session; pair_session="$(setup_linked_worktree "INT2-session")"
    local wt_session="${pair_session#*|}"

    local pair_target; pair_target="$(setup_linked_worktree "INT2-target")"
    local wt_target="${pair_target#*|}"
    local target_norm; target_norm="$(norm_path "$wt_target")"

    # Without EXTRA_REPOS, target is out of session scope → should block.
    local out; out="$(run_bash_guard \
        "git -C \"$target_norm\" rev-parse HEAD && gh pr merge 1" \
        "$wt_session" \
        ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "INT2: no EXTRA_REPOS, out-of-scope target should be blocked ($out) [EXISTING]"
    else
        pass "INT2: no EXTRA_REPOS, out-of-scope target via git -C blocked [EXISTING]"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

# Normal cases (new dir-scan behaviour — expected RED until implemented)
test_N1_parent_dir_two_repos_allowed
test_N2_mixed_individual_and_parent
test_N3_space_after_comma_trimmed
test_N4_parent_with_no_git_repos_noop
test_N5_parent_mixed_git_and_nongit

# Error cases (existing behaviour — must pass now)
test_E1_nonexistent_path_silently_skipped
test_E2_extra_repos_unset_only_cwd
test_E3_file_path_silently_skipped
test_E4_empty_dir_no_repos_no_error

# Idempotency (IDEM1 has dir-scan component — expected RED for allow assertion)
test_IDEM1_duplicate_parent_deduped

# Security (existing — must pass now)
test_SEC1_metacharacters_not_shell_executed

# Integration (INT1 new, INT2 existing)
test_INT1_extra_repos_parent_gh_merge_allowed
test_INT2_no_extra_repos_git_C_different_repo_blocked

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
