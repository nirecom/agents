#!/usr/bin/env bash
# tests/bin/main-worktree-resolution.sh
# Tests: hooks/lib/main-worktree.js, bin/lib/main-worktree.sh, bin/main-worktree-root
# Tags: worktree, git, main-worktree, bin, hook, lib, scope:common
#
# js / sourced sh / CLI resolvers agree: main worktree = first porcelain entry, nothing when bare, separate-git-dir or non-git.
# Fixtures: (a) plain+linked, (b) --separate-git-dir+linked, (c) bare, (d) non-git; paths normalized (R3-1).

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

_TMP_ROOT="$(make_tmp)"; readonly _TMP_ROOT
trap 'rm -rf "$_TMP_ROOT"' EXIT
harness_isolate "$_TMP_ROOT/isolation"
unset CLAUDE_CODE_SESSION_ID
export GIT_CEILING_DIRECTORIES="$_TMP_ROOT"
export GIT_CONFIG_NOSYSTEM=1

MW_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/main-worktree.js"
MW_SH="$SCRIPT_CHECKOUT_ROOT/bin/lib/main-worktree.sh"
MW_CLI="$SCRIPT_CHECKOUT_ROOT/bin/main-worktree-root"
NULL_MARK="<null>"

# norm <path> — forward slashes, no trailing slash, lower-case on Windows.
norm() {
  local p="$1"
  [ -z "$p" ] && { printf ''; return; }
  if command -v cygpath >/dev/null 2>&1; then
    p="$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")"
    p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  fi
  p="${p//\\//}"
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

gitc() { git -c user.email=t@example.com -c user.name=t "$@"; }

# ── fixtures ────────────────────────────────────────────────────────────────
FX="$_TMP_ROOT/fx"
mkdir -p "$FX/a" "$FX/b" "$FX/c" "$FX/d/plain"

A_MAIN="$FX/a/main"
harness_git_init "$A_MAIN"
gitc -C "$A_MAIN" commit -q --allow-empty --no-verify -m init
gitc -C "$A_MAIN" worktree add -q -b feat-a "$FX/a/linked" 2>/dev/null
A_LINKED="$FX/a/linked"
mkdir -p "$A_LINKED/sub/dir"

# (b): the common dir does not end in /.git, so "dirname(common dir)" answers wrong here.
B_MAIN="$FX/b/main"
B_GITDIR="$FX/b/gitdir"
git init -q --separate-git-dir "$B_GITDIR" "$B_MAIN"
git -C "$B_MAIN" config core.hooksPath /dev/null
gitc -C "$B_MAIN" commit -q --allow-empty --no-verify -m init
gitc -C "$B_MAIN" worktree add -q -b feat-b "$FX/b/linked" 2>/dev/null
B_LINKED="$FX/b/linked"

C_BARE="$FX/c/bare.git"
git init -q --bare "$C_BARE"
git -C "$C_BARE" config core.hooksPath /dev/null
C_SEED="$FX/c/seed"
harness_git_init "$C_SEED"
gitc -C "$C_SEED" commit -q --allow-empty --no-verify -m init
git -C "$C_SEED" push -q "$C_BARE" HEAD:refs/heads/main 2>/dev/null
gitc -C "$C_BARE" worktree add -q -b feat-c "$FX/c/linked" main 2>/dev/null
C_LINKED="$FX/c/linked"

D_PLAIN="$FX/d/plain"

canon() { (cd "$1" && pwd -P); }
A_MAIN_N="$(norm "$(canon "$A_MAIN")")"
B_LINKED_N="$(norm "$(canon "$B_LINKED")")"
B_GITDIR_N="$(norm "$(canon "$B_GITDIR")")"
B_GITDIR_PARENT_N="$(norm "$(canon "$FX/b")")"

# ── resolver probes: each prints the normalized result, or NULL_MARK ───────
# js: null → NULL_MARK; load/throw error → "<error rc=N>".
probe_js() {
  local out rc
  out="$(cd "$_TMP_ROOT" && run_with_timeout 30 node -e '
    const { mainWorktreeOf } = require(process.argv[1]);
    const r = mainWorktreeOf(process.argv[2]);
    process.stdout.write(r === null ? "<null>" : String(r));
  ' "$(np "$MW_JS")" "$(np "$1")" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then printf '<error rc=%s>' "$rc"; return; fi
  if [ "$out" = "$NULL_MARK" ]; then printf '%s' "$NULL_MARK"; else norm "$out"; fi
}

# sh / cli: "empty output + rc 1" → NULL_MARK; anything else is reported raw.
_sh_result() {
  local out="$1" rc="$2"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then norm "$out"; return; fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then printf '%s' "$NULL_MARK"; return; fi
  printf '<rc=%s out=%s>' "$rc" "$out"
}

probe_sh() {
  local out rc
  out="$(cd "$_TMP_ROOT" && run_with_timeout 30 bash -c '. "$1" || exit 99; main_worktree_of "$2"' _ "$MW_SH" "$1" 2>/dev/null)"
  rc=$?
  _sh_result "$out" "$rc"
}

probe_cli() {
  local out rc
  out="$(cd "$_TMP_ROOT" && run_with_timeout 30 "$MW_CLI" "$1" 2>/dev/null)"
  rc=$?
  _sh_result "$out" "$rc"
}

# probe_cli_cwd <dir> — the no-argument form resolves from the current directory.
probe_cli_cwd() {
  local out rc
  out="$(cd "$1" && run_with_timeout 30 "$MW_CLI" 2>/dev/null)"
  rc=$?
  _sh_result "$out" "$rc"
}

# expect_all <label> <dir> <expected-normalized-or-NULL_MARK>
expect_all() {
  local label="$1" dir="$2" want="$3" got kind
  for kind in js sh cli; do
    got="$("probe_$kind" "$dir")"
    if [ "$got" = "$want" ]; then
      pass "$label [$kind] → $want"
    else
      fail "$label [$kind]" "want=$want got=$got"
    fi
  done
}

# ── cases ───────────────────────────────────────────────────────────────────
case_begin "MW-A plain repo: main and linked both resolve to main" "hooks/lib/main-worktree.js"
expect_all "MW-A1 from main" "$A_MAIN" "$A_MAIN_N"
expect_all "MW-A2 from linked" "$A_LINKED" "$A_MAIN_N"
expect_all "MW-A3 from linked subdir" "$A_LINKED/sub/dir" "$A_MAIN_N"
case_end

# (b): pinned to NULL_MARK (fail closed), not to b/main. git 2.53 porcelain names the git dir
# (not b/main) as the first entry, and nothing records b/main from the linked side, so b/main
# cannot be proven; all three resolvers therefore reject a common dir whose basename is not
# `.git` (hooks/lib/main-worktree.js header). Any directory answer — b/main included — fails.
# expect_b_null names the wrong directory taken, so a regression reads as what broke.
expect_b_null() {
  local label="$1" dir="$2" got kind
  for kind in js sh cli; do
    got="$("probe_$kind" "$dir")"
    if [ "$got" = "$NULL_MARK" ]; then
      pass "$label [$kind] → $NULL_MARK (fail closed)"
    elif [ "$got" = "$B_LINKED_N" ]; then
      fail "$label [$kind] linked worktree taken for the main worktree" "got=$got"
    elif [ "$got" = "$B_GITDIR_N" ]; then
      fail "$label [$kind] separate git dir (porcelain first entry) taken for the main worktree" "got=$got"
    elif [ "$got" = "$B_GITDIR_PARENT_N" ]; then
      fail "$label [$kind] dirname(common dir) taken for the main worktree" "got=$got"
    else
      fail "$label [$kind] want $NULL_MARK (fail closed)" "got=$got"
    fi
  done
}

case_begin "MW-B separate-git-dir: resolves to nothing (fail closed)" "bin/lib/main-worktree.sh"
expect_b_null "MW-B1 from main" "$B_MAIN"
case_end

case_begin "MW-B protection: linked worktree of a separate-git-dir repo resolves to nothing" "bin/lib/main-worktree.sh"
expect_b_null "MW-B2 from linked" "$B_LINKED"
case_end

case_begin "MW-C bare repo resolves to nothing" "bin/main-worktree-root"
expect_all "MW-C1 bare repo dir" "$C_BARE" "$NULL_MARK"
expect_all "MW-C2 linked worktree of a bare repo" "$C_LINKED" "$NULL_MARK"
case_end

case_begin "MW-D non-git directory resolves to nothing" "bin/main-worktree-root"
expect_all "MW-D1 plain dir" "$D_PLAIN" "$NULL_MARK"
expect_all "MW-D2 missing dir" "$FX/d/does-not-exist" "$NULL_MARK"
case_end

case_begin "MW-CLI no-argument form uses the current directory" "bin/main-worktree-root"
assert_eq "$(probe_cli_cwd "$A_LINKED")" "$A_MAIN_N"
assert_eq "$(probe_cli_cwd "$D_PLAIN")" "$NULL_MARK"
case_end

# same_repository decides by the physical git common dir, so a layout main_worktree_of refuses
# (separate-git-dir, bare) still reads as one repository; a refused layout never reads as "different".
same_rc() {
  (cd "$_TMP_ROOT" && run_with_timeout 30 bash -c '. "$1" || exit 99; same_repository "$2" "$3"; echo $?' _ "$MW_SH" "$1" "$2" 2>/dev/null | tail -n 1)
}

case_begin "MW-E same_repository: worktrees of one repository are the same, even for layouts main_worktree_of refuses" "bin/lib/main-worktree.sh"
assert_eq "$(same_rc "$A_MAIN" "$A_LINKED")" "0"
assert_eq "$(same_rc "$B_MAIN" "$B_LINKED")" "0"
assert_eq "$(same_rc "$C_BARE" "$C_LINKED")" "0"
case_end

case_begin "MW-F same_repository: distinct repositories and non-git directories are different" "bin/lib/main-worktree.sh"
assert_eq "$(same_rc "$A_MAIN" "$B_MAIN")" "1"
assert_eq "$(same_rc "$A_LINKED" "$B_LINKED")" "1"
assert_eq "$(same_rc "$A_MAIN" "$D_PLAIN")" "1"
assert_eq "$(same_rc "$A_MAIN" "$FX/d/does-not-exist")" "1"
case_end

# A symlinked path reaches the same physical common dir; the comparison must not read it as another repository.
case_begin "MW-G same_repository: a symlinked worktree path is the same repository as its target's siblings" "bin/lib/main-worktree.sh"
A_LINK="$FX/a-main-link"
ln -s "$A_MAIN" "$A_LINK" 2>/dev/null || true
if [ -L "$A_LINK" ]; then
  assert_eq "$(same_rc "$A_LINK" "$A_LINKED")" "0"
  assert_eq "$(same_rc "$A_LINK" "$B_MAIN")" "1"
else
  skip "symlinks cannot be created on this host"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
