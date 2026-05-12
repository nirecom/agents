#!/bin/bash
# tests/fix-settings-marker-cleanup.sh
#
# Tests for the marker-file cleanup exemption in hooks/enforce-worktree.js.
# After /worktree-end deletes the branch (gated by the existing marker), the
# marker file itself must be deletable from the main worktree. This is
# authorised by a new predicate `isAllowedMarkerDelete(cmd, repoRoot)` plus
# matching settings.json allow entries for the step-6g cleanup command.
#
# Module contract under test (hooks/enforce-worktree.js exports):
#   isAllowedMarkerDelete(cmd, repoRoot) -> bool
# Plus classifier stability (existing behaviour):
#   classify('rm "<marker_path>"')          -> "write"
#   classify('Remove-Item -LiteralPath ...') -> "write"
# Plus settings.json glob-pattern matching for the new allow entries.
#
# Predicate tests (T1–T14) are expected to FAIL with
#   ERROR: m.isAllowedMarkerDelete is not a function
# until the source implements/exports the predicate. The classifier-stability
# tests (T17–T18), the e2e block tests (T15–T16), and the settings.json
# pattern-matching tests (T19–T21) should PASS today.

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
SETTINGS_JSON="${_AGENTS_DIR_NODE}/settings.json"

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

# Glob match helper that mimics Claude Code's permission-pattern matching:
# `*` matches any sequence of characters (including / and \). The full
# allow-rule string (e.g. `Bash(rm "...")`) is converted to an anchored regex.
glob_match() {
    local pattern="$1" candidate="$2"
    node -e "
      const pat = process.argv[1];
      const cand = process.argv[2];
      const re = new RegExp('^' + pat.replace(/[.+?^\${}()|[\\]\\\\]/g, '\\\\\$&').replace(/\\*/g, '.*') + '\$');
      process.stdout.write(re.test(cand) ? 'yes' : 'no');
    " -- "$pattern" "$candidate" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup helpers
# ─────────────────────────────────────────────────────────────────────────────

# Marker path string used in commands. Computed from the repo's .git/info dir.
# Uses forward slashes so the value is portable across POSIX and Windows tests.
marker_path_for() {
    local repo="$1"
    printf '%s/.git/info/pending-branch-delete' "$repo"
}

setup_repo_branch_gone() {
    # branch absent, marker present
    local repo="$1" branch="$2" wtree="$3"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    mkdir -p "$repo/.git/info"
    printf '%s\n%s\n' "$branch" "$wtree" > "$repo/.git/info/pending-branch-delete"
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
    mkdir -p "$repo/.git/info"
    printf '%s\n%s\n' "$branch" "$wtree" > "$repo/.git/info/pending-branch-delete"
}

setup_repo_git_broken() {
    # marker present, .git/HEAD corrupted → git show-ref exits 128
    local repo="$1" branch="$2" wtree="$3"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    mkdir -p "$repo/.git/info"
    printf '%s\n%s\n' "$branch" "$wtree" > "$repo/.git/info/pending-branch-delete"
    # Corrupt HEAD so subsequent git plumbing calls fail
    printf 'this is not a valid ref pointer\n' > "$repo/.git/HEAD"
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit — predicate positive (T1, T2)
# ─────────────────────────────────────────────────────────────────────────────

T1_marker_delete_allowed_posix() {
    local repo="$TMPDIR_BASE/t1-repo"
    local wbase="$TMPDIR_BASE/t1-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    [ "$r" = "true" ] && pass "T1 marker_delete_allowed_posix" \
                     || fail "T1 marker_delete_allowed_posix == $r"
}

T2_marker_delete_allowed_pwsh_litpath() {
    local repo="$TMPDIR_BASE/t2-repo"
    local wbase="$TMPDIR_BASE/t2-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -LiteralPath \"$marker\"" "$repo")"
    [ "$r" = "true" ] && pass "T2 marker_delete_allowed_pwsh_litpath" \
                     || fail "T2 marker_delete_allowed_pwsh_litpath == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit — predicate negative (T3–T13)
# ─────────────────────────────────────────────────────────────────────────────

T3_marker_delete_blocked_branch_exists() {
    local repo="$TMPDIR_BASE/t3-repo"
    local wbase="$TMPDIR_BASE/t3-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_present "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T3 marker_delete_blocked_branch_exists" \
                      || fail "T3 marker_delete_blocked_branch_exists == $r"
}

T4_marker_delete_blocked_target_mismatch() {
    local repo="$TMPDIR_BASE/t4-repo"
    local wbase="$TMPDIR_BASE/t4-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local other="$repo/.git/info/other"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$other\"" "$repo")"
    [ "$r" = "false" ] && pass "T4 marker_delete_blocked_target_mismatch" \
                      || fail "T4 marker_delete_blocked_target_mismatch == $r"
}

T5_marker_delete_allowed_no_marker() {
    # Non-existent marker: deletion is a no-op, so it should be allowed.
    # This handles manual cleanup of stale markers from aborted /worktree-end runs.
    local repo="$TMPDIR_BASE/t5-repo"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    # No marker file written.

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$TMPDIR_BASE/t5-wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    [ "$r" = "true" ] && pass "T5 marker_delete_allowed_no_marker (no-op)" \
                     || fail "T5 marker_delete_allowed_no_marker == $r"
}

T6_marker_delete_blocked_chaining() {
    local repo="$TMPDIR_BASE/t6-repo"
    local wbase="$TMPDIR_BASE/t6-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\" && rm -rf /" "$repo")"
    [ "$r" = "false" ] && pass "T6 marker_delete_blocked_chaining" \
                      || fail "T6 marker_delete_blocked_chaining == $r"
}

T7_marker_delete_blocked_recursive_rm() {
    local repo="$TMPDIR_BASE/t7-repo"
    local wbase="$TMPDIR_BASE/t7-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm -rf \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T7 marker_delete_blocked_recursive_rm" \
                      || fail "T7 marker_delete_blocked_recursive_rm == $r"
}

T7b_marker_delete_blocked_recursive_rm_short() {
    local repo="$TMPDIR_BASE/t7b-repo"
    local wbase="$TMPDIR_BASE/t7b-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm -r \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T7b marker_delete_blocked_recursive_rm_short" \
                      || fail "T7b marker_delete_blocked_recursive_rm_short == $r"
}

T8_marker_delete_blocked_recursive_ri_full() {
    local repo="$TMPDIR_BASE/t8-repo"
    local wbase="$TMPDIR_BASE/t8-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -Recurse -LiteralPath \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T8 marker_delete_blocked_recursive_ri_full" \
                      || fail "T8 marker_delete_blocked_recursive_ri_full == $r"
}

T8b_marker_delete_blocked_recursive_ri_abbrev() {
    local repo="$TMPDIR_BASE/t8b-repo"
    local wbase="$TMPDIR_BASE/t8b-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -r -LiteralPath \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T8b marker_delete_blocked_recursive_ri_abbrev" \
                      || fail "T8b marker_delete_blocked_recursive_ri_abbrev == $r"
}

T9_marker_delete_blocked_pwsh_path_wildcard() {
    local repo="$TMPDIR_BASE/t9-repo"
    local wbase="$TMPDIR_BASE/t9-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -Path \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T9 marker_delete_blocked_pwsh_path_wildcard" \
                      || fail "T9 marker_delete_blocked_pwsh_path_wildcard == $r"
}

T10_marker_delete_blocked_extra_positional_rm() {
    local repo="$TMPDIR_BASE/t10-repo"
    local wbase="$TMPDIR_BASE/t10-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\" README.md" "$repo")"
    [ "$r" = "false" ] && pass "T10 marker_delete_blocked_extra_positional_rm" \
                      || fail "T10 marker_delete_blocked_extra_positional_rm == $r"
}

T11_marker_delete_blocked_extra_positional_ri() {
    local repo="$TMPDIR_BASE/t11-repo"
    local wbase="$TMPDIR_BASE/t11-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -LiteralPath \"$marker\" README.md" "$repo")"
    [ "$r" = "false" ] && pass "T11 marker_delete_blocked_extra_positional_ri" \
                      || fail "T11 marker_delete_blocked_extra_positional_ri == $r"
}

T12_marker_delete_blocked_ri_array() {
    local repo="$TMPDIR_BASE/t12-repo"
    local wbase="$TMPDIR_BASE/t12-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "Remove-Item -LiteralPath \"$marker\",\"other\"" "$repo")"
    [ "$r" = "false" ] && pass "T12 marker_delete_blocked_ri_array" \
                      || fail "T12 marker_delete_blocked_ri_array == $r"
}

T13_marker_delete_failclosed_git_fatal() {
    local repo="$TMPDIR_BASE/t13-repo"
    local wbase="$TMPDIR_BASE/t13-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_git_broken "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local r
    WORKTREE_BASE_DIR="$wbase" r="$(call_isAllowedMarkerDelete "rm \"$marker\"" "$repo")"
    [ "$r" = "false" ] && pass "T13 marker_delete_failclosed_git_fatal" \
                      || fail "T13 marker_delete_failclosed_git_fatal == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# E2E — full hook (T14–T16)
# ─────────────────────────────────────────────────────────────────────────────

T14_e2e_hook_allows_from_main() {
    local repo="$TMPDIR_BASE/t14-repo"
    local wbase="$TMPDIR_BASE/t14-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local payload
    payload="$(hook_payload_bash "rm \"$marker\"")"
    local out
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*) fail "T14 e2e_hook_allows_from_main blocked: $out" ;;
        *) pass "T14 e2e_hook_allows_from_main" ;;
    esac
}

T15_e2e_hook_blocks_unrelated_rm() {
    local repo="$TMPDIR_BASE/t15-repo"
    local wbase="$TMPDIR_BASE/t15-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_gone "$repo" "fix/foo" "$wbase/foo/agents"

    local payload
    payload="$(hook_payload_bash "rm README.md")"
    local out
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*) pass "T15 e2e_hook_blocks_unrelated_rm" ;;
        *) fail "T15 e2e_hook_blocks_unrelated_rm not blocked: $out" ;;
    esac
}

T16_e2e_hook_blocks_marker_branch_exists() {
    local repo="$TMPDIR_BASE/t16-repo"
    local wbase="$TMPDIR_BASE/t16-wbase"
    mkdir -p "$wbase/foo"
    setup_repo_branch_present "$repo" "fix/foo" "$wbase/foo/agents"

    local marker="$(marker_path_for "$repo")"
    local payload
    payload="$(hook_payload_bash "rm \"$marker\"")"
    local out
    out="$(ENFORCE_WORKTREE=on WORKTREE_BASE_DIR="$wbase" run_hook "$payload" "$repo")"
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
    r="$(call_classify 'rm "/path/.git/info/pending-branch-delete"')"
    [ "$r" = "write" ] && pass "T17 classify_rm_still_write" \
                      || fail "T17 classify_rm_still_write == $r"
}

T18_classify_removeitem_still_write() {
    local r
    r="$(call_classify 'Remove-Item -LiteralPath "/path/.git/info/pending-branch-delete"')"
    [ "$r" = "write" ] && pass "T18 classify_removeitem_still_write" \
                      || fail "T18 classify_removeitem_still_write == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# settings.json glob-pattern matching (T19–T21)
# ─────────────────────────────────────────────────────────────────────────────

# New allow entries planned for settings.json. Hardcoded here because the
# settings.json file does not yet contain them — these strings document the
# expected step-6g command shape.
#
# settings.json stores these as JSON strings, so `\\` in the file decodes to
# a single backslash at runtime. We compare against the *decoded* pattern,
# which is the form Claude Code's permission matcher sees.
POSIX_ALLOW_PATTERN='Bash(rm "*/.git/info/pending-branch-delete")'
PWSH_ALLOW_PATTERN='Bash(Remove-Item -LiteralPath "*\.git\info\pending-branch-delete")'

T19_settings_posix_pattern_matches() {
    local candidate='Bash(rm "/tmp/repo/.git/info/pending-branch-delete")'
    local r
    r="$(glob_match "$POSIX_ALLOW_PATTERN" "$candidate")"
    [ "$r" = "yes" ] && pass "T19 settings_posix_pattern_matches" \
                    || fail "T19 settings_posix_pattern_matches == $r"
}

T20_settings_pwsh_pattern_matches() {
    local candidate='Bash(Remove-Item -LiteralPath "C:\repo\.git\info\pending-branch-delete")'
    local r
    r="$(glob_match "$PWSH_ALLOW_PATTERN" "$candidate")"
    [ "$r" = "yes" ] && pass "T20 settings_pwsh_pattern_matches" \
                    || fail "T20 settings_pwsh_pattern_matches == $r"
}

T21_settings_no_match_unrelated() {
    # path tail missing `.git/info/` — must not match POSIX allow pattern
    local candidate='Bash(rm "/tmp/pending-branch-delete")'
    local r
    r="$(glob_match "$POSIX_ALLOW_PATTERN" "$candidate")"
    [ "$r" = "no" ] && pass "T21 settings_no_match_unrelated" \
                   || fail "T21 settings_no_match_unrelated == $r"
}

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
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    local marker="$(marker_path_for "$repo")"
    local r
    r="$(call_isMarkerFilePath "$marker" "$repo")"
    [ "$r" = "true" ] && pass "T22 isMarkerFilePath_matches" \
                     || fail "T22 isMarkerFilePath_matches == $r"
}

T23_isMarkerFilePath_no_match_other_file() {
    local repo="$TMPDIR_BASE/t23-repo"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    local r
    r="$(call_isMarkerFilePath "$repo/.git/info/exclude" "$repo")"
    [ "$r" = "false" ] && pass "T23 isMarkerFilePath_no_match_other_file" \
                      || fail "T23 isMarkerFilePath_no_match_other_file == $r"
}

T24_isMarkerFilePath_no_match_repo_file() {
    local repo="$TMPDIR_BASE/t24-repo"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    local r
    r="$(call_isMarkerFilePath "$repo/README.md" "$repo")"
    [ "$r" = "false" ] && pass "T24 isMarkerFilePath_no_match_repo_file" \
                      || fail "T24 isMarkerFilePath_no_match_repo_file == $r"
}

T25_e2e_hook_allows_write_to_marker() {
    local repo="$TMPDIR_BASE/t25-repo"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    local marker="$(marker_path_for "$repo")"
    local payload out
    payload="$(hook_payload_write "$marker")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*) fail "T25 e2e_hook_allows_write_to_marker blocked: $out" ;;
        *) pass "T25 e2e_hook_allows_write_to_marker" ;;
    esac
}

T26_e2e_hook_allows_edit_to_marker() {
    local repo="$TMPDIR_BASE/t26-repo"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
    local marker="$(marker_path_for "$repo")"
    local payload out
    payload="$(hook_payload_edit "$marker")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*) fail "T26 e2e_hook_allows_edit_to_marker blocked: $out" ;;
        *) pass "T26 e2e_hook_allows_edit_to_marker" ;;
    esac
}

T27_e2e_hook_blocks_write_to_tracked_file() {
    local repo="$TMPDIR_BASE/t27-repo"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty -q -m init)
    local payload out
    payload="$(hook_payload_write "$repo/README.md")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*) pass "T27 e2e_hook_blocks_write_to_tracked_file" ;;
        *) fail "T27 e2e_hook_blocks_write_to_tracked_file not blocked: $out" ;;
    esac
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
T19_settings_posix_pattern_matches
T20_settings_pwsh_pattern_matches
T21_settings_no_match_unrelated
T22_isMarkerFilePath_matches
T23_isMarkerFilePath_no_match_other_file
T24_isMarkerFilePath_no_match_repo_file
T25_e2e_hook_allows_write_to_marker
T26_e2e_hook_allows_edit_to_marker
T27_e2e_hook_blocks_write_to_tracked_file

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
