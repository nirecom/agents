#!/bin/bash
# tests/fix-unblock-branch-d/unit.sh
# Tests: hooks/enforce-worktree.js, hooks/lib/bash-write-patterns.js, hooks/lib/command-parser.js, hooks/enforce-worktree/branch-delete-guard.js
# Tags: worktree, enforce, hook, branch-delete, redirect, parser, scope:common
#
# Unit tests (no real git repo required) for the branch-delete guard:
#   - classify() reclassifies -d/-D as write
#   - isBranchDeleteCommand / parseBranchDeleteTarget shape + quoting
#   - stripTrailingRedirects mechanical trailing-redirect stripping (#1380/#1172)
#   - isWorktreeEndSkillForceDelete tolerance of trailing redirect suffixes
#
# Runnable standalone:
#   bash tests/fix-unblock-branch-d/unit.sh
#
# L3 gap (what this test does NOT catch):
# - Whether the PreToolUse hook actually fires and honors the redirect-tolerant
#   predicate inside a real Claude Code session Bash invocation (integration.sh
#   covers the hook end-to-end; only a live session exercises the real wiring).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

PASS=0
FAIL=0

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'unblock-branch-d-unit-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# T1: git branch -d/-D is a write (detected by isGitWriteIR, the SSOT).
# Post-#1401 the git WRITE_PATTERNS entries were retired: classify() no longer
# flags git as write; isGitWriteIR (IR-based) owns write detection. This mirrors
# the fix-1391 gh-retire update (classify → isGhWriteIR).
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_delete_is_write() {
    local r
    r="$(call_isGitWriteIR 'git branch -d fix/foo')"
    if [ "$r" = "true" ]; then
        pass "isGitWriteIR(git branch -d fix/foo) == true"
    else
        fail "isGitWriteIR(git branch -d fix/foo) == $r (expected true)"
    fi
    r="$(call_isGitWriteIR 'git branch -D fix/foo')"
    if [ "$r" = "true" ]; then
        pass "isGitWriteIR(git branch -D fix/foo) == true"
    else
        fail "isGitWriteIR(git branch -D fix/foo) == $r (expected true)"
    fi
    r="$(call_isGitWriteIR 'git -C /path branch -D fix/foo')"
    if [ "$r" = "true" ]; then
        pass "isGitWriteIR(git -C /path branch -D fix/foo) == true"
    else
        fail "isGitWriteIR(git -C ... branch -D ...) == $r (expected true)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T2: classify does NOT match read-only branch ops or branch names
#     containing "-d" / "-D" as substrings
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_no_false_positive() {
    local r
    r="$(call_classify 'git branch')"
    [ "$r" = "read" ] && pass "classify(git branch) == read" \
                     || fail "classify(git branch) == $r"
    r="$(call_classify 'git branch -a')"
    [ "$r" = "read" ] && pass "classify(git branch -a) == read" \
                     || fail "classify(git branch -a) == $r"
    r="$(call_classify 'git branch --contains HEAD')"
    [ "$r" = "read" ] && pass "classify(git branch --contains) == read" \
                     || fail "classify(git branch --contains) == $r"
    # Branch name token contains substring "-d" — must NOT match (whitespace-anchored)
    r="$(call_classify 'git branch fix-d-foo')"
    [ "$r" = "read" ] && pass "classify(git branch fix-d-foo) == read (no false positive)" \
                     || fail "classify(git branch fix-d-foo) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# T3: isBranchDeleteCommand basic shape detection
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand() {
    local r
    r="$(call_isBranchDeleteCommand 'git branch -D fix/foo')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git branch -D fix/foo)" \
                     || fail "isBranchDeleteCommand(git branch -D fix/foo) == $r"
    r="$(call_isBranchDeleteCommand 'git branch -d fix/foo')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git branch -d fix/foo)" \
                     || fail "isBranchDeleteCommand(git branch -d fix/foo) == $r"
    r="$(call_isBranchDeleteCommand 'git -C /path branch -D fix/foo')"
    [ "$r" = "true" ] && pass "isBranchDeleteCommand(git -C ... branch -D ...)" \
                     || fail "isBranchDeleteCommand(git -C ... branch -D ...) == $r"
    r="$(call_isBranchDeleteCommand 'git branch -m old new')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(git branch -m) == false (rename, not delete)" \
                      || fail "isBranchDeleteCommand(git branch -m) == $r"
    r="$(call_isBranchDeleteCommand 'git status')"
    [ "$r" = "false" ] && pass "isBranchDeleteCommand(git status) == false" \
                      || fail "isBranchDeleteCommand(git status) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# T4: parseBranchDeleteTarget extracts the target branch name
# ─────────────────────────────────────────────────────────────────────────────

test_parseBranchDeleteTarget() {
    local r
    r="$(call_parseTarget 'git branch -D fix/foo')"
    [ "$r" = '"fix/foo"' ] && pass "parseTarget(git branch -D fix/foo) == fix/foo" \
                          || fail "parseTarget == $r"
    r="$(call_parseTarget 'git -C /repo branch -d feature/x')"
    [ "$r" = '"feature/x"' ] && pass "parseTarget(git -C ... branch -d feature/x) == feature/x" \
                            || fail "parseTarget == $r"
    r="$(call_parseTarget 'git branch -D')"
    [ "$r" = "null" ] && pass "parseTarget(git branch -D <no arg>) == null" \
                      || fail "parseTarget(no arg) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# T5: structural smoke — module exports are callable.
# ─────────────────────────────────────────────────────────────────────────────

test_module_loads() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const ok = (typeof m.isBranchDeleteCommand === 'function') &&
                   (typeof m.parseBranchDeleteTarget === 'function');
        console.log(ok ? 'OK' : 'MISSING_EXPORT');
      } catch (e) { console.log('ERROR: ' + e.message); }
    " 2>/dev/null)"
    [ "$r" = "OK" ] && pass "module exports isBranchDeleteCommand & parseBranchDeleteTarget" \
                   || fail "module load: $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# T13: isBranchDeleteCommand must not false-positive on commit messages
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_no_FP_in_commit_message() {
    local r
    r="$(call_isBranchDeleteCommand 'git commit -m "branch -d fix/foo"')"
    [ "$r" = "false" ] && pass "T13 isBranchDeleteCommand(commit -m \"branch -d fix/foo\") == false" \
                      || fail "T13 isBranchDeleteCommand(commit msg with branch -d) == $r (expected false)"
    r="$(call_isBranchDeleteCommand 'git commit -m "delete branch -D feature/x"')"
    [ "$r" = "false" ] && pass "T13 isBranchDeleteCommand(commit msg with branch -D) == false" \
                      || fail "T13 isBranchDeleteCommand(commit msg with branch -D) == $r (expected false)"
}

# ─────────────────────────────────────────────────────────────────────────────
# T14: real `git branch -d/-D` with quoted branch name still detected
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_quoted_branch_value() {
    local r
    r="$(call_isBranchDeleteCommand 'git branch -D "feature/x"')"
    [ "$r" = "true" ] && pass "T14 isBranchDeleteCommand(git branch -D \"feature/x\") == true" \
                     || fail "T14 isBranchDeleteCommand(git branch -D \"feature/x\") == $r (expected true)"
    r="$(call_isBranchDeleteCommand "git branch -d 'fix/foo'")"
    [ "$r" = "true" ] && pass "T14 isBranchDeleteCommand(git branch -d 'fix/foo') == true" \
                     || fail "T14 isBranchDeleteCommand(git branch -d 'fix/foo') == $r (expected true)"
}

# ─────────────────────────────────────────────────────────────────────────────
# T15: documented false negative — subcommand token in quotes
# ─────────────────────────────────────────────────────────────────────────────

test_isBranchDeleteCommand_documented_fn() {
    local r
    r="$(call_isBranchDeleteCommand 'git "branch" -D foo')"
    [ "$r" = "false" ] && pass "T15 isBranchDeleteCommand(git \"branch\" -D foo) == false (FN-1: documented)" \
                      || fail "T15 isBranchDeleteCommand(git \"branch\" -D foo) == $r (expected false; FN-1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# T16: parseBranchDeleteTarget unwraps quoted branch names
# ─────────────────────────────────────────────────────────────────────────────

test_parseBranchDeleteTarget_quoted_branch_names() {
    local r
    r="$(call_parseTarget 'git branch -D "feature/x"')"
    [ "$r" = '"feature/x"' ] && pass "T16 parseTarget(git branch -D \"feature/x\") == feature/x" \
                            || fail "T16 parseTarget(quoted feature/x) == $r"
    r="$(call_parseTarget "git branch -d 'fix/foo'")"
    [ "$r" = '"fix/foo"' ] && pass "T16 parseTarget(git branch -d 'fix/foo') == fix/foo" \
                          || fail "T16 parseTarget(single-quoted fix/foo) == $r"
}

# ─────────────────────────────────────────────────────────────────────────────
# NEW — stripTrailingRedirects unit (table-driven; command-parser.js is a
#       parser/regex file → table-driven per test-design.md).
#
#       The helper strips recognized trailing redirect suffixes MECHANICALLY.
#       fail-closed is the predicate layer's job (asserted in the predicate
#       test below and integration.sh), NOT this helper's — hence the
#       `; rm -rf /` case asserts the exact residual after stripping `2>&1`.
#
#       FAIL-BEFORE-FIX: stripTrailingRedirects is not yet exported. The node
#       caller returns 'MISSING_FN' → every non-trivial case FAILS until the
#       source fix lands. That red state is the expected evidence.
#
#       Mutation-probe kill coverage: each redirect form (fd-dup, file-devnull,
#       file-2devnull, stacked) is an independent row, so never-match mutation
#       of any new stripTrailingRedirects regex const kills >=1 row. AFTER the
#       source fix lands, run `bin/mutation-probe.sh hooks/lib/command-parser.js`
#       and confirm the >=80% threshold (run-tests stage, not here).
# ─────────────────────────────────────────────────────────────────────────────

# Assert-eq for table-driven cases (inline, no shared lib).
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

# Call stripTrailingRedirects('$1') and print its return value, or MISSING_FN
# when the export does not exist yet (fail-before-fix state).
call_stripTrailingRedirects() {
    run_with_timeout 30 node -e "
      try {
        const p = require('$PARSER_MODULE');
        const fn = typeof p.stripTrailingRedirects === 'function' ? p.stripTrailingRedirects : null;
        if (!fn) { console.log('MISSING_FN'); process.exit(0); }
        process.stdout.write(fn(process.argv[1]));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

test_stripTrailingRedirects_unit() {
    local input want got
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        # Trim only leading/trailing spaces on name; input/want keep inner spaces.
        name="$(printf '%s' "$name" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        input="$(printf '%s' "$input" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        want="$(printf '%s' "$want" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        got="$(call_stripTrailingRedirects "$input")"
        assert_eq "stripTrailingRedirects/$name" "$want" "$got"
    done <<'TABLE'
fd-dup-2and1        | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>&1            | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
fd-dup-bare-1       | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >&1             | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
fd-dup-close-2      | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>&-            | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
file-devnull        | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >/dev/null      | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
file-2devnull       | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>/dev/null     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
spaced-devnull      | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x > /dev/null     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
spaced-2devnull     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2> /dev/null    | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
append-attached     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >>/tmp/log      | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
append-2-spaced     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>> /tmp/log    | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
allout-spaced       | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x &> /tmp/log     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
allout-append-spaced | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x &>> /tmp/log   | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
stacked-devnull-2and1 | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >/dev/null 2>&1 | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
no-redirect         | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x                | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x
chain-then-2and1    | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x; rm -rf / 2>&1  | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x; rm -rf /
TABLE
}

# ─────────────────────────────────────────────────────────────────────────────
# NEW — isWorktreeEndSkillForceDelete redirect tolerance (predicate unit).
#
#       Security fix (fail-closed): the predicate must ALLOW authorized
#       force-deletes even with Bash-appended trailing redirects, while still
#       REJECTING chained (`;`) and non-feature-branch forms.
#
#       Pattern 1 (Negative assertion): chain + pipe + main cases assert
#       predicate === false, not merely a non-true value.
#       Pattern 2 (Attack scenario): the `; rm -rf /` and `| tee /tmp/x` cases
#       prove a chain/pipe is NOT authorized even after the helper strips a
#       trailing redirect — the layer-B `^...$` anchor rejects `;` / `|`.
#
#       FAIL-BEFORE-FIX: the predicate's `[ \t]*$` anchor still rejects the
#       redirect suffixes → the "want=true" cases FAIL now.
# ─────────────────────────────────────────────────────────────────────────────

# Call isWorktreeEndSkillForceDelete('$1') → prints 'true' | 'false' | 'MISSING_FN'.
call_isWorktreeEndForceDelete() {
    run_with_timeout 30 node -e "
      try {
        const g = require('$GUARD_JS');
        const fn = typeof g.isWorktreeEndSkillForceDelete === 'function' ? g.isWorktreeEndSkillForceDelete : null;
        if (!fn) { console.log('MISSING_FN'); process.exit(0); }
        console.log(fn(process.argv[1]) === true ? 'true' : 'false');
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

test_isWorktreeEndSkillForceDelete_redirect_unit() {
    local name input want got
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(printf '%s' "$name" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        input="$(printf '%s' "$input" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        want="$(printf '%s' "$want" | sed -E 's/[[:space:]]//g')"
        got="$(call_isWorktreeEndForceDelete "$input")"
        assert_eq "isWorktreeEndSkillForceDelete/$name" "$want" "$got"
    done <<'TABLE'
suffix-2and1        | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>&1              | true
suffix-devnull      | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >/dev/null        | true
suffix-2devnull     | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>/dev/null       | true
suffix-spaced-devnull | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x > /dev/null      | true
suffix-fd-dup-bare  | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >&1               | true
suffix-append-spaced | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>> /tmp/log      | true
suffix-stacked      | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >/dev/null 2>&1   | true
quoted-C-path-space | WORKTREE_END_SKILL=1 git -C "repo with space" branch -D feature/x 2>&1 | true
attack-chain-rmrf   | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x; rm -rf / 2>&1    | false
attack-cmdsub-paren | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >$(touch x)       | false
attack-cmdsub-tick  | WORKTREE_END_SKILL=1 git -C /p branch -D feature/x >`touch x`        | false
nonfeature-main     | WORKTREE_END_SKILL=1 git -C /p branch -D main 2>&1                   | false
TABLE

    # attack-pipe-tee is asserted OUT-OF-TABLE: a literal `|` in the input
    # column would collide with the IFS='|' field delimiter. Layer-B check:
    # even after stripTrailingRedirects removes the trailing `2>&1`, the `|`
    # keeps the string off the `^...$` predicate anchor → false.
    local pipe_got
    pipe_got="$(call_isWorktreeEndForceDelete 'WORKTREE_END_SKILL=1 git -C /p branch -D feature/x 2>&1 | tee /tmp/x')"
    assert_eq "isWorktreeEndSkillForceDelete/attack-pipe-tee" "false" "$pipe_got"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

test_classify_branch_delete_is_write
test_classify_branch_no_false_positive
test_isBranchDeleteCommand
test_parseBranchDeleteTarget
test_module_loads
test_isBranchDeleteCommand_no_FP_in_commit_message
test_isBranchDeleteCommand_quoted_branch_value
test_isBranchDeleteCommand_documented_fn
test_parseBranchDeleteTarget_quoted_branch_names
test_stripTrailingRedirects_unit
test_isWorktreeEndSkillForceDelete_redirect_unit

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
