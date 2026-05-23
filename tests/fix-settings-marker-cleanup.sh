#!/bin/bash
# tests/fix-settings-marker-cleanup.sh
#
# Tests for the marker-file cleanup exemption in hooks/enforce-worktree.js.
# After /worktree-end deletes the branch (gated by the existing marker), the
# marker file itself must be deletable from the main worktree. This is
# authorised by `isAllowedMarkerDelete(cmd, repoRoot)`.
#
# Markers live at <plans>/worktree-end/pending-branch-delete-<repo-id>--<encoded-branch>
# where <plans> = $WORKFLOW_PLANS_DIR or ~/.workflow-plans (outside .git/ to avoid
# Claude Code's protected-path prompt on every write).
#
# Module contract under test (hooks/enforce-worktree.js exports):
#   isAllowedMarkerDelete(cmd, repoRoot) -> bool
#   isMarkerFilePath(filePath, repoRoot) -> bool
# Plus classifier stability (existing behaviour):
#   classify('rm "<marker_path>"')          -> "write"
#   classify('Remove-Item -LiteralPath ...') -> "write"
#
# Predicate tests (T1–T14) are expected to FAIL with
#   ERROR: m.isAllowedMarkerDelete is not a function
# until the source implements/exports the predicate. The classifier-stability
# tests (T17–T18) and e2e block tests (T15–T16) should PASS today.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
PATTERNS_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"
HOOK_SCRIPT="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

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
const d=path.join(os.tmpdir(),'settings-marker-cleanup-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Each test sets WORKFLOW_PLANS_DIR to an isolated per-test dir under TMPDIR_BASE.

# ─────────────────────────────────────────────────────────────────────────────
# Caller helpers
# ─────────────────────────────────────────────────────────────────────────────

call_isAllowedMarkerDelete() {
    # args: cmd, repoRoot
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.isAllowedMarkerDelete(process.argv[1], process.argv[2])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" "$2" 2>/dev/null
}

call_classify() {
    run_with_timeout 30 node -e "
      try {
        const { classify } = require('$PATTERNS_MODULE');
        console.log(classify(process.argv[1]));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

run_hook() {
    local payload="$1" cwd="$2"
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 node "$HOOK_SCRIPT" 2>&1)
}

hook_payload_bash() {
    local cmd="$1"
    node -e "
      const c = process.argv[1];
      console.log(JSON.stringify({tool_name:'Bash', tool_input:{command:c}}));
    " -- "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup helpers
# ─────────────────────────────────────────────────────────────────────────────

# Marker path string for the ~/.workflow-plans/worktree-end/ location.
# Args: repo, branch
# Uses the repo's git-common-dir sha1-12 as the repo-id component.
# Requires WORKFLOW_PLANS_DIR to be exported before calling.
marker_path_for() {
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

call_getMarkerPath() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(m.getMarkerPath(process.argv[1], process.argv[2]));
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$1" "$2" 2>/dev/null
}

setup_repo_branch_gone() {
    # branch absent, marker present
    local repo="$1" branch="$2" wtree="$3"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    local marker
    marker="$(marker_path_for "$repo" "$branch")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n' "$branch" "$wtree" > "$marker"
    # No branch creation — branch is "gone"
}

setup_repo_branch_present() {
    # branch exists, marker present
    local repo="$1" branch="$2" wtree="$3"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init && \
        git -c user.email=t@example.com -c user.name=t branch "$branch")
    local marker
    marker="$(marker_path_for "$repo" "$branch")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n' "$branch" "$wtree" > "$marker"
}

setup_repo_git_broken() {
    # marker present, .git/HEAD corrupted → git show-ref exits 128
    # IMPORTANT: marker_path_for is called BEFORE corrupting HEAD.
    local repo="$1" branch="$2" wtree="$3"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    local marker
    marker="$(marker_path_for "$repo" "$branch")"
    mkdir -p "$(dirname "$marker")"
    printf '%s\n%s\n' "$branch" "$wtree" > "$marker"
    # Corrupt HEAD so subsequent git plumbing calls fail
    printf 'this is not a valid ref pointer\n' > "$repo/.git/HEAD"
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit — predicate positive (T1, T2)
# ─────────────────────────────────────────────────────────────────────────────

T1_marker_delete_allowed_posix() {
    local repo="$TMPDIR_BASE/t1-repo"
    local wbase="$TMPDIR_BASE/t1-wbase"
    local plans="$TMPDIR_BASE/t1-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "true" ] && pass "T1 marker_delete_allowed_posix" \
                     || fail "T1 marker_delete_allowed_posix == $r"
}

T2_marker_delete_allowed_pwsh_litpath() {
    local repo="$TMPDIR_BASE/t2-repo"
    local wbase="$TMPDIR_BASE/t2-wbase"
    local plans="$TMPDIR_BASE/t2-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -LiteralPath \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "true" ] && pass "T2 marker_delete_allowed_pwsh_litpath" \
                     || fail "T2 marker_delete_allowed_pwsh_litpath == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit — predicate negative (T3–T13)
# ─────────────────────────────────────────────────────────────────────────────

T3_marker_delete_blocked_branch_exists() {
    local repo="$TMPDIR_BASE/t3-repo"
    local wbase="$TMPDIR_BASE/t3-wbase"
    local plans="$TMPDIR_BASE/t3-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_present "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T3 marker_delete_blocked_branch_exists" \
                      || fail "T3 marker_delete_blocked_branch_exists == $r"
}

T4_marker_delete_blocked_target_mismatch() {
    local repo="$TMPDIR_BASE/t4-repo"
    local wbase="$TMPDIR_BASE/t4-wbase"
    local plans="$TMPDIR_BASE/t4-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    # Use wrong repo-id (16-char hex not matching this repo) — must be rejected.
    local other="$plans/worktree-end/pending-branch-delete-deadbeefdeadbeef--fix%2Ffoo"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$other\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T4 marker_delete_blocked_target_mismatch" \
                      || fail "T4 marker_delete_blocked_target_mismatch == $r"
}

T5_marker_delete_allowed_no_marker() {
    # Non-existent marker: deletion is a no-op, so it should be allowed.
    # This handles manual cleanup of stale markers from aborted /worktree-end runs.
    local repo="$TMPDIR_BASE/t5-repo"
    local plans="$TMPDIR_BASE/t5-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    # No marker file written.
    export WORKFLOW_PLANS_DIR="$plans"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$TMPDIR_BASE/t5-wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "true" ] && pass "T5 marker_delete_allowed_no_marker (no-op)" \
                     || fail "T5 marker_delete_allowed_no_marker == $r"
}

T6_marker_delete_blocked_chaining() {
    local repo="$TMPDIR_BASE/t6-repo"
    local wbase="$TMPDIR_BASE/t6-wbase"
    local plans="$TMPDIR_BASE/t6-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\" && rm -rf /" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T6 marker_delete_blocked_chaining" \
                      || fail "T6 marker_delete_blocked_chaining == $r"
}

T7_marker_delete_blocked_recursive_rm() {
    local repo="$TMPDIR_BASE/t7-repo"
    local wbase="$TMPDIR_BASE/t7-wbase"
    local plans="$TMPDIR_BASE/t7-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm -rf \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T7 marker_delete_blocked_recursive_rm" \
                      || fail "T7 marker_delete_blocked_recursive_rm == $r"
}

T7b_marker_delete_blocked_recursive_rm_short() {
    local repo="$TMPDIR_BASE/t7b-repo"
    local wbase="$TMPDIR_BASE/t7b-wbase"
    local plans="$TMPDIR_BASE/t7b-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm -r \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T7b marker_delete_blocked_recursive_rm_short" \
                      || fail "T7b marker_delete_blocked_recursive_rm_short == $r"
}

T8_marker_delete_blocked_recursive_ri_full() {
    local repo="$TMPDIR_BASE/t8-repo"
    local wbase="$TMPDIR_BASE/t8-wbase"
    local plans="$TMPDIR_BASE/t8-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -Recurse -LiteralPath \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T8 marker_delete_blocked_recursive_ri_full" \
                      || fail "T8 marker_delete_blocked_recursive_ri_full == $r"
}

T8b_marker_delete_blocked_recursive_ri_abbrev() {
    local repo="$TMPDIR_BASE/t8b-repo"
    local wbase="$TMPDIR_BASE/t8b-wbase"
    local plans="$TMPDIR_BASE/t8b-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -r -LiteralPath \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T8b marker_delete_blocked_recursive_ri_abbrev" \
                      || fail "T8b marker_delete_blocked_recursive_ri_abbrev == $r"
}

T9_marker_delete_blocked_pwsh_path_wildcard() {
    local repo="$TMPDIR_BASE/t9-repo"
    local wbase="$TMPDIR_BASE/t9-wbase"
    local plans="$TMPDIR_BASE/t9-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -Path \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T9 marker_delete_blocked_pwsh_path_wildcard" \
                      || fail "T9 marker_delete_blocked_pwsh_path_wildcard == $r"
}

T10_marker_delete_blocked_extra_positional_rm() {
    local repo="$TMPDIR_BASE/t10-repo"
    local wbase="$TMPDIR_BASE/t10-wbase"
    local plans="$TMPDIR_BASE/t10-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\" README.md" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T10 marker_delete_blocked_extra_positional_rm" \
                      || fail "T10 marker_delete_blocked_extra_positional_rm == $r"
}

T11_marker_delete_blocked_extra_positional_ri() {
    local repo="$TMPDIR_BASE/t11-repo"
    local wbase="$TMPDIR_BASE/t11-wbase"
    local plans="$TMPDIR_BASE/t11-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -LiteralPath \"$marker\" README.md" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T11 marker_delete_blocked_extra_positional_ri" \
                      || fail "T11 marker_delete_blocked_extra_positional_ri == $r"
}

T12_marker_delete_blocked_ri_array() {
    local repo="$TMPDIR_BASE/t12-repo"
    local wbase="$TMPDIR_BASE/t12-wbase"
    local plans="$TMPDIR_BASE/t12-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -LiteralPath \"$marker\",\"other\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T12 marker_delete_blocked_ri_array" \
                      || fail "T12 marker_delete_blocked_ri_array == $r"
}

T13_marker_delete_failclosed_git_fatal() {
    local repo="$TMPDIR_BASE/t13-repo"
    local wbase="$TMPDIR_BASE/t13-wbase"
    local plans="$TMPDIR_BASE/t13-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_git_broken "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T13 marker_delete_failclosed_git_fatal" \
                      || fail "T13 marker_delete_failclosed_git_fatal == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# E2E — full hook (T14–T16)
# ─────────────────────────────────────────────────────────────────────────────

T14_e2e_hook_allows_from_main() {
    local repo="$TMPDIR_BASE/t14-repo"
    local wbase="$TMPDIR_BASE/t14-wbase"
    local plans="$TMPDIR_BASE/t14-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local payload out
    payload="$(hook_payload_bash "rm \"$marker\"")"
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
    unset WORKFLOW_PLANS_DIR
    case "$out" in
        *"\"decision\":\"block\""*) fail "T14 e2e_hook_allows_from_main blocked: $out" ;;
        *) pass "T14 e2e_hook_allows_from_main" ;;
    esac
}

T15_e2e_hook_blocks_unrelated_rm() {
    local repo="$TMPDIR_BASE/t15-repo"
    local wbase="$TMPDIR_BASE/t15-wbase"
    local plans="$TMPDIR_BASE/t15-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local payload out
    payload="$(hook_payload_bash "rm README.md")"
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
    unset WORKFLOW_PLANS_DIR
    case "$out" in
        *"\"decision\":\"block\""*) pass "T15 e2e_hook_blocks_unrelated_rm" ;;
        *) fail "T15 e2e_hook_blocks_unrelated_rm not blocked: $out" ;;
    esac
}

T16_e2e_hook_blocks_marker_branch_exists() {
    local repo="$TMPDIR_BASE/t16-repo"
    local wbase="$TMPDIR_BASE/t16-wbase"
    local plans="$TMPDIR_BASE/t16-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_present "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local payload out
    payload="$(hook_payload_bash "rm \"$marker\"")"
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
    unset WORKFLOW_PLANS_DIR
    case "$out" in
        *"\"decision\":\"block\""*) pass "T16 e2e_hook_blocks_marker_branch_exists" ;;
        *) fail "T16 e2e_hook_blocks_marker_branch_exists not blocked: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Classifier stability (T17–T18)
# ─────────────────────────────────────────────────────────────────────────────

T17_classify_rm_still_write() {
    local r
    r="$(call_classify 'rm "/tmp/.workflow-plans/worktree-end/pending-branch-delete-abc123def456--fix%2Ffoo"')"
    [ "$r" = "write" ] && pass "T17 classify_rm_still_write" \
                      || fail "T17 classify_rm_still_write == $r"
}

T18_classify_removeitem_still_write() {
    local r
    r="$(call_classify 'Remove-Item -LiteralPath "C:\Users\user\.workflow-plans\worktree-end\pending-branch-delete-abc123def456--fix%2Ffoo"')"
    [ "$r" = "write" ] && pass "T18 classify_removeitem_still_write" \
                      || fail "T18 classify_removeitem_still_write == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# T19–T21 (settings.json glob-pattern matching) removed.
# Previous T19–T21 verified that ~/.claude/settings.json contained allow patterns
# for the .git/info/pending-branch-delete path. With the marker moved out of
# the protected .git/ tree, no settings.json allow rule is needed and those
# rules are deleted in the implementation. The deletion is validated at
# code-review time rather than via a fragile relative-path test that would
# silently skip when the user-global settings file is absent.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# isMarkerFilePath (T22–T24) and Write/Edit hook exceptions (T25–T27)
# ─────────────────────────────────────────────────────────────────────────────

call_isMarkerFilePath() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.isMarkerFilePath(process.argv[1], process.argv[2])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" "$2" 2>/dev/null
}

hook_payload_write() {
    local fp="$1"
    node -e "
      const fp = process.argv[1];
      console.log(JSON.stringify({tool_name:'Write', tool_input:{file_path:fp}}));
    " -- "$fp"
}

hook_payload_edit() {
    local fp="$1"
    node -e "
      const fp = process.argv[1];
      console.log(JSON.stringify({tool_name:'Edit', tool_input:{file_path:fp}}));
    " -- "$fp"
}

T22_isMarkerFilePath_matches() {
    local repo="$TMPDIR_BASE/t22-repo"
    local plans="$TMPDIR_BASE/t22-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local marker
    marker="$(marker_path_for "$repo" "feature/test")"
    local r
    r="$(call_isMarkerFilePath "$marker" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "true" ] && pass "T22 isMarkerFilePath_matches" \
                     || fail "T22 isMarkerFilePath_matches == $r"
}

T23_isMarkerFilePath_wrong_repo_id() {
    local repo="$TMPDIR_BASE/t23-repo"
    local plans="$TMPDIR_BASE/t23-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    # All-zeros repo-id cannot match any real repo's sha256-16.
    local wrong_marker="$plans/worktree-end/pending-branch-delete-0000000000000000--feature%2Ftest"
    local r
    r="$(call_isMarkerFilePath "$wrong_marker" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T23 isMarkerFilePath_wrong_repo_id" \
                      || fail "T23 isMarkerFilePath_wrong_repo_id == $r"
}

T24_isMarkerFilePath_no_match_repo_file() {
    local repo="$TMPDIR_BASE/t24-repo"
    local plans="$TMPDIR_BASE/t24-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local r
    r="$(call_isMarkerFilePath "$repo/README.md" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "T24 isMarkerFilePath_no_match_repo_file" \
                      || fail "T24 isMarkerFilePath_no_match_repo_file == $r"
}

T25_e2e_hook_allows_write_to_marker() {
    local repo="$TMPDIR_BASE/t25-repo"
    local plans="$TMPDIR_BASE/t25-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local marker
    marker="$(marker_path_for "$repo" "feature/test")"
    local payload out
    payload="$(hook_payload_write "$marker")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    unset WORKFLOW_PLANS_DIR
    case "$out" in
        *"\"decision\":\"block\""*) fail "T25 e2e_hook_allows_write_to_marker blocked: $out" ;;
        *) pass "T25 e2e_hook_allows_write_to_marker" ;;
    esac
}

T26_e2e_hook_allows_edit_to_marker() {
    local repo="$TMPDIR_BASE/t26-repo"
    local plans="$TMPDIR_BASE/t26-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local marker
    marker="$(marker_path_for "$repo" "feature/test")"
    local payload out
    payload="$(hook_payload_edit "$marker")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    unset WORKFLOW_PLANS_DIR
    case "$out" in
        *"\"decision\":\"block\""*) fail "T26 e2e_hook_allows_edit_to_marker blocked: $out" ;;
        *) pass "T26 e2e_hook_allows_edit_to_marker" ;;
    esac
}

T27_e2e_hook_blocks_write_to_tracked_file() {
    local repo="$TMPDIR_BASE/t27-repo"
    local plans="$TMPDIR_BASE/t27-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local payload out
    payload="$(hook_payload_write "$repo/README.md")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    unset WORKFLOW_PLANS_DIR
    case "$out" in
        *"\"decision\":\"block\""*) pass "T27 e2e_hook_blocks_write_to_tracked_file" ;;
        *) fail "T27 e2e_hook_blocks_write_to_tracked_file not blocked: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# D1–D9 — PR1 backward compatibility + new prefix tests
# ─────────────────────────────────────────────────────────────────────────────

# D1 — getMarkerPath backward compat (default prefix = pending-branch-delete-)
# Expected: FAIL until PR1 exports getMarkerPath
D1_getMarkerPath_backward_compat() {
    local repo="$TMPDIR_BASE/d1-repo"
    local plans="$TMPDIR_BASE/d1-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local r
    r="$(call_getMarkerPath "$repo" "fix/foo")"
    unset WORKFLOW_PLANS_DIR
    case "$r" in
        *"pending-branch-delete-"*) pass "D1 getMarkerPath_backward_compat" ;;
        *) fail "D1 getMarkerPath_backward_compat == $r" ;;
    esac
}

# D2 — isMarkerFilePath backward compat (2-arg recognizes BRANCH_DELETE marker)
# Verifies the default-parameter behavior: omitting the 3rd `prefixes` arg
# still recognizes the legacy pending-branch-delete- marker.
D2_isMarkerFilePath_backward_compat() {
    local repo="$TMPDIR_BASE/d2-repo"
    local plans="$TMPDIR_BASE/d2-plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    export WORKFLOW_PLANS_DIR="$plans"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    r="$(call_isMarkerFilePath "$marker" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "true" ] && pass "D2 isMarkerFilePath_backward_compat" \
                     || fail "D2 isMarkerFilePath_backward_compat == $r"
}

# D3 — isAllowedMarkerDelete backward compat (2-arg, allows pending-branch-delete- rm)
D3_isAllowedMarkerDelete_backward_compat() {
    local repo="$TMPDIR_BASE/d3-repo"
    local wbase="$TMPDIR_BASE/d3-wbase"
    local plans="$TMPDIR_BASE/d3-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"
    local marker
    marker="$(marker_path_for "$repo" "fix/foo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "true" ] && pass "D3 isAllowedMarkerDelete_backward_compat" \
                     || fail "D3 isAllowedMarkerDelete_backward_compat == $r"
}

# D7 — Unknown prefix pending-foo- is blocked
# Must PASS in PR1: unknown prefixes are rejected by existing code
D7_unknown_prefix_blocked() {
    local repo="$TMPDIR_BASE/d7-repo"
    local wbase="$TMPDIR_BASE/d7-wbase"
    local plans="$TMPDIR_BASE/d7-plans"
    mkdir -p "$wbase/foo"
    export WORKFLOW_PLANS_DIR="$plans"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    local repo_id
    repo_id=$(node -e "
      const crypto=require('crypto'), path=require('path'), {spawnSync}=require('child_process');
      const r=spawnSync('git',['rev-parse','--git-common-dir'],{cwd:process.argv[1],encoding:'utf8'});
      const common=path.resolve(process.argv[1],r.stdout.trim());
      console.log(crypto.createHash('sha256').update(common).digest('hex').slice(0,16));
    " -- "$repo" 2>/dev/null)
    local bad_marker="$plans/worktree-end/pending-foo-${repo_id}--feature%2Ftest"
    mkdir -p "$(dirname "$bad_marker")"
    printf '%s\n%s\n' "feature/test" "$wbase/foo/agents" > "$bad_marker"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$bad_marker\"" "$repo")"
    unset WORKFLOW_PLANS_DIR
    [ "$r" = "false" ] && pass "D7 unknown_prefix_blocked" \
                      || fail "D7 unknown_prefix_blocked == $r"
}

# D9 — module.exports exposes MARKER_PREFIXES, getRepoId, getMarkerPath (PR1)
# Expected: FAIL until PR1 exports MARKER_PREFIXES, getRepoId, getMarkerPath
D9_module_exports_marker_api() {
    local r
    r=$(node -e "
      try {
        const m = require('$MODULE');
        const ok = typeof m.MARKER_PREFIXES === 'object' &&
                   typeof m.getRepoId === 'function' &&
                   typeof m.getMarkerPath === 'function';
        console.log(ok ? 'true' : 'false');
      } catch(e) { console.log('ERROR: ' + e.message); }
    " 2>/dev/null)
    [ "$r" = "true" ] && pass "D9 module_exports_marker_api" \
                     || fail "D9 module_exports_marker_api == $r"
}

# D10a — SKILL.md step 6b: old sha256 recipe absent AND new argv-safe snippet present
# Compound check: negative (old text gone) + positive (new text present)
# RED before commit 3: step6b_old_recipe_absent FAILS (old text still there)
#                    AND step6b_has_argv_require FAILS (new text not yet there)
# GREEN after commit 3: both sub-checks pass
D10a_skill_md_step6b_updated() {
    local skill="$AGENTS_DIR/skills/worktree-end/SKILL.md"
    # Negative: old sha256-of-raw-git-common-dir prescription must be gone
    ! grep -qF 'first 16 hex chars of sha256' "$skill" \
        && pass "D10a step6b_old_recipe_absent" \
        || fail "D10a step6b_old_recipe_absent: old sha256 prescription still present in SKILL.md"
    # Positive: new argv-safe getRepoId snippet must be present
    grep -qF 'require(process.argv[1])' "$skill" \
        && pass "D10a step6b_has_argv_require" \
        || fail "D10a step6b_has_argv_require: new getRepoId snippet not found in SKILL.md"
}

# D10b — old recipe (raw sha256 of git-common-dir) produces DIFFERENT id than getRepoId()
# Proves root cause: from main worktree, git-common-dir returns ".git" (relative);
# path.resolve() inside getRepoId() normalizes to absolute → different sha256.
# PASS in any environment where git rev-parse --git-common-dir is relative (i.e., ".git").
# Does NOT change with SKILL.md commits — validates the bug exists independently.
D10b_old_recipe_disagrees_with_getrepoid() {
    local repo="$AGENTS_DIR"
    local old_id
    old_id=$(run_with_timeout 30 node -e "
      const {execSync} = require('child_process');
      const crypto = require('crypto');
      const rawDir = execSync('git rev-parse --git-common-dir',
        {cwd: process.argv[1], encoding: 'utf8'}).trim();
      const hash = crypto.createHash('sha256').update(rawDir).digest('hex').slice(0, 16);
      console.log(hash);
    " -- "$repo" 2>/dev/null)
    local new_id
    new_id=$(run_with_timeout 30 node -e "
      const {getRepoId} = require(process.argv[1]);
      const id = getRepoId(process.argv[2]);
      if (!id) { process.stderr.write('getRepoId failed\n'); process.exit(1); }
      console.log(id);
    " -- "$MODULE" "$repo" 2>/dev/null)
    [ "$old_id" != "$new_id" ] \
        && pass "D10b old_recipe_disagrees_with_getrepoid: root cause confirmed" \
        || fail "D10b old_recipe_disagrees_with_getrepoid: IDs match — root cause not reproduced (git-common-dir already absolute?)"
}

# D10c — new SKILL.md recipe (node + getRepoId) agrees with validator (marker_path_for)
# Regression protection: writer and validator must produce the same repo-id.
# PASS from commit 1 onward (getRepoId already exported).
D10c_new_recipe_matches_validator() {
    local repo="$AGENTS_DIR"
    local plans="$TMPDIR_BASE/d10-plans"
    export WORKFLOW_PLANS_DIR="$plans"
    local validator_marker
    validator_marker="$(marker_path_for "$repo" "feature/test")"
    unset WORKFLOW_PLANS_DIR
    local validator_id
    validator_id=$(basename "$validator_marker" | sed 's/pending-branch-delete-//;s/--.*//')
    local writer_id
    writer_id=$(run_with_timeout 30 node -e "
      const {getRepoId} = require(process.argv[1]);
      const id = getRepoId(process.argv[2]);
      if (!id) { process.stderr.write('getRepoId failed\n'); process.exit(1); }
      console.log(id);
    " -- "$MODULE" "$repo" 2>/dev/null)
    [ "$writer_id" = "$validator_id" ] \
        && pass "D10c new_recipe_matches_validator" \
        || fail "D10c new_recipe_matches_validator: writer=$writer_id validator=$validator_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

T1_marker_delete_allowed_posix
T2_marker_delete_allowed_pwsh_litpath
T3_marker_delete_blocked_branch_exists
T4_marker_delete_blocked_target_mismatch
T5_marker_delete_allowed_no_marker
T6_marker_delete_blocked_chaining
T7_marker_delete_blocked_recursive_rm
T7b_marker_delete_blocked_recursive_rm_short
T8_marker_delete_blocked_recursive_ri_full
T8b_marker_delete_blocked_recursive_ri_abbrev
T9_marker_delete_blocked_pwsh_path_wildcard
T10_marker_delete_blocked_extra_positional_rm
T11_marker_delete_blocked_extra_positional_ri
T12_marker_delete_blocked_ri_array
T13_marker_delete_failclosed_git_fatal
T14_e2e_hook_allows_from_main
T15_e2e_hook_blocks_unrelated_rm
T16_e2e_hook_blocks_marker_branch_exists
T17_classify_rm_still_write
T18_classify_removeitem_still_write
T22_isMarkerFilePath_matches
T23_isMarkerFilePath_wrong_repo_id
T24_isMarkerFilePath_no_match_repo_file
T25_e2e_hook_allows_write_to_marker
T26_e2e_hook_allows_edit_to_marker
T27_e2e_hook_blocks_write_to_tracked_file
D1_getMarkerPath_backward_compat
D2_isMarkerFilePath_backward_compat
D3_isAllowedMarkerDelete_backward_compat
D7_unknown_prefix_blocked
D9_module_exports_marker_api
D10a_skill_md_step6b_updated
D10b_old_recipe_disagrees_with_getrepoid
D10c_new_recipe_matches_validator

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
