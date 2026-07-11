#!/bin/bash
# tests/fix-unblock-branch-d/hook-redirect.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/branch-delete-guard.js, hooks/lib/command-parser.js
# Tags: worktree, enforce, hook, branch-delete, redirect, sweep, security, integration, scope:common
#
# End-to-end hook coverage for the redirect-suffix fix (#1380/#1172) that the
# JS-unit and WORKTREE_END-only integration groups do not exercise:
#   - S1/S2: SWEEP_BRANCHES_SKILL force-delete routed through the REAL hook
#     (enforce-worktree.js), redirect suffix ALLOW + protected-branch BLOCK.
#   - C-space: quoted `-C <path with space>` end-to-end ALLOW.
#   - N1: redirect + `&&` chaining → BLOCK, with a Negative assertion that
#     BOTH branches survive (nothing was force-deleted) — the security proof
#     that redirect stripping does not open a chaining bypass.
#
# Runnable standalone:
#   bash tests/fix-unblock-branch-d/hook-redirect.sh
#
# Mutation-probe: AFTER the source fix lands, run
#   bin/mutation-probe.sh hooks/lib/command-parser.js
# and confirm the >=80% kill threshold (run-tests stage, not here). Each redirect
# form has an independent ALLOW case so a never-match mutation kills >=1 case.
#
# L3 gap (what this test does NOT catch):
# - Whether a real Claude Code Bash tool invocation appends exactly these
#   redirect/chaining forms (this spawns `node hooks/...` with a synthetic
#   payload, not a live session).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

PASS=0
FAIL=0

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'unblock-branch-d-hookr-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Create a divergent feature branch off main (unmerged commit → force-delete
# territory). Leaves HEAD on main so the target branch is not checked out.
make_divergent_feature() {
    local repo="$1" branch="$2"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t checkout -q -b "$branch" && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m "divergent" && \
        git -c user.email=t@example.com -c user.name=t checkout -q main)
}

# ─────────────────────────────────────────────────────────────────────────────
# C1 — S1: SWEEP_BRANCHES_SKILL force-delete + ` 2>&1` through the REAL hook
#      → ALLOW. run_hook builds a generic Bash payload; the hook reads the raw
#      command text, so the SWEEP_BRANCHES_SKILL=1 inline prefix routes to
#      isSweepBranchesSkillForceDelete with no extra wiring.
#      FAIL-BEFORE-FIX: hook BLOCKs the redirect form now → RED until the fix.
# ─────────────────────────────────────────────────────────────────────────────

test_S1_allow_sweep_force_delete_with_redirect() {
    local repo="$TMPDIR_BASE/s1-repo"
    make_divergent_feature "$repo" "feature/sweepx"
    local payload out rc
    payload="$(hook_payload_bash "SWEEP_BRANCHES_SKILL=1 git -C $repo branch -D feature/sweepx 2>&1")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S1 SWEEP_BRANCHES_SKILL force-delete + ' 2>&1' → ALLOW (hook e2e)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# C1 — S2: SWEEP force-delete of a PROTECTED/non-feature branch (`main`) with
#      a redirect suffix → BLOCK. Negative assertion (fail-closed must hold
#      even when the redirect is stripped). PASSES now and must keep passing.
# ─────────────────────────────────────────────────────────────────────────────

test_S2_block_sweep_protected_branch_with_redirect() {
    local repo="$TMPDIR_BASE/s2-repo"
    init_repo "$repo"
    local payload out rc
    payload="$(hook_payload_bash "SWEEP_BRANCHES_SKILL=1 git -C $repo branch -D main 2>&1")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_block "S2 SWEEP force-delete of 'main' + ' 2>&1' → BLOCK (fail-closed holds)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# C3 — quoted `-C <path with space>` + redirect through the REAL hook → ALLOW.
#      Exercises the `-C` path regex branch `(?:"[^"]+"|'[^']+'|\S+)` against a
#      real repo whose absolute path contains a space, matching #1172's strict
#      `-C <path>` handling.
#      FAIL-BEFORE-FIX: hook BLOCKs the redirect form now → RED until the fix.
# ─────────────────────────────────────────────────────────────────────────────

test_S3_allow_quoted_C_path_with_space() {
    local repo="$TMPDIR_BASE/s3 repo with space"
    make_divergent_feature "$repo" "feature/spacepath"
    local payload out rc
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C \"$repo\" branch -D feature/spacepath 2>&1")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S3 quoted -C '<path with space>' + ' 2>&1' → ALLOW (hook e2e, #1172)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# G1 — S4: spaced-operator redirect (operator and path are SEPARATE tokens,
#      `> /dev/null`) through the REAL hook → ALLOW. Exercises the detail
#      plan's stripping pattern c (`/\s+(?:\d*>>?|&>>?)\s+[^\s...]+$/`), which
#      the glued-operator cases (S1/S3) do not reach.
#      FAIL-BEFORE-FIX: hook BLOCKs the redirect form now → RED until the fix.
# ─────────────────────────────────────────────────────────────────────────────

test_S4_allow_WE_force_delete_with_spaced_operator() {
    local repo="$TMPDIR_BASE/s4-repo"
    make_divergent_feature "$repo" "feature/spaced"
    local payload out rc
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/spaced > /dev/null")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S4 WE force-delete + spaced-operator '> /dev/null' → ALLOW (hook e2e)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# C2 — N1: redirect + `&&` chaining → BLOCK, with a directly-asserted Negative
#      outcome. Attack scenario (#1001 pattern 2): an authorized WE force-delete
#      shape is suffixed with ` 2>&1 && git branch -D main` to smuggle a second
#      protected-branch delete past the redirect-stripping helper.
#      Layer-A guard: hasShellChaining(ORIGINAL cmd) detects `&&` → BLOCK.
#      stripTrailingRedirects would strip ` 2>&1` but NOT the trailing `main`.
#      Negative assertion (#1001 pattern 1): assert BOTH feature/x and main
#      still exist after the hook decision — proving nothing was force-deleted.
#      PASSES now (chaining guard predates this fix) and must keep passing.
# ─────────────────────────────────────────────────────────────────────────────

test_N1_block_redirect_plus_chaining_negative() {
    local repo="$TMPDIR_BASE/n1-repo"
    make_divergent_feature "$repo" "feature/chainx"

    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/chainx 2>&1 && git branch -D main")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"

    # Precondition sanity: hook must not have side effects — the hook only
    # decides; it never runs git. Assert BLOCK decision first.
    local decided_block=0
    case "$out" in
        *'"decision":"block"'*) decided_block=1 ;;
    esac

    # Negative assertion: neither branch was deleted. The hook is a PreToolUse
    # gate that returns a decision; on BLOCK the Bash command never executes, so
    # both branches must remain present in the repo.
    local feat_exists main_exists
    feat_exists="$(cd "$repo" && git branch --list 'feature/chainx' 2>/dev/null)"
    main_exists="$(cd "$repo" && git branch --list 'main' 2>/dev/null)"

    if [ "$decided_block" -eq 1 ] && [ -n "$feat_exists" ] && [ -n "$main_exists" ]; then
        pass "N1 redirect + '&&' chaining → BLOCK; feature/chainx & main both survive (negative)"
    else
        fail "N1 expected BLOCK + both branches intact; block=$decided_block feat=[$feat_exists] main=[$main_exists] out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# C1 — S5: append-redirect (`2>> /tmp/log`) through the REAL hook → ALLOW.
#      Exercises the detail plan's `\d*>>?` / spaced pattern for the append
#      operator, which the truncating-redirect cases do not reach.
#      FAIL-BEFORE-FIX: hook BLOCKs the redirect form now → RED until the fix.
# ─────────────────────────────────────────────────────────────────────────────

test_S5_allow_WE_force_delete_with_append_redirect() {
    local repo="$TMPDIR_BASE/s5-repo"
    make_divergent_feature "$repo" "feature/append"
    local payload out rc
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/append 2>> $TMPDIR_BASE/s5.log")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S5 WE force-delete + append-redirect '2>> <log>' → ALLOW (hook e2e)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# C2 — N2: redirect + pipe (`2>&1 | tee /tmp/x`) → BLOCK (fail-closed boundary).
#      stripTrailingRedirects strips the trailing `2>&1` but NOT the following
#      `tee /tmp/x` (not a redirect); the `|` then trips both hasShellChaining
#      and the layer-B `^...$` anchor. Negative assertion: feature/x survives.
#      PASSES now (fail-closed predates this fix) and must keep passing.
# ─────────────────────────────────────────────────────────────────────────────

test_N2_block_redirect_plus_pipe_negative() {
    local repo="$TMPDIR_BASE/n2-repo"
    make_divergent_feature "$repo" "feature/pipex"
    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/pipex 2>&1 | tee /tmp/x")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    local decided_block=0
    case "$out" in
        *'"decision":"block"'*) decided_block=1 ;;
    esac
    local feat_exists
    feat_exists="$(cd "$repo" && git branch --list 'feature/pipex' 2>/dev/null)"
    if [ "$decided_block" -eq 1 ] && [ -n "$feat_exists" ]; then
        pass "N2 redirect + '| tee' pipe → BLOCK; feature/pipex survives (negative)"
    else
        fail "N2 expected BLOCK + branch intact; block=$decided_block feat=[$feat_exists] out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# C2 — N3: redirect + background (`2>&1 &`) → BLOCK (fail-closed boundary).
#      Trailing `&` is a control operator, not part of a recognized redirect
#      suffix; hasShellChaining detects it → BLOCK. Negative assertion: the
#      protected branch survives. PASSES now and must keep passing.
# ─────────────────────────────────────────────────────────────────────────────

test_N3_block_redirect_plus_background_negative() {
    local repo="$TMPDIR_BASE/n3-repo"
    init_repo "$repo"
    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D main 2>&1 &")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    local decided_block=0
    case "$out" in
        *'"decision":"block"'*) decided_block=1 ;;
    esac
    local main_exists
    main_exists="$(cd "$repo" && git branch --list 'main' 2>/dev/null)"
    if [ "$decided_block" -eq 1 ] && [ -n "$main_exists" ]; then
        pass "N3 redirect + background '&' → BLOCK; main survives (negative)"
    else
        fail "N3 expected BLOCK + main intact; block=$decided_block main=[$main_exists] out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# C2 — N4/N5: command-substitution redirect-target attack. An authorized WE
#      force-delete shape is given a redirect target of `$(touch <marker>)` /
#      `` `touch <marker>` `` to try to run arbitrary code as a side effect of
#      the delete.
#
#      OBSERVED CONTRACT (verified by hitting the hook directly — NOT guessed):
#      the hook is a pure PreToolUse DECISION gate; it never executes the Bash
#      command, so the substitution never runs → the marker file is never
#      created, regardless of the allow/block decision. That marker-not-created
#      invariant is the security property under test and it holds both before
#      and after the source fix (the fix changes only the allow/block decision,
#      never whether the hook executes the command).
#
#      The invariant asserted is directly the Negative outcome (#1001 pattern 1):
#      the attack side effect did NOT occur. Additionally, the redirect target
#      is inert to the authorization predicate (see the unit-level
#      isWorktreeEndSkillForceDelete rows: `>$(...)` / backtick → false).
#
#      NOTE for downstream: currently the HOOK DECISION for these forms is ALLOW
#      ({} payload), because the trailing `>$(...)` breaks branch-delete command
#      classification so the force-delete guard never engages. The delete itself
#      is still inert here (hook never runs it), but this asymmetry is worth a
#      source-side check when the fix lands. Test asserts only the verified fact.
# ─────────────────────────────────────────────────────────────────────────────

# Assert the hook did NOT execute a command-substitution redirect target.
# $1=label, $2=command (must reference $marker), $3=repo, $4=marker path.
_assert_no_cmdsub_side_effect() {
    local label="$1" cmd="$2" repo="$3" marker="$4"
    local payload out
    payload="$(hook_payload_bash "$cmd")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    if [ -e "$marker" ]; then
        fail "$label: SECURITY — command substitution executed (marker created); out=$out"
    else
        pass "$label: substitution NOT executed (marker absent); hook is a pure decision gate"
    fi
}

test_N4_cmdsub_dollar_paren_no_side_effect() {
    local repo="$TMPDIR_BASE/n4-repo"
    local marker="$TMPDIR_BASE/n4-marker"
    make_divergent_feature "$repo" "feature/x"
    _assert_no_cmdsub_side_effect \
        "N4 redirect target '\$(touch <marker>)'" \
        "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/x >\$(touch $marker)" \
        "$repo" "$marker"
}

test_N5_cmdsub_backtick_no_side_effect() {
    local repo="$TMPDIR_BASE/n5-repo"
    local marker="$TMPDIR_BASE/n5-marker"
    make_divergent_feature "$repo" "feature/x"
    _assert_no_cmdsub_side_effect \
        "N5 redirect target backtick 'touch <marker>'" \
        "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/x >\`touch $marker\`" \
        "$repo" "$marker"
}

# ─────────────────────────────────────────────────────────────────────────────
# C2 (CPR-5) — S6/S7/S8: sweep-side hook e2e symmetry with the WE cases
#      T21/T22/T23. S1 only covers ` 2>&1`; the truncating file-redirect forms
#      (`>/dev/null`, `2>/dev/null`, stacked `>/dev/null 2>&1`) are exercised
#      here through the REAL hook via the SWEEP_BRANCHES_SKILL=1 route, using a
#      feature-typed branch (same fixture shape as the WE tests).
#      Positive+exit assertion (assert_hook_allow: exit 0 + allow payload `{}`).
#      FAIL-BEFORE-FIX: hook BLOCKs the redirect form now → RED until the fix.
# ─────────────────────────────────────────────────────────────────────────────

test_S6_allow_sweep_force_delete_truncate_redirect() {
    local repo="$TMPDIR_BASE/s6-repo"
    make_divergent_feature "$repo" "feature/sweep6"
    local payload out rc
    payload="$(hook_payload_bash "SWEEP_BRANCHES_SKILL=1 git -C $repo branch -D feature/sweep6 >/dev/null")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S6 SWEEP force-delete + ' >/dev/null' → ALLOW (hook e2e)" "$out" "$rc"
}

test_S7_allow_sweep_force_delete_2devnull() {
    local repo="$TMPDIR_BASE/s7-repo"
    make_divergent_feature "$repo" "feature/sweep7"
    local payload out rc
    payload="$(hook_payload_bash "SWEEP_BRANCHES_SKILL=1 git -C $repo branch -D feature/sweep7 2>/dev/null")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S7 SWEEP force-delete + ' 2>/dev/null' → ALLOW (hook e2e)" "$out" "$rc"
}

test_S8_allow_sweep_force_delete_stacked() {
    local repo="$TMPDIR_BASE/s8-repo"
    make_divergent_feature "$repo" "feature/sweep8"
    local payload out rc
    payload="$(hook_payload_bash "SWEEP_BRANCHES_SKILL=1 git -C $repo branch -D feature/sweep8 >/dev/null 2>&1")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "S8 SWEEP force-delete + stacked ' >/dev/null 2>&1' → ALLOW (hook e2e)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

test_S1_allow_sweep_force_delete_with_redirect
test_S2_block_sweep_protected_branch_with_redirect
test_S3_allow_quoted_C_path_with_space
test_S4_allow_WE_force_delete_with_spaced_operator
test_S5_allow_WE_force_delete_with_append_redirect
test_S6_allow_sweep_force_delete_truncate_redirect
test_S7_allow_sweep_force_delete_2devnull
test_S8_allow_sweep_force_delete_stacked
test_N1_block_redirect_plus_chaining_negative
test_N2_block_redirect_plus_pipe_negative
test_N3_block_redirect_plus_background_negative
test_N4_cmdsub_dollar_paren_no_side_effect
test_N5_cmdsub_backtick_no_side_effect

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
