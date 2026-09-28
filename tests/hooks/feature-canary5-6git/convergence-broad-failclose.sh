#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/convergence-broad-failclose.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/git-write-ir.js, hooks/enforce-worktree/git-repo-detection.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, git-write, security, scope:issue-specific, hook-registration, pwsh-not-required
# Convergence: isGitWriteIR is a BROAD FAIL-CLOSED net — "git AND not a known
# read" (basename form recognition + subcommand read-allowlist). FIX #2:
# findRepoRootForBash gives --work-tree precedence over -C for the write target.
# L3 gap (every L2 case): real PreToolUse dispatch only fires in a live claude -p
# session; live ADDITIONAL_REPOS / payload paths / backslash normalization differ.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight bin/check-verification-gate.sh: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# NO BYPASS — isGitWriteIR must be true for every write / unknown form (L1).
bq_hdr "=== CONV: NO BYPASS — isGitWriteIR true (L1) ==="
bq_table git_write <<'BYPASS_TABLE'
CB.1 path-qualified /usr/bin/git commit^/usr/bin/git commit -m x^true
CB.2 relative ./git commit^./git commit -m x^true
CB.3 git.exe commit^git.exe commit -m x^true
CB.4 git switch -f x (working-tree mutate)^git switch -f x^true
CB.5 git rm f^git rm f^true
CB.6 git mv a b^git mv a b^true
CB.7 git clean -fdx^git clean -fdx^true
CB.8 bare git stash (defaults to push)^git stash^true
CB.9 git stash save m^git stash save m^true
CB.10 git worktree move a b^git worktree move a b^true
CB.11 git notes add^git notes add^true
CB.12 unknown git some-future-cmd → write^git some-future-cmd^true
CB.13 env -Z v git commit (safety net)^env -Z v git commit -m x^true
CB.14 stdbuf -oL /usr/bin/git commit^stdbuf -oL /usr/bin/git commit -m x^true
CB.15 git restore f (working-tree mutate)^git restore f^true
CB.16 git checkout main (working-tree mutate)^git checkout main^true
CB.17 git remote add o url^git remote add o url^true
CB.18 git reflog expire^git reflog expire^true
CB.19 git config user.name x (key value write)^git config user.name x^true
CB.20 git tag -d v1^git tag -d v1^true
CB.21 git branch newb (create)^git branch newb^true
CB.22 git branch -d old (delete)^git branch -d old^true
CB.23 /usr/bin/env git commit (FIXB path-qualified wrapper)^/usr/bin/env git commit -m x^true
CB.24 /usr/bin/nice git commit (FIXB path-qualified wrapper)^/usr/bin/nice git commit -m x^true
CB.25 /bin/nohup git commit (FIXB path-qualified wrapper)^/bin/nohup git commit -m x^true
CB.26 env -Z v /usr/bin/git commit (FIXB basename in safety net)^env -Z v /usr/bin/git commit -m x^true
CB.27 stdbuf -Z git.exe commit (FIXB basename in safety net)^stdbuf -Z git.exe commit -m x^true
BYPASS_TABLE

# NO OVER-BLOCK — common reads must stay isGitWriteIR false (L1).
bq_hdr "=== CONV: NO OVER-BLOCK — isGitWriteIR false (L1) ==="
bq_table git_write <<'READ_TABLE'
CR.1 git status^git status^false
CR.2 git log^git log^false
CR.3 git diff^git diff^false
CR.4 git show^git show^false
CR.5 git fetch^git fetch^false
CR.6 git branch (bare list)^git branch^false
CR.7 git branch -l^git branch -l^false
CR.8 git branch -a^git branch -a^false
CR.9 git tag (bare list)^git tag^false
CR.10 git tag -l^git tag -l^false
CR.11 git tag -v x (verify)^git tag -v x^false
CR.12 git tag -n (list annotated)^git tag -n^false
CR.13 git stash list^git stash list^false
CR.14 git worktree list^git worktree list^false
CR.15 git config --get user.name^git config --get user.name^false
CR.16 git config user.name (get, one arg)^git config user.name^false
CR.17 git remote -v^git remote -v^false
CR.18 git remote show o^git remote show o^false
CR.19 git rev-parse HEAD^git rev-parse HEAD^false
CR.20 git version^git version^false
CR.21 git --version (global flag only)^git --version^false
CR.22 git ls-files^git ls-files^false
CR.23 git for-each-ref^git for-each-ref^false
CR.24 git -C /x log^git -C /x log^false
CR.25 git reflog (bare show)^git reflog^false
CR.26 git reflog show^git reflog show^false
CR.27 git notes list^git notes list^false
CR.28 nice git log (wrapped read)^nice git log^false
CR.29 /usr/bin/env git status (FIXB wrapped read no over-block)^/usr/bin/env git status^false
READ_TABLE

# FIX #2 — wt_target mirrors findRepoRootForBash precedence: parseGitPathFlag
# (--work-tree) first, then parseGitCPath (-C).
bq_hdr "=== CONV FIX#2: --work-tree wins over -C for findRepoRootForBash target (L1) ==="
bq_row "FIX2.parse.1 both present → --work-tree wins" "/in-session/path" wt_target 'git -C /outside --work-tree /in-session/path commit'
bq_row "FIX2.parse.2 -C only → -C used" "/outside" wt_target 'git -C /outside commit'
bq_row "FIX2.parse.3 --work-tree only → --work-tree used" "/in-session/path" wt_target 'git --work-tree /in-session/path commit'

# L2 hook-boundary — bypass forms from MAIN worktree → BLOCK; outside → ALLOW.
bq_hdr "=== CONV L2: bypass forms from MAIN worktree → BLOCK ==="
TMP_ROOT="$(mk_tmp_root conv)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { bq_flush; skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }
echo "src" > "$TMP_ROOT/main/src.txt"

# Each is an isGitWriteIR write NOT in the main-worktree cleanup allow-list.
bq_row "CL2.1 /usr/bin/git commit from main → block" block guard "$REPO" '/usr/bin/git commit --allow-empty -m x'
bq_row "CL2.2 git switch from main → block" block guard "$REPO" 'git switch -c newbranch'
bq_row "CL2.3 git some-future-cmd from main → block (fail-closed)" block guard "$REPO" 'git some-future-cmd --do-thing'
bq_row "CL2.4 git notes add from main → block" block guard "$REPO" 'git notes add'

# FIX #2 root resolution is the load-bearing fix (the L2 decision would also
# depend on session-scope registration, not modeled here) → assert it directly.
bq_row "CL2.5 -C outside --work-tree in-session → root resolves to --work-tree (FIX2)" \
  "$REPO" frb "git -C /nonexistent-outside --work-tree $REPO commit --allow-empty -m x" "$TMP_ROOT"
bq_row "CL2.6 -C in-session only → root resolves to -C value" \
  "$REPO" frb "git -C $REPO commit --allow-empty -m x" "$TMP_ROOT"

# FIX A — a --work-tree / -C flag in a DIFFERENT segment, inside quoted text,
# relative, or env-var-driven must NOT re-scope the write → CWD repo ($REPO).
bq_hdr "=== CONV FIXA: cross-segment / quoted --work-tree cannot re-scope the write (L1) ==="
bq_row "FIXA.1 cross-segment --work-tree read + commit → CWD repo (in-session)" \
  "$REPO" frb 'git --work-tree /nonexistent-outside status && git commit --allow-empty -m x' "$REPO"
bq_row "FIXA.2 quoted --work-tree in printf + commit → CWD repo (in-session)" \
  "$REPO" frb 'printf "git --work-tree /nonexistent-outside" && git commit --allow-empty -m x' "$REPO"
bq_row "FIXA.3 relative --work-tree on write → fail-closed to CWD repo" \
  "$REPO" frb 'git --work-tree ../outside commit --allow-empty -m x' "$REPO"
bq_row "FIXA.4 env-var --work-tree on write → fail-closed to CWD repo" \
  "$REPO" frb 'git --work-tree $HOME/x commit --allow-empty -m x' "$REPO"

bq_hdr "=== CONV L2 controls: reads → ALLOW (no over-block) ==="
bq_row "CL2.C1 git status from main → allow" allow guard "$REPO" 'git status'
bq_row "CL2.C2 git branch -l from main → allow" allow guard "$REPO" 'git branch -l'
bq_row "CL2.C3 git remote -v from main → allow" allow guard "$REPO" 'git remote -v'
bq_flush

report_totals
exit "$FAIL"
