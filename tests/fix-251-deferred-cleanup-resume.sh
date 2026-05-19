#!/bin/bash
# tests/fix-251-deferred-cleanup-resume.sh
#
# Tests for bin/worktree-end-resume-load.js (deferred-cleanup resume path).
# Covers: no-marker no-op, valid marker happy path, malformed marker abort,
# already-removed worktree ("not a working tree") partial-cleanup,
# marker cleanup after success.
#
# All tests are expected to FAIL until PR2 creates bin/worktree-end-resume-load.js.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix-251-resume-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

cwd_unlock_marker_path_for() {
    local repo="$1" branch="$2"
    node -e "
      const crypto = require('crypto');
      const path = require('path');
      const { spawnSync } = require('child_process');
      const repo = process.argv[1];
      const branch = process.argv[2];
      const plans = process.env.WORKFLOW_PLANS_DIR;
      const r = spawnSync('git', ['rev-parse', '--git-common-dir'],
        { cwd: repo, encoding: 'utf8' });
      const common = path.resolve(repo, r.stdout.trim());
      const id = crypto.createHash('sha256').update(common).digest('hex').slice(0,16);
      const enc = encodeURIComponent(branch);
      const p = path.join(plans, 'worktree-end', 'pending-cwd-unlock-' + id + '--' + enc);
      console.log(p.replace(/\\\\/g, '/'));
    " -- "$repo" "$branch" 2>/dev/null
}

branch_delete_marker_path_for() {
    local repo="$1" branch="$2"
    node -e "
      const crypto = require('crypto');
      const path = require('path');
      const { spawnSync } = require('child_process');
      const repo = process.argv[1];
      const branch = process.argv[2];
      const plans = process.env.WORKFLOW_PLANS_DIR;
      const r = spawnSync('git', ['rev-parse', '--git-common-dir'],
        { cwd: repo, encoding: 'utf8' });
      const common = path.resolve(repo, r.stdout.trim());
      const id = crypto.createHash('sha256').update(common).digest('hex').slice(0,16);
      const enc = encodeURIComponent(branch);
      const p = path.join(plans, 'worktree-end', 'pending-branch-delete-' + id + '--' + enc);
      console.log(p.replace(/\\\\/g, '/'));
    " -- "$repo" "$branch" 2>/dev/null
}

call_resume_load() {
    local repo="$1" wbase="$2" plans_dir="$3"
    (cd "$repo" && WORKFLOW_PLANS_DIR="$plans_dir" WORKTREE_BASE_DIR="$wbase" \
        run_with_timeout 30 node "${_AGENTS_DIR_NODE}/bin/worktree-end-resume-load.js" \
        --plans-dir "$plans_dir" 2>&1)
}

setup_minimal_repo() {
    mkdir -p "$1"
    git -c user.email=t@example.com -c user.name=t -C "$1" init -q -b main .
    git -c user.email=t@example.com -c user.name=t -C "$1" commit --allow-empty --no-verify -q -m init
}

write_cwd_unlock_marker() {
    local repo="$1" branch="$2" wbase="$3" plans="$4"
    local marker
    marker="$(WORKFLOW_PLANS_DIR="$plans" cwd_unlock_marker_path_for "$repo" "$branch")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n%s\n' "$branch" "$wbase/$(echo "$branch" | tr '/' '-')-wt" "pre-remove" > "$marker"
    echo "$marker"
}

write_branch_delete_marker() {
    local repo="$1" branch="$2" wbase="$3" plans="$4"
    local marker
    marker="$(WORKFLOW_PLANS_DIR="$plans" branch_delete_marker_path_for "$repo" "$branch")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n' "$branch" "$wbase/$(echo "$branch" | tr '/' '-')-wt" > "$marker"
    echo "$marker"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

R1_no_marker_exit0() {
    local repo="$TMPDIR_BASE/r1-repo"
    local wbase="$TMPDIR_BASE/r1-wbase"
    local plans="$TMPDIR_BASE/r1-plans"
    setup_minimal_repo "$repo"
    local out ec
    out="$(call_resume_load "$repo" "$wbase" "$plans" 2>&1)"
    ec=$?
    [ "$ec" -eq 0 ] && pass "R1 no_marker_exit0" || fail "R1 no_marker_exit0 (exit $ec): $out"
}

R2_not_registered_worktree_cleanup() {
    local repo="$TMPDIR_BASE/r2-repo"
    local wbase="$TMPDIR_BASE/r2-wbase"
    local plans="$TMPDIR_BASE/r2-plans"
    setup_minimal_repo "$repo"
    local cwd_marker bd_marker
    cwd_marker="$(WORKFLOW_PLANS_DIR="$plans" write_cwd_unlock_marker "$repo" "fix/foo" "$wbase" "$plans")"
    bd_marker="$(WORKFLOW_PLANS_DIR="$plans" write_branch_delete_marker "$repo" "fix/foo" "$wbase" "$plans")"
    local out ec
    out="$(call_resume_load "$repo" "$wbase" "$plans" 2>&1)"
    ec=$?
    if [ "$ec" -ne 0 ]; then
        fail "R2 not_registered_worktree_cleanup (exit $ec): $out"
        return
    fi
    if [ -f "$cwd_marker" ]; then
        fail "R2 cwd_unlock_marker not deleted after resume"
    elif [ -f "$bd_marker" ]; then
        fail "R2 branch_delete_marker not deleted after resume"
    else
        pass "R2 not_registered_worktree_cleanup"
    fi
}

R3_idempotent_double_resume() {
    local repo="$TMPDIR_BASE/r3-repo"
    local wbase="$TMPDIR_BASE/r3-wbase"
    local plans="$TMPDIR_BASE/r3-plans"
    setup_minimal_repo "$repo"
    WORKFLOW_PLANS_DIR="$plans" write_cwd_unlock_marker "$repo" "fix/foo" "$wbase" "$plans" > /dev/null
    WORKFLOW_PLANS_DIR="$plans" write_branch_delete_marker "$repo" "fix/foo" "$wbase" "$plans" > /dev/null
    # First run — should succeed
    call_resume_load "$repo" "$wbase" "$plans" > /dev/null 2>&1
    # Second run — marker gone, should exit 0 (no-op)
    local out ec
    out="$(call_resume_load "$repo" "$wbase" "$plans" 2>&1)"
    ec=$?
    [ "$ec" -eq 0 ] && pass "R3 idempotent_double_resume" || fail "R3 idempotent_double_resume (exit $ec): $out"
}

R4_malformed_marker_abort() {
    local repo="$TMPDIR_BASE/r4-repo"
    local wbase="$TMPDIR_BASE/r4-wbase"
    local plans="$TMPDIR_BASE/r4-plans"
    setup_minimal_repo "$repo"
    local marker
    marker="$(WORKFLOW_PLANS_DIR="$plans" cwd_unlock_marker_path_for "$repo" "fix/foo")"
    mkdir -p "$(dirname "$marker")"
    printf 'fix/foo\n' > "$marker"  # only 1 line — malformed
    local out ec
    out="$(call_resume_load "$repo" "$wbase" "$plans" 2>&1)"
    ec=$?
    if [ "$ec" -eq 0 ]; then
        fail "R4 malformed_marker_abort (should have failed, but exit 0): $out"
    elif echo "$out" | grep -qi "malformed\|ERROR\|invalid"; then
        pass "R4 malformed_marker_abort"
    else
        fail "R4 malformed_marker_abort (non-zero exit but no expected message): $out"
    fi
}

R5_unknown_stage_abort() {
    local repo="$TMPDIR_BASE/r5-repo"
    local wbase="$TMPDIR_BASE/r5-wbase"
    local plans="$TMPDIR_BASE/r5-plans"
    setup_minimal_repo "$repo"
    local marker
    marker="$(WORKFLOW_PLANS_DIR="$plans" cwd_unlock_marker_path_for "$repo" "fix/foo")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n%s\n' "fix/foo" "$wbase/foo-wt" "future-stage-v2" > "$marker"
    local out ec
    out="$(call_resume_load "$repo" "$wbase" "$plans" 2>&1)"
    ec=$?
    if [ "$ec" -eq 0 ]; then
        fail "R5 unknown_stage_abort (should have failed, but exit 0): $out"
    elif echo "$out" | grep -qi "unknown\|not supported\|ERROR"; then
        pass "R5 unknown_stage_abort"
    else
        fail "R5 unknown_stage_abort (non-zero exit but no expected message): $out"
    fi
}

R6_path_outside_base_abort() {
    local repo="$TMPDIR_BASE/r6-repo"
    local wbase="$TMPDIR_BASE/r6-wbase"
    local plans="$TMPDIR_BASE/r6-plans"
    setup_minimal_repo "$repo"
    local marker
    marker="$(WORKFLOW_PLANS_DIR="$plans" cwd_unlock_marker_path_for "$repo" "fix/foo")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n%s\n' "fix/foo" "/etc/passwd" "pre-remove" > "$marker"
    local out ec
    out="$(call_resume_load "$repo" "$wbase" "$plans" 2>&1)"
    ec=$?
    if [ "$ec" -eq 0 ]; then
        fail "R6 path_outside_base_abort (should have failed, but exit 0): $out"
    elif echo "$out" | grep -qi "outside\|ERROR\|invalid"; then
        pass "R6 path_outside_base_abort"
    else
        fail "R6 path_outside_base_abort (non-zero exit but no expected message): $out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

R1_no_marker_exit0
R2_not_registered_worktree_cleanup
R3_idempotent_double_resume
R4_malformed_marker_abort
R5_unknown_stage_abort
R6_path_outside_base_abort

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
