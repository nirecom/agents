#!/bin/bash
# Tests: hooks/pre-commit, hooks/enforce-worktree/shared-cmd-utils.js
# Tags: worktree, enforce, pre-commit, builtin, integration
#
# Integration tests driving the real hooks/pre-commit to verify that the
# built-in `**/.worktree-backup/**` exclude pattern (issue #654) allows
# .worktree-backup commits from the main worktree even when
# ENFORCE_WORKTREE_EXCLUDE is unset, while NOT over-matching unrelated paths.
#
# Run BEFORE source changes land → all cases FAIL (red phase) or SKIP if the
#   pre-commit hook has not yet been updated.
# Run AFTER  source changes land → all cases PASS.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRE_COMMIT="${AGENTS_DIR}/hooks/pre-commit"
SHARED_JS="${AGENTS_DIR}/hooks/enforce-worktree/shared-cmd-utils.js"

if [ ! -f "$PRE_COMMIT" ]; then
    echo "SKIP: hooks/pre-commit not present"
    exit 0
fi
if [ ! -f "$SHARED_JS" ]; then
    echo "SKIP: hooks/enforce-worktree/shared-cmd-utils.js not present"
    exit 0
fi

# Red-phase skip guard: both pre-commit and shared-cmd-utils must have been
# updated. If either marker is missing, the integration cases would fail in
# uninformative ways — skip cleanly so the runner doesn't conflate red phase
# with a regression.
if ! grep -q 'getExcludePatterns\|BUILTIN_EXCLUDE_PATTERNS' "$PRE_COMMIT" 2>/dev/null; then
    echo "SKIP: hooks/pre-commit not yet wired to getExcludePatterns / BUILTIN_EXCLUDE_PATTERNS (pre-implementation red phase)"
    exit 0
fi
if ! grep -q 'BUILTIN_EXCLUDE_PATTERNS' "$SHARED_JS" 2>/dev/null; then
    echo "SKIP: BUILTIN_EXCLUDE_PATTERNS not yet defined in shared-cmd-utils.js (pre-implementation red phase)"
    exit 0
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix-654-precommit-'+process.pid).replace(/\\\\/g,'/');
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

# Create a throwaway main worktree wired to the agents-repo pre-commit hook.
# Modeled on tests/feature-enforce-worktree-exclude.sh#setup_main_checkout.
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath "${AGENTS_DIR}/hooks"
    echo "init" > "$repo/README.md"
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1
    AGENTS_CONFIG_DIR="$AGENTS_DIR" ENFORCE_WORKTREE=off \
        git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "initial" >/dev/null 2>&1
    echo "$repo"
}

RUN_OUT=""
run_pre_commit() {
    local cwd="$1"; shift
    local rc=0
    RUN_OUT="$(cd "$cwd" && AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 env "$@" bash "$PRE_COMMIT" 2>&1)" || rc=$?
    return $rc
}

stage_file() {
    local repo="$1" rel="$2" content="$3"
    local full="$repo/$rel"
    mkdir -p "$(dirname "$full")"
    printf '%s\n' "$content" > "$full"
    git -C "$repo" -c core.hooksPath=/dev/null add "$rel" >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 1: builtin allows .worktree-backup/<branch>/file when env is unset
# ─────────────────────────────────────────────────────────────────────────────
test_case_1_builtin_allows_worktree_backup_subdir() {
    local repo; repo="$(setup_main_checkout "c1-builtin-subdir")"
    stage_file "$repo" ".worktree-backup/test-branch/notes.md" "backup notes"
    if run_pre_commit "$repo" ENFORCE_WORKTREE=on; then
        pass "Case 1: .worktree-backup/<branch>/file.md allowed (builtin, env unset)"
    else
        fail "Case 1: builtin must allow .worktree-backup/<branch>/file.md (out: $RUN_OUT)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 2: builtin allows file directly under .worktree-backup/ (no branch dir)
# (trailing /** matches zero segments)
# ─────────────────────────────────────────────────────────────────────────────
test_case_2_builtin_allows_no_branch_dir() {
    local repo; repo="$(setup_main_checkout "c2-builtin-flat")"
    stage_file "$repo" ".worktree-backup/file.md" "flat backup"
    if run_pre_commit "$repo" ENFORCE_WORKTREE=on; then
        pass "Case 2: .worktree-backup/file.md allowed (builtin, no branch dir)"
    else
        fail "Case 2: builtin must allow .worktree-backup/file.md (out: $RUN_OUT)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 3: regression — unrelated docs/notes.md must still BLOCK from main
# ─────────────────────────────────────────────────────────────────────────────
test_case_3_unrelated_still_blocked() {
    local repo; repo="$(setup_main_checkout "c3-unrelated")"
    stage_file "$repo" "docs/notes.md" "ordinary doc"
    if run_pre_commit "$repo" ENFORCE_WORKTREE=on; then
        fail "Case 3: docs/notes.md must still be BLOCKED from main (out: $RUN_OUT)"
    else
        pass "Case 3: docs/notes.md blocked (no over-match by builtin)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 4: partial-match — .worktree-backup file + unrelated doc → BLOCK
# (all-or-none semantics: one non-excluded staged file fails the gate)
# ─────────────────────────────────────────────────────────────────────────────
test_case_4_partial_match_blocks() {
    local repo; repo="$(setup_main_checkout "c4-partial")"
    stage_file "$repo" ".worktree-backup/x.md" "backup"
    stage_file "$repo" "docs/notes.md" "ordinary"
    if run_pre_commit "$repo" ENFORCE_WORKTREE=on; then
        fail "Case 4: mixed stage must block (one file not excluded) (out: $RUN_OUT)"
    else
        pass "Case 4: partial match blocks (all-or-none semantics preserved)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 5: user env pattern coexists with builtin
# ─────────────────────────────────────────────────────────────────────────────
test_case_5_user_env_coexists() {
    local repo; repo="$(setup_main_checkout "c5-user-env")"
    stage_file "$repo" ".worktree-backup/x.md" "backup"
    if run_pre_commit "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.tmp"; then
        pass "Case 5: builtin survives alongside user ENFORCE_WORKTREE_EXCLUDE=*.tmp"
    else
        fail "Case 5: user env must not displace builtin (out: $RUN_OUT)"
    fi
}

run_all() {
    test_case_1_builtin_allows_worktree_backup_subdir
    test_case_2_builtin_allows_no_branch_dir
    test_case_3_unrelated_still_blocked
    test_case_4_partial_match_blocks
    test_case_5_user_env_coexists
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX_654_PRECOMMIT_INNER:-}" ]; then
        _FIX_654_PRECOMMIT_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
