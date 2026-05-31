#!/bin/bash
# tests/main-merge-detect.sh
# Tests: hooks/lib/merge-detect.js, hooks/lib/parse-git-args.js
# Tags: hook, bin, git, pr, github
#
# Unit tests for hooks/lib/merge-detect.js
#
# This source module is NOT yet implemented. Tests will FAIL with a
# "merge-detect.js not implemented" message until the source is written.
# That is expected.
#
# Targets:
#   hooks/lib/merge-detect.js — exports isMergeToProtectedCommand(command, repoDir)
#                               returning { hit: bool, kind: "gh-pr-merge"|"git-push-protected"|null }
#   hooks/lib/parse-git-args.js — must export parseGitGlobalOptions used by merge-detect.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/merge-detect.js"
MODULE_BASH="${AGENTS_DIR}/hooks/lib/merge-detect.js"

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

require_module() {
    if [ ! -f "$MODULE_BASH" ]; then
        fail "$1 (merge-detect.js not implemented)"
        return 1
    fi
    return 0
}

# Invoke isMergeToProtectedCommand(cmd, repoDir) and print "<hit>|<kind>"
# (kind printed as "null" if null/undefined). repoDir is optional; defaults to "".
detect_cmd() {
    local cmd="$1"
    local repo="${2:-}"
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.isMergeToProtectedCommand;
        const cmd = process.argv[1];
        const repo = process.argv[2] || undefined;
        const r = fn(cmd, repo);
        const hit = r && r.hit ? 'true' : 'false';
        const kind = r && r.kind != null ? String(r.kind) : 'null';
        console.log(hit + '|' + kind);
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$cmd" "$repo" 2>/dev/null
}

assert_hit() {
    local desc="$1" cmd="$2" expected_kind="$3"
    require_module "$desc" || return
    local got
    got="$(detect_cmd "$cmd")"
    if [ "$got" = "true|$expected_kind" ]; then
        pass "$desc -> hit:true kind:$expected_kind"
    else
        fail "$desc: expected 'true|$expected_kind', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

assert_miss() {
    local desc="$1" cmd="$2"
    require_module "$desc" || return
    local got
    got="$(detect_cmd "$cmd")"
    if [ "${got%%|*}" = "false" ]; then
        pass "$desc -> hit:false"
    else
        fail "$desc: expected 'false|*', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

# ============ Normal (11) ============

test_n01_gh_pr_merge_squash() {
    assert_hit "N01 gh pr merge --squash"          "gh pr merge --squash"             "gh-pr-merge"
}
test_n02_git_push_origin_main() {
    assert_hit "N02 git push origin main"          "git push origin main"             "git-push-protected"
}
test_n03_git_push_feature() {
    assert_miss "N03 git push origin feature/foo"  "git push origin feature/foo"
}
test_n04_gh_pr_view() {
    assert_miss "N04 gh pr view"                   "gh pr view"
}
test_n05_gh_pr_list() {
    assert_miss "N05 gh pr list"                   "gh pr list"
}
test_n06_gh_pr_create() {
    assert_miss "N06 gh pr create"                 "gh pr create"
}
test_n07_push_HEAD_colon_main() {
    assert_hit "N07 git push origin HEAD:main"     "git push origin HEAD:main"        "git-push-protected"
}
test_n08_push_HEAD_refs_heads_main() {
    assert_hit "N08 git push origin HEAD:refs/heads/main" \
        "git push origin HEAD:refs/heads/main" "git-push-protected"
}
test_n09_push_feature_colon_main() {
    assert_hit "N09 git push origin feature/x:main" \
        "git push origin feature/x:main" "git-push-protected"
}
test_n10_push_delete_main() {
    assert_hit "N10 git push origin :main (delete)" "git push origin :main" "git-push-protected"
}
test_n11_push_force_plus_HEAD_main() {
    assert_hit "N11 git push origin +HEAD:main"    "git push origin +HEAD:main"       "git-push-protected"
}

# ============ Edge (12) ============

test_e12_force_main() {
    assert_hit "E12 git push --force origin main"  "git push --force origin main"     "git-push-protected"
}
test_e13_force_with_lease_main() {
    assert_hit "E13 git push --force-with-lease origin main" \
        "git push --force-with-lease origin main" "git-push-protected"
}
test_e14_master() {
    assert_hit "E14 git push origin master"        "git push origin master"           "git-push-protected"
}
test_e15_no_pager_push_main() {
    assert_hit "E15 git --no-pager push origin main" \
        "git --no-pager push origin main" "git-push-protected"
}
test_e16_dash_c_global_then_push() {
    assert_hit "E16 git -c http.sslVerify=false push origin main" \
        "git -c http.sslVerify=false push origin main" "git-push-protected"
}
test_e17_push_all() {
    assert_hit "E17 git push --all origin"         "git push --all origin"            "git-push-protected"
}
test_e18_push_mirror() {
    assert_hit "E18 git push --mirror origin"      "git push --mirror origin"         "git-push-protected"
}
test_e19_gh_pr_merge_auto() {
    assert_hit "E19 gh pr merge --auto"            "gh pr merge --auto"               "gh-pr-merge"
}
test_e20_gh_pr_merge_pr_number() {
    assert_hit "E20 gh pr merge 42 --squash"       "gh pr merge 42 --squash"          "gh-pr-merge"
}
test_e21_substring_mainframe() {
    assert_miss "E21 git push origin mainframe (substring not whole-word)" \
        "git push origin mainframe"
}
test_e22_feature_main_rebase() {
    assert_miss "E22 git push origin feature/main-rebase" \
        "git push origin feature/main-rebase"
}
test_e23_push_HEAD_no_refspec() {
    assert_miss "E23 git push origin HEAD (no refspec)" "git push origin HEAD"
}

# ============ Security (3) ============

test_s24_echo_git_push_main() {
    assert_miss "S24 echo \"git push origin main\" (echo command, not git push)" \
        'echo "git push origin main"'
}
test_s25_empty_command() {
    assert_miss "S25 empty command" ""
}
test_s26_quoted_main_with_payload() {
    assert_miss "S26 git push origin 'main; rm -rf /' (quoted single token)" \
        "git push origin 'main; rm -rf /'"
}

# ============ Run all ============

test_n01_gh_pr_merge_squash
test_n02_git_push_origin_main
test_n03_git_push_feature
test_n04_gh_pr_view
test_n05_gh_pr_list
test_n06_gh_pr_create
test_n07_push_HEAD_colon_main
test_n08_push_HEAD_refs_heads_main
test_n09_push_feature_colon_main
test_n10_push_delete_main
test_n11_push_force_plus_HEAD_main
test_e12_force_main
test_e13_force_with_lease_main
test_e14_master
test_e15_no_pager_push_main
test_e16_dash_c_global_then_push
test_e17_push_all
test_e18_push_mirror
test_e19_gh_pr_merge_auto
test_e20_gh_pr_merge_pr_number
test_e21_substring_mainframe
test_e22_feature_main_rebase
test_e23_push_HEAD_no_refspec
test_s24_echo_git_push_main
test_s25_empty_command
test_s26_quoted_main_with_payload

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
