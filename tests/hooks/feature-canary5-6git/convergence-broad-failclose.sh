#!/usr/bin/env bash
# tests/feature-canary5-6git/convergence-broad-failclose.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/git-write-ir.js, hooks/enforce-worktree/git-repo-detection.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, git-write, security, scope:issue-specific, hook-registration, pwsh-not-required
#
# Convergence redesign: isGitWriteIR is now a BROAD FAIL-CLOSED safety net —
# "git AND not a known read". FORM recognition is by BASENAME (path-qualified /
# .exe / wrapped git all resolve to git). SUBCOMMAND classification is a
# read-allowlist: any subcommand not in the allowlist (and not classified read by
# the flag-conditioned logic) defaults to WRITE. This closes the invocation-form
# gap class definitively — unknown/future/exotic git subcommands can no longer
# fast-allow past the main-worktree guard.
#
# FIX #2: findRepoRootForBash gives --work-tree precedence over -C for the write
# target (the working tree selected by --work-tree is authoritative for WHERE the
# write lands).
#
# L3 gap (every L2 case): real PreToolUse dispatch only fires in a live claude -p
# session. These L2 cases drive `node hooks/enforce-worktree.js` over stdin JSON;
# live-session ADDITIONAL_REPOS / payload-derived path / Windows backslash
# normalization differ from in-process fixtures. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight bin/check-verification-gate.sh: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# NO BYPASS — isGitWriteIR must be true for every write / unknown form (L1).
# ---------------------------------------------------------------------------
echo "=== CONV: NO BYPASS — isGitWriteIR true (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'BYPASS_TABLE'
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

# ---------------------------------------------------------------------------
# NO OVER-BLOCK — common reads must stay isGitWriteIR false (L1).
# ---------------------------------------------------------------------------
echo "=== CONV: NO OVER-BLOCK — isGitWriteIR false (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'READ_TABLE'
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

# ---------------------------------------------------------------------------
# FIX #2 — --work-tree precedence over -C for the scope target (L1 path parse).
# ---------------------------------------------------------------------------
echo "=== CONV FIX#2: --work-tree wins over -C for findRepoRootForBash target (L1) ==="
wt_target() {
  # Prints the working-tree root findRepoRootForBash prefers by echoing the
  # --work-tree / -C precedence result. We assert the parseGitPathFlag(--work-tree)
  # value is chosen over parseGitCPath when both are present.
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const cmd=process.argv[1];
    const wt=m.parseGitPathFlag(cmd,'--work-tree');
    const c=m.parseGitCPath(cmd);
    // Mirror findRepoRootForBash precedence: --work-tree first, then -C.
    process.stdout.write(wt || c || 'null');
  " -- "$1" 2>/dev/null
}
assert_eq "FIX2.parse.1 both present → --work-tree wins" "/in-session/path" \
  "$(wt_target 'git -C /outside --work-tree /in-session/path commit')"
assert_eq "FIX2.parse.2 -C only → -C used" "/outside" \
  "$(wt_target 'git -C /outside commit')"
assert_eq "FIX2.parse.3 --work-tree only → --work-tree used" "/in-session/path" \
  "$(wt_target 'git --work-tree /in-session/path commit')"

# ---------------------------------------------------------------------------
# L2 hook-boundary — bypass forms from MAIN worktree → BLOCK; outside → ALLOW.
# ---------------------------------------------------------------------------
echo "=== CONV L2: bypass forms from MAIN worktree → BLOCK ==="
TMP_ROOT="$(mk_tmp_root conv)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }
echo "src" > "$TMP_ROOT/main/src.txt"

l2_decision() {
  local cmd="$1" cwd="$2"; shift 2
  local out; out="$(run_bash_guard "$cmd" "$cwd" ENFORCE_WORKTREE=on "$@")"
  echo "$out" | grep -q '"decision":"block"' && { echo block; return; }
  echo allow
}

# These bypass forms — run from cwd=REPO (an in-session main worktree) — must
# reach the main-worktree block, not fast-allow. Each is an isGitWriteIR write
# that is NOT in the main-worktree cleanup allow-list.
assert_eq "CL2.1 /usr/bin/git commit from main → block" \
  "block" "$(l2_decision '/usr/bin/git commit --allow-empty -m x' "$REPO")"
assert_eq "CL2.2 git switch from main → block" \
  "block" "$(l2_decision 'git switch -c newbranch' "$REPO")"
assert_eq "CL2.3 git some-future-cmd from main → block (fail-closed)" \
  "block" "$(l2_decision 'git some-future-cmd --do-thing' "$REPO")"
# git notes add is a write and NOT in the cleanup allow-list (unlike stash
# push/pop, restore, checkout --) → must block from main.
assert_eq "CL2.4 git notes add from main → block" \
  "block" "$(l2_decision 'git notes add' "$REPO")"

# FIX #2 (L1 root resolution): `-C outside --work-tree in-session` resolves the
# working-tree root to the --work-tree value (in-session), NOT the -C value. The
# clean block/allow outcome depends on session-scope registration (cwd-derived),
# which this fixture does not model; the ROOT RESOLUTION is the load-bearing fix
# and is asserted directly here (the L2 decision would additionally depend on
# whether that root is a registered session root).
assert_eq "CL2.5 -C outside --work-tree in-session → root resolves to --work-tree (FIX2)" \
  "$REPO" "$(run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const r=m.findRepoRootForBash(process.argv[1], process.argv[2]);
    process.stdout.write(r||'null');
  " -- "git -C /nonexistent-outside --work-tree $REPO commit --allow-empty -m x" "$TMP_ROOT")"
assert_eq "CL2.6 -C in-session only → root resolves to -C value" \
  "$REPO" "$(run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const r=m.findRepoRootForBash(process.argv[1], process.argv[2]);
    process.stdout.write(r||'null');
  " -- "git -C $REPO commit --allow-empty -m x" "$TMP_ROOT")"

# ---------------------------------------------------------------------------
# FIX A — segment-aware, quote-aware git write-scope resolution. A --work-tree /
# -C flag in a DIFFERENT segment or inside quoted text must NOT re-scope the
# write. The write is scoped to the CWD repo (in-session $REPO) → the mis-scope
# "outside" bypass is closed. findRepoRootForBash is asserted directly (root
# resolution is the load-bearing fix; the L2 block additionally depends on
# session-scope registration, not modeled by this fixture).
# ---------------------------------------------------------------------------
echo "=== CONV FIXA: cross-segment / quoted --work-tree cannot re-scope the write (L1) ==="
frb() {
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const r=m.findRepoRootForBash(process.argv[1], process.argv[2]);
    process.stdout.write(r||'null');
  " -- "$1" "$2" 2>/dev/null
}
# cross-segment: outside --work-tree lives on a READ segment; the later commit
# carries no scope flag → scopes to the CWD repo ($REPO), NOT /nonexistent-outside.
assert_eq "FIXA.1 cross-segment --work-tree read + commit → CWD repo (in-session)" \
  "$REPO" "$(frb 'git --work-tree /nonexistent-outside status && git commit --allow-empty -m x' "$REPO")"
# quoted: the flag is inside a printf argument token, never a git global option →
# the commit scopes to the CWD repo.
assert_eq "FIXA.2 quoted --work-tree in printf + commit → CWD repo (in-session)" \
  "$REPO" "$(frb 'printf "git --work-tree /nonexistent-outside" && git commit --allow-empty -m x' "$REPO")"
# fail-closed: a write segment carrying a RELATIVE --work-tree is ambiguous →
# scope forced to the CWD repo (in-session), never an "outside" self-target.
assert_eq "FIXA.3 relative --work-tree on write → fail-closed to CWD repo" \
  "$REPO" "$(frb 'git --work-tree ../outside commit --allow-empty -m x' "$REPO")"
# fail-closed: env-var --work-tree (unresolvable pre-expansion) → CWD repo.
assert_eq "FIXA.4 env-var --work-tree on write → fail-closed to CWD repo" \
  "$REPO" "$(frb 'git --work-tree $HOME/x commit --allow-empty -m x' "$REPO")"

echo "=== CONV L2 controls: reads → ALLOW (no over-block) ==="
assert_eq "CL2.C1 git status from main → allow" \
  "allow" "$(l2_decision 'git status' "$REPO")"
assert_eq "CL2.C2 git branch -l from main → allow" \
  "allow" "$(l2_decision 'git branch -l' "$REPO")"
assert_eq "CL2.C3 git remote -v from main → allow" \
  "allow" "$(l2_decision 'git remote -v' "$REPO")"

report_totals
exit "$FAIL"
