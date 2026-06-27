#!/bin/bash
# tests/fix-enforce-worktree-main-cleanup.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows.js
# Tags: worktree, enforce, hook, bin, git, security, interpreter-wrapper, fix-802, scope:common
# Tests for isAllowedMainWorktreeCleanup() — #297; isAllowedWorktreeCommand — #778, #802
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
GUARD_JS="${_A}/hooks/enforce-worktree.js"
ALLOWS_JS="${_A}/hooks/enforce-worktree/main-worktree-allows.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}
TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t mctest)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

# Main repo with NO linked worktrees
MAIN_CLEAN="$TMPBASE/main-clean"
mkdir -p "$MAIN_CLEAN"
git -C "$MAIN_CLEAN" init -q -b main
git -C "$MAIN_CLEAN" config user.email "test@example.com"
git -C "$MAIN_CLEAN" config user.name "Test"
git -C "$MAIN_CLEAN" config core.hooksPath /dev/null
git -C "$MAIN_CLEAN" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then MAIN_CLEAN_N="$(cygpath -m "$MAIN_CLEAN")"; else MAIN_CLEAN_N="$MAIN_CLEAN"; fi

# Main repo WITH one linked worktree
MAIN_DIRTY="$TMPBASE/main-dirty"
mkdir -p "$MAIN_DIRTY"
git -C "$MAIN_DIRTY" init -q -b main
git -C "$MAIN_DIRTY" config user.email "test@example.com"
git -C "$MAIN_DIRTY" config user.name "Test"
git -C "$MAIN_DIRTY" config core.hooksPath /dev/null
git -C "$MAIN_DIRTY" commit --allow-empty --no-verify -q -m init
git -C "$MAIN_DIRTY" worktree add -q -b feature-x "$TMPBASE/dirty-wt" 2>/dev/null
if command -v cygpath >/dev/null 2>&1; then MAIN_DIRTY_N="$(cygpath -m "$MAIN_DIRTY")"; else MAIN_DIRTY_N="$MAIN_DIRTY"; fi

# Separate unrelated repo for -C /other tests
OTHER_REPO="$TMPBASE/other"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config user.email "test@example.com"
git -C "$OTHER_REPO" config user.name "Test"
git -C "$OTHER_REPO" commit --allow-empty --no-verify -q -m init
if command -v cygpath >/dev/null 2>&1; then OTHER_N="$(cygpath -m "$OTHER_REPO")"; else OTHER_N="$OTHER_REPO"; fi

# Add DIRTY_WT_N — the actual worktree path of MAIN_DIRTY (needed for S38/S42)
if command -v cygpath >/dev/null 2>&1; then DIRTY_WT_N="$(cygpath -m "$TMPBASE/dirty-wt")"; else DIRTY_WT_N="$TMPBASE/dirty-wt"; fi

# MAIN_VERY_DIRTY — 2 linked worktrees (wtCount=3) for S34
MAIN_VERY_DIRTY="$TMPBASE/main-very-dirty"
mkdir -p "$MAIN_VERY_DIRTY"
git -C "$MAIN_VERY_DIRTY" init -q -b main
git -C "$MAIN_VERY_DIRTY" config user.email "test@example.com"
git -C "$MAIN_VERY_DIRTY" config user.name "Test"
git -C "$MAIN_VERY_DIRTY" config core.hooksPath /dev/null
git -C "$MAIN_VERY_DIRTY" commit --allow-empty --no-verify -q -m init
git -C "$MAIN_VERY_DIRTY" worktree add -q -b feature-a "$TMPBASE/very-dirty-wt1" 2>/dev/null
git -C "$MAIN_VERY_DIRTY" worktree add -q -b feature-b "$TMPBASE/very-dirty-wt2" 2>/dev/null
if command -v cygpath >/dev/null 2>&1; then MAIN_VERY_DIRTY_N="$(cygpath -m "$MAIN_VERY_DIRTY")"; else MAIN_VERY_DIRTY_N="$MAIN_VERY_DIRTY"; fi

check_mc() {
  run_with_timeout node -e "
    const {isAllowedMainWorktreeCleanup}=require('$GUARD_JS');
    console.log(isAllowedMainWorktreeCleanup(process.argv[1],process.argv[2])?'allow':'reject');
  " -- "$1" "$2" 2>/dev/null
}
assert_allow() { local got; got="$(check_mc "$1" "$2")"; [ "$got" = "allow"  ] && pass "$3" || fail "$3 (got=$got)"; }
assert_block() { local got; got="$(check_mc "$1" "$2")"; [ "$got" = "reject" ] && pass "$3" || fail "$3 (got=$got)"; }

check_wc() {
  run_with_timeout node -e "
    const {isAllowedWorktreeCommand}=require('$ALLOWS_JS');
    console.log(isAllowedWorktreeCommand(process.argv[1],process.argv[2])?'allow':'reject');
  " -- "$1" "$2" 2>/dev/null
}
assert_allow_wc() { local got; got="$(check_wc "$1" "$2")"; [ "$got" = "allow"  ] && pass "$3" || fail "$3 (got=$got)"; }
assert_block_wc() { local got; got="$(check_wc "$1" "$2")"; [ "$got" = "reject" ] && pass "$3" || fail "$3 (got=$got)"; }

# Allow: no linked worktrees
assert_allow "git stash push -m wip"           "$MAIN_CLEAN_N" "S1: stash push (no linked WT)"
assert_allow "git stash pop"                    "$MAIN_CLEAN_N" "S2: stash pop"
assert_allow "git stash apply stash@{0}"        "$MAIN_CLEAN_N" "S3: stash apply"
assert_allow "git stash drop stash@{0}"         "$MAIN_CLEAN_N" "S4: stash drop"
assert_allow "git stash clear"                  "$MAIN_CLEAN_N" "S5: stash clear"
assert_allow "git stash -u"                     "$MAIN_CLEAN_N" "S6: stash -u (push variant)"
assert_allow "git checkout -- README.md"        "$MAIN_CLEAN_N" "S7: checkout -- file"
assert_allow "git checkout HEAD -- README.md"   "$MAIN_CLEAN_N" "S8: checkout HEAD -- file"
assert_allow "git restore README.md"            "$MAIN_CLEAN_N" "S9: restore file"
assert_allow "git restore --staged README.md"   "$MAIN_CLEAN_N" "S10: restore --staged"
assert_allow "git -C \"$MAIN_CLEAN_N\" stash pop" "$MAIN_CLEAN_N" "S10b: -C repoRoot stash"

# Block: linked worktree exists — cleanup NOT complete
assert_block "git stash push"                   "$MAIN_DIRTY_N" "S11: stash blocked (linked WT exists)"
assert_block "git stash pop"                    "$MAIN_DIRTY_N" "S12: stash pop blocked (linked WT)"
assert_block "git restore README.md"            "$MAIN_DIRTY_N" "S13: restore blocked (linked WT)"

# Block: out-of-scope stash subcommands
assert_block "git stash branch newbranch"       "$MAIN_CLEAN_N" "S14: stash branch blocked"
assert_block "git stash show"                   "$MAIN_CLEAN_N" "S15: stash show blocked"
assert_block "git stash store sha"              "$MAIN_CLEAN_N" "S16: stash store blocked"
assert_block "git stash create"                 "$MAIN_CLEAN_N" "S17: stash create blocked"
assert_block "git stash list"                   "$MAIN_CLEAN_N" "S18: stash list blocked"

# Block: restore --source (rewrite from arbitrary tree)
assert_block "git restore --source=HEAD~1 f"   "$MAIN_CLEAN_N" "S19: restore --source= blocked"
assert_block "git restore --source HEAD~1 f"   "$MAIN_CLEAN_N" "S20: restore --source <tree> blocked"

# Block: checkout without -- separator (branch switch)
assert_block "git checkout main"               "$MAIN_CLEAN_N" "S21: checkout branch blocked"
assert_block "git checkout -b feature/x"       "$MAIN_CLEAN_N" "S22: checkout -b blocked"
assert_block "git checkout -B feature/x"       "$MAIN_CLEAN_N" "S23: checkout -B blocked"
assert_block "git checkout -f main"            "$MAIN_CLEAN_N" "S24: checkout -f blocked"

# Block: shell chaining
assert_block "git stash pop && echo done"      "$MAIN_CLEAN_N" "S25: chaining blocked"

# Block: -C pointing at unrelated repo
assert_block "git -C \"$OTHER_N\" stash pop"  "$MAIN_CLEAN_N" "S26: -C /other blocked"

# === WORKTREE_END_SKILL=1 prefix handling (S27-S42, new behavior) ===
# S27-S29, S34, S36 FAIL until source changes are applied.
# S37/S38/S39/S42 retargeted to isAllowedWorktreeCommand (#778) — no-prefix forms.

# S27: skill-prefixed stash at wtCount=2 (linked WT present) → allow after fix
assert_allow "WORKTREE_END_SKILL=1 git -C \"$MAIN_DIRTY_N\" stash push -m tmp" "$MAIN_DIRTY_N" "S27: skill-prefixed stash push at wtCount=2 → allow (#705/#739b)"
# S28: no-prefix stash at wtCount=2 → block (current behavior unchanged)
assert_block "git -C \"$MAIN_DIRTY_N\" stash push -m tmp" "$MAIN_DIRTY_N" "S28: no-prefix stash push at wtCount=2 → block"
# S27b: skill-prefixed stash pop at wtCount=2 → allow (#1024)
assert_allow "WORKTREE_END_SKILL=1 git -C \"$MAIN_DIRTY_N\" stash pop" "$MAIN_DIRTY_N" "S27b: skill-prefixed stash pop at wtCount=2 → allow (#1024)"
# S29: skill-prefixed restore at wtCount=2 → allow after fix
assert_allow "WORKTREE_END_SKILL=1 git -C \"$MAIN_DIRTY_N\" restore README.md" "$MAIN_DIRTY_N" "S29: skill-prefixed restore at wtCount=2 → allow (#705)"
# S34: skill-prefixed stash at wtCount=3 → block (cap=2 even with prefix)
assert_block "WORKTREE_END_SKILL=1 git -C \"$MAIN_VERY_DIRTY_N\" stash push" "$MAIN_VERY_DIRTY_N" "S34: skill-prefixed stash at wtCount=3 → block (count cap)"
# S35: shell chaining → block (current behavior)
assert_block "git stash push && rm README.md" "$MAIN_CLEAN_N" "S35: chaining blocked"
# S36: skill-prefixed stash at wtCount=1 → allow after fix
assert_allow "WORKTREE_END_SKILL=1 git -C \"$MAIN_CLEAN_N\" stash push" "$MAIN_CLEAN_N" "S36: skill-prefixed stash at wtCount=1 → allow"
# S37: no-prefix worktree prune → allow via isAllowedWorktreeCommand (#778)
assert_allow_wc "git -C \"$MAIN_DIRTY_N\" worktree prune" "$MAIN_DIRTY_N" "S37: no-prefix worktree prune → allow via isAllowedWorktreeCommand (#778)"
# S38: no-prefix worktree remove → allow via isAllowedWorktreeCommand (#778)
assert_allow_wc "git -C \"$MAIN_DIRTY_N\" worktree remove \"$DIRTY_WT_N\"" "$MAIN_DIRTY_N" "S38: no-prefix worktree remove → allow via isAllowedWorktreeCommand (#778)"
# S39: no-prefix worktree prune --dry-run → allow via isAllowedWorktreeCommand (#778)
assert_allow_wc "git -C \"$MAIN_DIRTY_N\" worktree prune --dry-run" "$MAIN_DIRTY_N" "S39: no-prefix worktree prune --dry-run → allow via isAllowedWorktreeCommand (#778)"
# S42: no-prefix worktree remove --force → block via isAllowedWorktreeCommand (#778)
assert_block_wc "git -C \"$MAIN_DIRTY_N\" worktree remove --force \"$DIRTY_WT_N\"" "$MAIN_DIRTY_N" "S42: no-prefix worktree remove --force → block via isAllowedWorktreeCommand (#778)"
# S43: no-prefix worktree remove -f (short form) → block via isAllowedWorktreeCommand (#778)
assert_block_wc "git -C \"$MAIN_DIRTY_N\" worktree remove -f \"$DIRTY_WT_N\"" "$MAIN_DIRTY_N" "S43: no-prefix worktree remove -f → block (#778)"
# S44: path with semicolon + --force (quoted separator bypass guard) → block (#778)
assert_block_wc "git -C \"$MAIN_DIRTY_N\" worktree remove \"$MAIN_DIRTY_N/a;b\" --force" "$MAIN_DIRTY_N" "S44: quoted path with ; then --force → block (#778)"

# === #802 interpreter-wrapper bypass coverage (S45-S48) ===
# Direct git invocations remain ALLOW (S45/S46), but wrapping the same command
# inside `bash -c`/`sh -c` must BLOCK (S47/S48). The wrapper hides the inner
# command behind a quoted body that stripQuotedArgs collapses, neutering the
# hasShellChaining() guard. The fix must reject any cmd whose top-level token
# is an interpreter (bash/sh) carrying -c.
# S45: direct `git -C <main> worktree remove "<linked>"` → allow (regression pin)
assert_allow_wc "git -C \"$MAIN_DIRTY_N\" worktree remove \"$DIRTY_WT_N\"" "$MAIN_DIRTY_N" "S45: direct git worktree remove (regression pin) → allow"
# S46: direct `git -C <main> worktree prune` → allow (regression pin)
assert_allow_wc "git -C \"$MAIN_DIRTY_N\" worktree prune" "$MAIN_DIRTY_N" "S46: direct git worktree prune (regression pin) → allow"
# S47: `bash -c "git -C <main> worktree prune"` → block (#802 interpreter wrapper)
assert_block_wc "bash -c \"git -C $MAIN_DIRTY_N worktree prune\"" "$MAIN_DIRTY_N" "S47: bash -c 'git worktree prune' → block (#802)"
# S48: `sh -c 'git worktree remove /tmp/x'` → block (#802 interpreter wrapper)
assert_block_wc "sh -c 'git worktree remove /tmp/x'" "$MAIN_DIRTY_N" "S48: sh -c 'git worktree remove …' → block (#802)"

# === #820 rejectInterpreterAndChaining coverage for isAllowedMainWorktreeCleanup ===
# Mirrors S45-S48 pattern but targets the cleanup predicate (check_mc / assert_block).
# All S49-S60 RED until isAllowedMainWorktreeCleanup calls rejectInterpreterAndChaining.
# S61-S63 are regression pins: sudo/env/env-prefix followed by `git` (not an
# interpreter name) must still ALLOW — the helper must only fire on actual
# interpreter tokens.
#
# S49-S50: bash -c wraps cleanup commands.
assert_block "bash -c 'git stash'"                       "$MAIN_CLEAN_N" "S49: bash -c 'git stash' → block (#820 interp wrapper)"
assert_block "bash -c 'git restore .'"                   "$MAIN_CLEAN_N" "S50: bash -c 'git restore .' → block (#820 interp wrapper)"
# S51-S52: path-qualified interpreter (bash, python3) — same class.
assert_block "/bin/bash -c 'git stash'"                  "$MAIN_CLEAN_N" "S51: /bin/bash -c → block (#820 path-qualified)"
assert_block "/usr/bin/python3 -c 'import os;os.system(\"git stash\")'" "$MAIN_CLEAN_N" "S52: /usr/bin/python3 -c → block (#820 non-bash interp)"
# S53-S55: launcher prefixes (env, sudo, chained).
assert_block "env bash -c 'git stash'"                   "$MAIN_CLEAN_N" "S53: env bash -c → block (#820 launcher)"
assert_block "sudo bash -c 'git stash'"                  "$MAIN_CLEAN_N" "S54: sudo bash -c → block (#820 launcher)"
assert_block "env sudo bash -c 'git stash'"              "$MAIN_CLEAN_N" "S55: env sudo bash -c → block (#820 chained launcher)"
# S56: lowercase env prefix.
assert_block "my_var=foo bash -c 'git stash'"            "$MAIN_CLEAN_N" "S56: my_var=foo bash -c → block (#820 lowercase env)"
# S57-S58: process substitution in stripped form.
assert_block "git stash <(cat /etc/passwd)"              "$MAIN_CLEAN_N" "S57: process substitution <(…) → block (#820 stripped-form operator)"
assert_block "git restore >(tee /etc/cron.d/evil)"       "$MAIN_CLEAN_N" "S58: process substitution >(…) → block (#820 stripped-form operator)"
# S59-S60: literal newline as operator in stripped form.
NL_CMD_1="$(printf 'git stash\nrm -rf /')"
assert_block "$NL_CMD_1"                                 "$MAIN_CLEAN_N" "S59: git stash + newline + rm -rf / → block (#820 literal newline)"
NL_CMD_2="$(printf 'git checkout main\ncurl evil.com')"
assert_block "$NL_CMD_2"                                 "$MAIN_CLEAN_N" "S60: git checkout + newline + curl → block (#820 literal newline)"

# S61-S63: sudo/env/env-prefix + `git` must NOT trigger the interpreter check.
# The next token after the launcher is `git`, not an interpreter name. These
# are ALLOW-by-cleanup-predicate-shape (still subject to other gates such as
# wtCount, but the interpreter check itself must be a no-op for these).
assert_allow "sudo git stash"                            "$MAIN_CLEAN_N" "S61: sudo git stash → allow (#820 sudo+git is safe)"
assert_allow "env git checkout HEAD -- README.md"        "$MAIN_CLEAN_N" "S62: env git checkout HEAD -- file → allow (#820 env+git is safe)"
assert_allow "my_var=foo git restore README.md"          "$MAIN_CLEAN_N" "S63: my_var=foo git restore → allow (#820 env-prefix+git is safe)"

echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
