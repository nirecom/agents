#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/commit3-git.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets/git.js, hooks/enforce-worktree/bash-write-scope.js, hooks/lib/bash-write-patterns/classify.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, git-write, self-target, ir-extractor, security, scope:issue-specific, hook-registration, pwsh-not-required
# Commit 3 — git write IR extractor + git group retire + self-target routing.
# SECURITY: C2 (global-flag order) and C3 (config-injection) are security
# boundaries; L2 cases assert the actual block/allow decision, not an exit code.
# L3 gap (what this test does NOT catch):
# - real PreToolUse dispatch only fires in a live claude -p session (these L2 cases drive node enforce-worktree.js via stdin JSON)
# - ADDITIONAL_REPOS / payload-derived path + Windows backslash normalization of model-emitted git `-C` paths differ from in-process fixtures
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bq_hdr "=== ST: git WRITE_PATTERNS / STRIP_KINDS retire (RED-pending-impl) ==="
bq_row "ST1 WRITE_PATTERNS git count == 0" "0" kind_count git
bq_row "ST2 STRIP_KINDS has no git"        "false" strip_has git

bq_hdr "=== GW: isGitWriteIR — 18 write forms true (RED-pending-impl) ==="
bq_table git_write <<'GW_TABLE'
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

bq_hdr "=== GR: isGitWriteIR — read forms false (RED-pending-impl) ==="
bq_table git_write <<'GR_TABLE'
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

bq_hdr "=== C2: SECURITY global-flag order (RED-pending-impl) ==="
# resolveGitSubArgv must skip leading global flags so the subcommand is reached;
# otherwise a global flag shifts argv and the write subcommand is missed.
bq_table git_write <<'C2_TABLE'
C2-1 -C path then commit^git -C /other commit^true
C2-2 --no-pager then push^git --no-pager push^true
C2-3 -c sshCommand then commit^git -c core.sshCommand=x commit^true
C2-4 --config-env separated then commit^git --config-env core.hooksPath=VAR commit^true
C2-5 --config-env=attached then commit^git --config-env=core.hooksPath=VAR commit^true
C2_TABLE

bq_hdr "=== C3: SECURITY config-injection reachability (RED-pending-impl) ==="
# git -c key=val / --config-env must keep the command reaching the safety
# predicate even for a READ subcommand (else it fast-allows past hasGitHooksBypass).
bq_table git_write <<'C3_TABLE'
C3-1 -c hooksPath then status → true^git -c core.hooksPath=/tmp status^true
C3-2 --config-env then status → true^git --config-env core.hooksPath=VAR status^true
C3-3 -c arbitrary key then log → true^git -c foo.bar=baz log^true
C3-4 plain status false (no injection)^git status^false
C3-5 -C then log false (no injection)^git -C /x log^false
C3_TABLE

bq_hdr "=== CL: classify fail-before-fix for git (RED-pending-impl) ==="
bq_row "CL1 classify(git commit) → read post-retire" "read" classify 'git commit -m x'
# Sanity: read git stays read (PASS now and after).
bq_row "CL2 classify(git status) → read (sanity)" "read" classify 'git status'

bq_hdr "=== IC: isReadOnlyInterpreterC git guard (PASS now — #820) ==="
# bash -c 'git commit' must NOT demote to read (#820 bare git guard).
bq_row "IC1 bash -c git commit → not read-only" "false" ro_interp_c 'bash -c "git commit"'

bq_hdr "=== EX: extractGitWriteTargets self-target contract (RED-pending-impl) ==="
# __NULL__ = null repoRoot. Rows travel over stdin, so /repo is never MSYS-rewritten.
bq_row "EX1 git commit + /repo → self-target" '[{"resolveVia":"self","path":"/repo"}]' extract_git 'git commit -m x' '/repo'
bq_row "EX2 git commit + null repoRoot → null (fail-closed)" 'null' extract_git 'git commit -m x' '__NULL__'
bq_row "EX3 git status + /repo → [] (non-write)" '[]' extract_git 'git status' '/repo'

bq_hdr "=== MG: collectBashWriteTargets git merge (RED-pending-impl) ==="
# Two-arg collectBashWriteTargets(ir, repoRoot) merges the git self-target.
bq_row "MG1 collect(git commit,/repo) → self-target, no parseFailure" \
  '{"targets":[{"resolveVia":"self","path":"/repo"}],"parseFailure":false}' collect_git 'git commit -m x' '/repo' no
# MG2: null repoRoot for a git write → parseFailure true (fail-closed); targets
# may be null, so the op checks the "parseFailure":true substring.
bq_row "MG2 collect(git commit,null) → parseFailure true (fail-closed)" "true" collect_git_pf 'git commit -m x' '__NULL__' no
# MG3: repoRoot omitted → back-compat, git skipped → targets null.
bq_row "MG3 collect(git commit) omitted repoRoot → targets null (back-compat)" \
  '{"targets":null,"parseFailure":false}' collect_git 'git commit -m x' '/repo' omit
# MG-nongit-2arg: a NON-git command + valid repoRoot keeps the rm ancestor target
# and MUST NOT inject a git self-target (git extraction fires only on isGitWriteIR).
bq_row "MG-nongit-2arg collect(rm /tmp/foo,/repo) → rm ancestor target only, no self-target" \
  '{"targets":[{"resolveVia":"ancestor","path":"/tmp/foo"}],"parseFailure":false}' collect_git 'rm /tmp/foo' '/repo' no

bq_hdr "=== L2: downstream reachability (RED-pending / preservation, HIGH) ==="
# git self-target must reach main-worktree-allows predicates, NOT terminate like
# gh's done(). Negative assertions on the actual block/allow decision.
TMP_ROOT="$(mk_tmp_root c3)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { bq_flush; skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }

# Create a fast-forwardable branch so `git merge` is a genuine fast-forward.
git -C "$TMP_ROOT/main" checkout -q -b ff
echo "more" >> "$TMP_ROOT/main/README.md"
git -C "$TMP_ROOT/main" add README.md
git -C "$TMP_ROOT/main" commit -q --no-verify -m "ff commit"
git -C "$TMP_ROOT/main" checkout -q main

# L2-1 (HIGH): `git merge --ff-only` from MAIN → ALLOW via isAllowedFastForwardMerge
# (needs the explicit --ff-only flag, standard.js:122).
bq_row "L2-1 fast-forward git merge --ff-only from main → allow (reaches isAllowedFastForwardMerge)" \
  allow guard "$REPO" 'git merge --ff-only ff'
bq_row "L2-2 git commit (non-ff) from main → block" block guard "$REPO" 'git commit --allow-empty -m x'
bq_row "L2-3 git branch -D checked-out branch from main → block (branch-delete gate)" \
  block guard "$REPO" 'git branch -D main'
bq_row "L2-4 git -c core.hooksPath=/dev/null commit → block (git-hooks-bypass)" \
  block guard "$REPO" 'git -c core.hooksPath=/dev/null commit -m x'
# L2-5 (SECURITY C3): a config-injection READ subcommand must not fast-allow.
bq_row "L2-5 git -c core.hooksPath=/dev/null status (read) → block (C3 reachability)" \
  block guard "$REPO" 'git -c core.hooksPath=/dev/null status'
# Flush before the SB fixture prep so L2-1..5 see the pre-prep working tree.
bq_flush

# L2-6: an out-of-session detected git root cannot be manufactured in-process
# (getSessionRepoRoots always adds the CWD repo; a non-git CWD fail-closes to
# DENY, the opposite decision) — see fix-1391 Section D.
# L3 gap: only a live claude -p session with real ADDITIONAL_REPOS proves it.
skip "L2-6 out-of-session git commit ALLOW — needs multi-repo session-root wiring (see fix-1391 Section D); covered at L3"

bq_hdr "=== SB: SECURITY sequenced/redirect write-detection bypasses (BUG 1/2/3) ==="
# Fixture prep: an EXCLUDE-covered dir (.worktree-backup is a BUILTIN exclude) and
# a source file for the cp segment.
mkdir -p "$TMP_ROOT/main/.worktree-backup/x"
echo "src" > "$TMP_ROOT/main/src.txt"

# BUG 1: a later git-write segment makes the whole command a write → block.
bq_row "SB1 (BUG1) git status && git commit from main → block" \
  block guard "$REPO" 'git status && git commit --allow-empty -m x'
# BUG 2 (git): the git self-target (repoRoot) is never EXCLUDE-covered → block.
bq_row "SB2 (BUG2-git) cp .worktree-backup/x/f && git commit from main → block" \
  block guard "$REPO" 'cp src.txt .worktree-backup/x/f && git commit --allow-empty -m pwned'
# BUG 2 (gh): a gh-write segment has no local file target, so isEverySegmentExcluded
# must fail closed (unit level; the live hook routes gh through its scope branch).
bq_row "SB3 (BUG2-gh) isEverySegmentExcluded(cp .worktree-backup && gh pr merge) → false (fail-closed, no gh EXCLUDE)" \
  false ese_default 'cp src.txt .worktree-backup/x/f && gh pr merge 123' "$REPO"
# Control (no over-block): a legit all-excluded sequenced file write still ALLOWs.
bq_row "SB4 control mkdir -p .worktree-backup/x && cp → allow (no over-block)" \
  allow guard "$REPO" 'mkdir -p .worktree-backup/x && cp src.txt .worktree-backup/x/f'
# BUG 3: `> sub/dev/null` is a real in-scope file; exact `/dev/null` stays read.
bq_row "SB5 (BUG3) echo x > sub/dev/null from main → block (real in-scope file)" \
  block guard "$REPO" 'echo x > sub/dev/null'
bq_row "SB6 (BUG3) echo x > /dev/null from main → allow (null device, exact match)" \
  allow guard "$REPO" 'echo x > /dev/null'
bq_flush

report_totals
exit "$FAIL"
