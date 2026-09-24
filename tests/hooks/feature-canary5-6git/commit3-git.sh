#!/usr/bin/env bash
# tests/feature-canary5-6git/commit3-git.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets/git.js, hooks/enforce-worktree/bash-write-scope.js, hooks/lib/bash-write-patterns/classify.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, git-write, self-target, ir-extractor, security, scope:issue-specific, hook-registration, pwsh-not-required
#
# Commit 3 — git write IR extractor + git group retire + self-target routing.
# RED-pending-impl (fail-before-fix):
#   - WRITE_PATTERNS git count == 0 / STRIP_KINDS no git (entries still present).
#   - isGitWriteIR rows (function not exported yet → ERROR:not-exported).
#   - SECURITY C2 (global-flag order) + C3 (config-injection reachability) rows.
#   - classify('git commit') === "read" post-retire.
#   - extractGitWriteTargets self-target contract + collector merge.
#   - L2 downstream reachability (isAllowedFastForwardMerge etc.).
# PASS-now: isReadOnlyInterpreterC('bash -c "git commit"') === false (#820 guard
#   already present), and the git-read false rows for classify sanity.
#
# SECURITY: the git config-injection (C3) and global-flag-order (C2) cases are
# security boundaries. The L2 cases use negative assertions on the actual block
# decision (protected op blocked), not just an exit code.
#
# L3 gap (what this test does NOT catch):
# - real PreToolUse dispatch only fires in a live claude -p session (these L2 cases drive node enforce-worktree.js via stdin JSON)
# - ADDITIONAL_REPOS / payload-derived path + Windows backslash normalization of model-emitted git `-C` paths differ from in-process fixtures
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== ST: git WRITE_PATTERNS / STRIP_KINDS retire (RED-pending-impl) ==="
assert_eq "ST1 WRITE_PATTERNS git count == 0" "0" "$(kind_count git)"
assert_eq "ST2 STRIP_KINDS has no git"        "false" "$(strip_has git)"

echo "=== GW: isGitWriteIR — 18 write forms true (RED-pending-impl) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'GW_TABLE'
GW01 commit^git commit -m x^true
GW02 push^git push^true
GW03 merge^git merge feature^true
GW04 rebase^git rebase main^true
GW05 reset^git reset --hard^true
GW06 am^git am patch.mbox^true
GW07 apply^git apply patch.diff^true
GW08 cherry-pick^git cherry-pick abc^true
GW09 revert^git revert abc^true
GW10 restore^git restore f^true
GW11 update-ref^git update-ref refs/heads/x abc^true
GW12 tag write^git tag v1^true
GW13 branch mutate -D^git branch -D old^true
GW14 checkout force^git checkout -- f^true
GW15 stash push^git stash push^true
GW16 worktree add^git worktree add ../wt^true
GW17 add-history^git add docs/history.md^true
GW18 merge-file write^git merge-file a b c^true
GW-add-changelog CHANGELOG.md path → true^git add CHANGELOG.md^true
GW-BUG1-seq read-then-write^git status && git commit -m x^true
GW-BUG1-seq write-then-read^git commit -m x && git status^true
GW-BUG1-seq write-in-middle^git status && git push && git log^true
GW_TABLE

echo "=== GR: isGitWriteIR — read forms false (RED-pending-impl) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'GR_TABLE'
GR1 status false^git status^false
GR2 log false^git log^false
GR3 merge-base false^git merge-base a b^false
GR4 merge-tree false^git merge-tree a b^false
GR5 tag -l false^git tag -l^false
GR6 stash list false^git stash list^false
GR7 add . (no history path) false^git add .^false
GR-add-nonhistory non-history path false^git add src/foo.js^false
GR-add-patch interactive patch no path false^git add -p^false
GR-add-dashdash no path args false^git add --^false
GR-BUG1-seq all-read false^git status && git log^false
GR_TABLE

echo "=== C2: SECURITY global-flag order (RED-pending-impl) ==="
# resolveGitSubArgv must skip leading global flags so the subcommand is reached.
# Without it a global flag shifts argv and the write subcommand is missed →
# fast-allow with no scope enforcement.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'C2_TABLE'
C2-1 -C path then commit^git -C /other commit^true
C2-2 --no-pager then push^git --no-pager push^true
C2-3 -c sshCommand then commit^git -c core.sshCommand=x commit^true
C2-4 --config-env separated then commit^git --config-env core.hooksPath=VAR commit^true
C2-5 --config-env=attached then commit^git --config-env=core.hooksPath=VAR commit^true
C2_TABLE

echo "=== C3: SECURITY config-injection reachability (RED-pending-impl) ==="
# git -c key=val / --config-env must keep the command reaching the safety
# predicate even when the subcommand is READ — else the config-injection
# fast-allows past hasGitHooksBypass after the git WRITE_PATTERNS retire.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'C3_TABLE'
C3-1 -c hooksPath then status → true^git -c core.hooksPath=/tmp status^true
C3-2 --config-env then status → true^git --config-env core.hooksPath=VAR status^true
C3-3 -c arbitrary key then log → true^git -c foo.bar=baz log^true
C3-4 plain status false (no injection)^git status^false
C3-5 -C then log false (no injection)^git -C /x log^false
C3_TABLE

echo "=== CL: classify fail-before-fix for git (RED-pending-impl) ==="
assert_eq "CL1 classify(git commit) → read post-retire" "read" "$(classify_ir 'git commit -m x')"
# Sanity: read git stays read (PASS now and after).
assert_eq "CL2 classify(git status) → read (sanity)" "read" "$(classify_ir 'git status')"

echo "=== IC: isReadOnlyInterpreterC git guard (PASS now — #820) ==="
# bash -c 'git commit' must NOT demote to read — #820 single-segment bare git
# guard already present, independent of WRITE_PATTERNS.
assert_eq "IC1 bash -c git commit → not read-only" "false" "$(ro_interp_c 'bash -c "git commit"')"

echo "=== EX: extractGitWriteTargets self-target contract (RED-pending-impl) ==="
# Bridge: guards require() so a missing module emits ERROR rather than crashing.
extract_git() {
  local cmd="$1" repo="$2"
  # MSYS_NO_PATHCONV=1: Git-Bash rewrites POSIX-absolute argv (e.g. /repo) into a
  # Windows path (C:/Program Files/Git/repo) before node sees it, mangling the
  # fixture. Disable that conversion so /repo reaches the extractor verbatim.
  MSYS_NO_PATHCONV=1 run_with_timeout 30 node -e "
    let m; try { m=require('${WT_NODE}/hooks/lib/bash-write-targets/git'); }
    catch (e) { process.stdout.write('ERROR:no-module'); process.exit(0); }
    if (typeof m.extractGitWriteTargets !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    const ir=parse(process.argv[1]);
    const repoArg = process.argv[2] === '__NULL__' ? null : process.argv[2];
    try { process.stdout.write(JSON.stringify(m.extractGitWriteTargets(ir, repoArg))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$cmd" "$repo" 2>/dev/null
}
assert_eq "EX1 git commit + /repo → self-target" '[{"resolveVia":"self","path":"/repo"}]' "$(extract_git 'git commit -m x' '/repo')"
assert_eq "EX2 git commit + null repoRoot → null (fail-closed)" 'null' "$(extract_git 'git commit -m x' '__NULL__')"
assert_eq "EX3 git status + /repo → [] (non-write)" '[]' "$(extract_git 'git status' '/repo')"

echo "=== MG: collectBashWriteTargets git merge (RED-pending-impl) ==="
# Two-arg collectBashWriteTargets(ir, repoRoot) merges the git self-target.
collect_git() {
  local cmd="$1" repo="$2" omit="$3"
  # MSYS_NO_PATHCONV=1: see extract_git — keep the POSIX fixture path (/repo)
  # from being rewritten by Git-Bash before node argv parsing.
  MSYS_NO_PATHCONV=1 run_with_timeout 30 node -e "
    const {collectBashWriteTargets}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    const ir=parse(process.argv[1]);
    const omit = process.argv[3] === 'omit';
    const repoArg = process.argv[2] === '__NULL__' ? null : process.argv[2];
    try {
      const out = omit ? collectBashWriteTargets(ir) : collectBashWriteTargets(ir, repoArg);
      process.stdout.write(JSON.stringify(out));
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$cmd" "$repo" "$omit" 2>/dev/null
}
assert_eq "MG1 collect(git commit,/repo) → self-target, no parseFailure" \
  '{"targets":[{"resolveVia":"self","path":"/repo"}],"parseFailure":false}' \
  "$(collect_git 'git commit -m x' '/repo' no)"
# MG2: null repoRoot for a git write → parseFailure true (fail-closed). We assert
# the parseFailure flag is true (targets may be null); check the substring.
mg2="$(collect_git 'git commit -m x' '__NULL__' no)"
if echo "$mg2" | grep -q '"parseFailure":true'; then
  pass "MG2 collect(git commit,null) → parseFailure true (fail-closed)"
else
  fail "MG2 collect(git commit,null) → expected parseFailure true, got ($mg2)"
fi
# MG3: repoRoot omitted → back-compat, git skipped → targets null.
assert_eq "MG3 collect(git commit) omitted repoRoot → targets null (back-compat)" \
  '{"targets":null,"parseFailure":false}' \
  "$(collect_git 'git commit -m x' '/repo' omit)"
# MG-nongit-2arg: the two-arg form with a NON-git command + valid repoRoot must
# still produce the green rm ancestor target and MUST NOT inject a git self-target
# (git extraction only fires when isGitWriteIR(ir) is true). Passing repoRoot for
# a non-git command does not break the extractor pipeline. RED-pending-impl.
assert_eq "MG-nongit-2arg collect(rm /tmp/foo,/repo) → rm ancestor target only, no self-target" \
  '{"targets":[{"resolveVia":"ancestor","path":"/tmp/foo"}],"parseFailure":false}' \
  "$(collect_git 'rm /tmp/foo' '/repo' no)"

echo "=== L2: downstream reachability (RED-pending / preservation, HIGH) ==="
# git self-target must reach main-worktree-allows predicates (enforce-worktree.js
# lines 441-451), NOT terminate like gh's done(). Negative assertions on the
# actual block/allow decision.
TMP_ROOT="$(mk_tmp_root c3)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }

# Create a fast-forwardable branch so `git merge` is a genuine fast-forward.
git -C "$TMP_ROOT/main" checkout -q -b ff
echo "more" >> "$TMP_ROOT/main/README.md"
git -C "$TMP_ROOT/main" add README.md
git -C "$TMP_ROOT/main" commit -q --no-verify -m "ff commit"
git -C "$TMP_ROOT/main" checkout -q main

l2_decision() {
  local cmd="$1" cwd="$2"; shift 2
  local out; out="$(run_bash_guard "$cmd" "$cwd" ENFORCE_WORKTREE=on "$@")"
  echo "$out" | grep -q '"decision":"block"' && { echo block; return; }
  echo allow
}

# L2-1 (HIGH): fast-forward `git merge` from MAIN → ALLOW via
# isAllowedFastForwardMerge (proves self-target reaches line 444, not a
# terminating done()).
# isAllowedFastForwardMerge requires an explicit --ff-only flag at the merge
# subcommand position (standard.js:122), so the fixture uses `git merge --ff-only`.
assert_eq "L2-1 fast-forward git merge --ff-only from main → allow (reaches isAllowedFastForwardMerge)" \
  "allow" "$(l2_decision 'git merge --ff-only ff' "$REPO")"

# L2-2: non-ff `git commit` from main → BLOCK (main-checkout gate).
assert_eq "L2-2 git commit (non-ff) from main → block" \
  "block" "$(l2_decision 'git commit --allow-empty -m x' "$REPO")"

# L2-3: `git branch -D <checked-out>` from main → BLOCK via branch-delete gate.
assert_eq "L2-3 git branch -D checked-out branch from main → block (branch-delete gate)" \
  "block" "$(l2_decision 'git branch -D main' "$REPO")"

# L2-4 (SECURITY): git-hooks-bypass commit → BLOCK via git-hooks-bypass gate.
assert_eq "L2-4 git -c core.hooksPath=/dev/null commit → block (git-hooks-bypass)" \
  "block" "$(l2_decision 'git -c core.hooksPath=/dev/null commit -m x' "$REPO")"

# L2-5 (SECURITY C3): git -c core.hooksPath=/dev/null status (READ subcommand) →
# BLOCK via git-hooks-bypass. Proves the fast-allow gate does NOT exit early for
# a config-injection read command after the retire.
assert_eq "L2-5 git -c core.hooksPath=/dev/null status (read) → block (C3 reachability)" \
  "block" "$(l2_decision 'git -c core.hooksPath=/dev/null status' "$REPO")"

# L2-6: OUT-OF-SESSION `git commit` from a repo whose detected root is not a
# session root → should ALLOW via the line-325 self-target all-outside scope
# check. SKIPPED in this single-process fixture: getSessionRepoRoots always adds
# the CWD repo root, so a real git CWD is by construction in-scope — a true
# out-of-session *detected* root cannot be manufactured in-process (identical
# constraint documented in fix-1391 Section D SKIP). A non-git CWD is NOT a valid
# proxy here: `git commit` from a non-git dir hits repoRoot=null → fail-closed
# DENY (cannot determine repo root), which is the OPPOSITE decision and would
# mis-assert. The self-target all-outside allow branch needs the live hook's
# ADDITIONAL_REPOS / payload-derived-path wiring.
# L3 gap: only a live claude -p session with real ADDITIONAL_REPOS env proves the
# self-target all-outside → done() branch fires for an out-of-session git write.
skip "L2-6 out-of-session git commit ALLOW — needs multi-repo session-root wiring (see fix-1391 Section D); covered at L3"

echo "=== SB: SECURITY sequenced/redirect write-detection bypasses (BUG 1/2/3) ==="
# Fixture prep: an EXCLUDE-covered dir (.worktree-backup is a BUILTIN exclude) and
# a source file for the cp segment.
mkdir -p "$TMP_ROOT/main/.worktree-backup/x"
echo "src" > "$TMP_ROOT/main/src.txt"

# BUG 1: `git status && git commit` — first git segment is a read, but the second
# is a write. isGitWriteIR must scan ALL segments → the whole command is a write →
# reaches the main-worktree block (not fast-allowed). LIVE hook boundary.
assert_eq "SB1 (BUG1) git status && git commit from main → block" \
  "block" "$(l2_decision 'git status && git commit --allow-empty -m x' "$REPO")"

# BUG 2 (git): `cp <excluded> && git commit` — the file segment is EXCLUDE-covered,
# but the git-write segment's self-target is repoRoot (NOT EXCLUDE-covered) →
# isEverySegmentExcluded must return false → block. Was ALLOWED before the fix.
assert_eq "SB2 (BUG2-git) cp .worktree-backup/x/f && git commit from main → block" \
  "block" "$(l2_decision 'cp src.txt .worktree-backup/x/f && git commit --allow-empty -m pwned' "$REPO")"

# BUG 2 (gh): a gh-write segment has no local file target — an EXCLUDE file pattern
# can never satisfy it. isEverySegmentExcluded must fail closed (return false) for
# any gh-write segment. Asserted at the unit level (the live hook routes this whole
# command through the earlier gh session-scope branch, which allows in-scope gh
# writes — an in-process fixture repo is always in scope, mirror of L2-6 SKIP).
sb3_ese() {
  MSYS_NO_PATHCONV=1 run_with_timeout 30 node -e "
    const {isEverySegmentExcluded}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {getExcludePatterns}=require('${WT_NODE}/hooks/enforce-worktree/shared-cmd-utils');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    const ir=parse(process.argv[1]);
    process.stdout.write(String(isEverySegmentExcluded(ir, process.argv[2], getExcludePatterns())));
  " -- "$1" "$2" 2>/dev/null
}
assert_eq "SB3 (BUG2-gh) isEverySegmentExcluded(cp .worktree-backup && gh pr merge) → false (fail-closed, no gh EXCLUDE)" \
  "false" "$(sb3_ese 'cp src.txt .worktree-backup/x/f && gh pr merge 123' "$REPO")"

# Control (no over-block): a legit all-excluded sequenced file write must still
# ALLOW (fix-739 R2/R2a preservation).
assert_eq "SB4 control mkdir -p .worktree-backup/x && cp → allow (no over-block)" \
  "allow" "$(l2_decision 'mkdir -p .worktree-backup/x && cp src.txt .worktree-backup/x/f' "$REPO")"

# BUG 3: `echo x > sub/dev/null` — a real in-scope file, NOT the null device.
# Exact-match /dev/null skip means this is a detected write → block. Control
# `echo x > /dev/null` (exact null device) stays read → allow.
assert_eq "SB5 (BUG3) echo x > sub/dev/null from main → block (real in-scope file)" \
  "block" "$(l2_decision 'echo x > sub/dev/null' "$REPO")"
assert_eq "SB6 (BUG3) echo x > /dev/null from main → allow (null device, exact match)" \
  "allow" "$(l2_decision 'echo x > /dev/null' "$REPO")"

report_totals
exit "$FAIL"
