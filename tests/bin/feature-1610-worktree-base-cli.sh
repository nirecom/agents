#!/usr/bin/env bash
# Tests: bin/worktree-base
# Tags: feature-1610, feature-1849, worktree-base, cli, worktree, in-repo-base, usage-error, config-dependent, scope:issue-specific, TL2, pwsh-not-required
# TL3 gap: a real worker-dispatch child that receives WORKTREE_BASE_DIR through envPassthrough.
#
# #1610 / #1849: bin/worktree-base prints WORKTREE_BASE= / MAIN_DIR= / WORKTREE_BASE_SOURCE= for
# the repo holding --repo <dir> (default: the CWD); the resolution itself is owned by
# hooks/lib/worktree-base.js (covered by tests/hooks/feature-1610-worktree-base-resolver.js).
# Every call pins HOME/USERPROFILE and the global .env (AGENTS_MAIN_ROOT) to fixture dirs and
# WORKTREE_BASE_DIR per case, and runs from a fixture CWD, never the worktree.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

set -euo pipefail

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

CLI="$SCRIPT_CHECKOUT_ROOT/bin/worktree-base"

# real <dir> — the long-name native form node and git report (no 8.3 names, forward slashes).
real() { node -p 'require("fs").realpathSync.native(process.argv[1]).replace(/\\/g, "/")' "$(np "$1")"; }
# norm <path> — the comparison key: forward slashes, no trailing slash, lower-case.
norm() { local p="${1//\\//}"; p="${p%/}"; printf '%s' "$p" | tr '[:upper:]' '[:lower:]'; }

SB="$(real "$TMP_ROOT")"
FX_HOME="$SB/home"
FX_CONF="$SB/conf"
mkdir -p "$FX_HOME" "$FX_CONF"

MAIN="$SB/repos/main"
mkdir -p "$MAIN"
harness_git_init "$MAIN"
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config commit.gpgsign false
printf 'fixture\n' >"$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -q --no-verify -m initial
LINKED="$SB/linked/main"
git -C "$MAIN" worktree add -q -b feature/linked "$LINKED"
SUBDIR="$MAIN/sub/deeper"
mkdir -p "$SUBDIR"
OUTSIDE="$SB/not-a-repo"
mkdir -p "$OUTSIDE"
DEFAULT_BASE="$MAIN/.claude/worktrees"

OUT="" ERR="" RC=0
# cli <cwd> <base|-> [args...] — run the CLI; '-' leaves WORKTREE_BASE_DIR unset. Sets OUT/ERR/RC.
cli() {
  local cwd="$1" base="$2"
  shift 2
  local -a envset=(env -u WORKTREE_BASE_DIR -u CLAUDE_CODE_SESSION_ID "HOME=$FX_HOME" "USERPROFILE=$FX_HOME" "AGENTS_MAIN_ROOT=$FX_CONF")
  if [[ "$base" != "-" ]]; then envset+=("WORKTREE_BASE_DIR=$base"); fi
  RC=0
  (cd "$cwd" && "${envset[@]}" bash "$CLI" "$@") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
  OUT="$(cat "$TMP_ROOT/out")"
  ERR="$(cat "$TMP_ROOT/err")"
}
# kv <key> — the value of KEY= in OUT.
kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | tr -d '\r' | head -n 1; }
assert_same_path() {
  if [[ "$(norm "$2")" == "$(norm "$3")" ]]; then pass "$1"; else fail "$1" "got=$2 want=$3"; fi
}
assert_rc() {
  if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "$1" "rc=$RC want=$2 err=$ERR"; fi
}

case_begin "cli-prints-default-base" "bin/worktree-base"
cli "$OUTSIDE" - --repo "$LINKED"
assert_rc "default/rc-0" 0
assert_same_path "default/base-is-in-repo" "$(kv WORKTREE_BASE)" "$DEFAULT_BASE"
assert_same_path "default/main-dir" "$(kv MAIN_DIR)" "$MAIN"
assert_eq "$(kv WORKTREE_BASE_SOURCE)" "default"
case_end

case_begin "cli-defaults-repo-to-cwd-and-reports-explicit" "bin/worktree-base"
cli "$SUBDIR" "$SB/shared-cli"
assert_rc "explicit/rc-0" 0
assert_same_path "explicit/base-is-shared" "$(kv WORKTREE_BASE)" "$SB/shared-cli"
assert_same_path "explicit/main-dir-from-cwd" "$(kv MAIN_DIR)" "$MAIN"
assert_eq "$(kv WORKTREE_BASE_SOURCE)" "explicit"
case_end

case_begin "cli-relative-explicit-matches-library" "bin/worktree-base"
cli "$SUBDIR" wt --repo "$MAIN"
assert_rc "relative/rc-0" 0
assert_same_path "relative/resolves-against-home" "$(kv WORKTREE_BASE)" "$FX_HOME/wt"
case_end

case_begin "cli-outside-repo-fails" "bin/worktree-base"
for repo_arg in "$OUTSIDE" "" "$SB/missing-dir"; do
  if [[ -n "$repo_arg" ]]; then cli "$OUTSIDE" - --repo "$repo_arg"; else cli "$OUTSIDE" -; fi
  label="outside[${repo_arg:-cwd}]"
  if [[ "$RC" != 0 ]]; then pass "$label/nonzero-rc"; else fail "$label/nonzero-rc" "out=$OUT"; fi
  if [[ -n "${ERR//[[:space:]]/}" ]]; then pass "$label/reason-on-stderr"; else fail "$label/reason-on-stderr" "stderr empty"; fi
  if [[ "$OUT" != *"WORKTREE_BASE="* ]]; then pass "$label/no-base-printed"; else fail "$label/no-base-printed" "out=$OUT"; fi
done
case_end

case_begin "cli-usage-error-exits-64" "bin/worktree-base"
for args in "--repo" "--repo=" "--bogus"; do
  if [[ "$args" == "--repo=" ]]; then cli "$MAIN" - --repo ""; else cli "$MAIN" - "$args"; fi
  assert_rc "usage[$args]/rc-64" 64
  if [[ "$ERR" == *"usage: worktree-base"* ]]; then pass "usage[$args]/usage-on-stderr"; else fail "usage[$args]/usage-on-stderr" "err=$ERR"; fi
  if [[ -z "$OUT" ]]; then pass "usage[$args]/no-stdout"; else fail "usage[$args]/no-stdout" "out=$OUT"; fi
done
case_end

# toNative must turn a Git Bash /c/... --repo into c:/...; MSYS2_ENV_CONV_EXCL keeps MSYS from
# converting WB_REPO_ARG on the way to node, so the CLI's own conversion is what is exercised.
case_begin "cli-posix-drive-repo-normalized" "bin/worktree-base"
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  drive="$(printf '%s' "${SB:0:1}" | tr '[:upper:]' '[:lower:]')"
  posix_main="/${drive}${SB:2}/repos/main"
  export MSYS2_ENV_CONV_EXCL="WB_REPO_ARG"
  cli "$OUTSIDE" - --repo "$posix_main"
  unset MSYS2_ENV_CONV_EXCL
  assert_rc "posix-repo/rc-0" 0
  assert_same_path "posix-repo/base-is-in-repo" "$(kv WORKTREE_BASE)" "$DEFAULT_BASE"
  if [[ "$(kv WORKTREE_BASE)" =~ ^[A-Za-z]:/ ]]; then pass "posix-repo/native-form"; else fail "posix-repo/native-form" "out=$OUT"; fi
else
  skip "cli-posix-drive-repo-normalized: win32 only (/c/... form)"
fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
