#!/usr/bin/env bash
# Tests: install/linux/global-gitignore.sh, install/win/global-gitignore.ps1
# Tags: feature-3138, installer, gitignore, in-repo-base, idempotency, symmetry, test-lang-exception:symmetry, scope:issue-specific, TL2, pwsh-not-required
# TL3 gap: neither installer runs against a real user profile here; the sh installer writes into
# a temp XDG_CONFIG_HOME, and the pwsh installer's own run is covered by
# tests/install/feature-parallel-sessions-worktree-installer-ignore.Tests.ps1.
#
# #3138: both installers' managed block ignores the in-repo worktree base (.claude/worktrees/).
# The block is defined twice (sh and ps1), so this file reads both definitions as text and
# requires the same lines (test-lang-exception:symmetry: one bash file checks a sh and a ps1
# source together), then runs the sh installer twice to pin idempotency.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

set -euo pipefail

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

SH_INSTALLER="$SCRIPT_CHECKOUT_ROOT/install/linux/global-gitignore.sh"
PS_INSTALLER="$SCRIPT_CHECKOUT_ROOT/install/win/global-gitignore.ps1"
BEGIN_MARK="# --- BEGIN agents-managed ---"
END_MARK="# --- END agents-managed ---"
NEW_LINE=".claude/worktrees/"

# sh_block — the quoted lines of _block_content, markers expanded.
SH_AWK='/^_block_content\(\) *\{/ { on=1; next } on && /^\}/ { exit } on && /^[[:space:]]*"/ { sub(/^[[:space:]]*"/, ""); sub(/"[[:space:]]*\\?[[:space:]]*$/, ""); print }'
PS_AWK='/^\$BlockContent = @\(/ { on=1; next } on && /^\)/ { exit } on { sub(/^[[:space:]]*/, ""); sub(/,[[:space:]]*$/, ""); sub(/^"/, ""); sub(/"$/, ""); print }'
sh_block() {
  awk "$SH_AWK" "$SH_INSTALLER" | tr -d '\r' | sed -e "s/^\\\$BLOCK_BEGIN\$/$BEGIN_MARK/" -e "s/^\\\$BLOCK_END\$/$END_MARK/"
}
# ps_block — the elements of $BlockContent = @( ... ), markers expanded.
ps_block() {
  awk "$PS_AWK" "$PS_INSTALLER" | tr -d '\r' | sed -e "s/^\\\$BlockBegin\$/$BEGIN_MARK/" -e "s/^\\\$BlockEnd\$/$END_MARK/"
}
count_exact() { printf '%s\n' "$1" | grep -cxF -- "$2" || true; }

SH_LINES="$(sh_block)"
PS_LINES="$(ps_block)"

case_begin "installer-blocks-define-the-same-lines" "install/win/global-gitignore.ps1"
if [[ -n "$SH_LINES" ]]; then pass "sh/block-extracted"; else fail "sh/block-extracted" "no lines read from $SH_INSTALLER"; fi
if [[ -n "$PS_LINES" ]]; then pass "ps1/block-extracted"; else fail "ps1/block-extracted" "no lines read from $PS_INSTALLER"; fi
if [[ "$SH_LINES" == "$PS_LINES" ]]; then pass "sh-and-ps1-blocks-match"; else fail "sh-and-ps1-blocks-match" "sh=[$SH_LINES] ps1=[$PS_LINES]"; fi
assert_eq "$(printf '%s\n' "$PS_LINES" | head -n 1)" "$BEGIN_MARK"
assert_eq "$(printf '%s\n' "$PS_LINES" | tail -n 1)" "$END_MARK"
case_end

case_begin "block-ignores-the-in-repo-worktree-base" "install/linux/global-gitignore.sh"
for side in sh ps1; do
  if [[ "$side" == sh ]]; then lines="$SH_LINES"; else lines="$PS_LINES"; fi
  assert_eq "$(count_exact "$lines" "$NEW_LINE")" "1"
  if printf '%s\n' "$lines" | grep -q '^# \.claude/worktrees/ (in-repo worktree base'; then
    pass "$side/comment-line"
  else
    fail "$side/comment-line" "no '# .claude/worktrees/ (in-repo worktree base...' line: $lines"
  fi
  assert_eq "$(count_exact "$lines" ".codegraph/")" "1"
  assert_eq "$(count_exact "$lines" "WORKTREE_NOTES.md")" "1"
done
case_end

# install_sh <xdg> — one sh installer run with HOME and XDG_CONFIG_HOME pinned to fixture dirs.
install_sh() {
  HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$1" bash "$SH_INSTALLER" >"$TMP_ROOT/inst-out" 2>&1
}
mkdir -p "$TMP_ROOT/home"

case_begin "sh-installer-twice-keeps-one-block" "install/linux/global-gitignore.sh"
XDG="$TMP_ROOT/xdg-fresh"
IGNORE="$XDG/git/ignore"
if install_sh "$XDG"; then pass "fresh/first-run-rc-0"; else fail "fresh/first-run-rc-0" "$(cat "$TMP_ROOT/inst-out")"; fi
FIRST="$(cat "$IGNORE" 2>/dev/null || true)"
if install_sh "$XDG"; then pass "fresh/second-run-rc-0"; else fail "fresh/second-run-rc-0" "$(cat "$TMP_ROOT/inst-out")"; fi
SECOND="$(cat "$IGNORE" 2>/dev/null || true)"
assert_eq "$(count_exact "$SECOND" "$BEGIN_MARK")" "1"
assert_eq "$(count_exact "$SECOND" "$END_MARK")" "1"
assert_eq "$(count_exact "$SECOND" "$NEW_LINE")" "1"
if [[ "$FIRST" == "$SECOND" ]]; then pass "fresh/second-run-unchanged"; else fail "fresh/second-run-unchanged" "first=[$FIRST] second=[$SECOND]"; fi
case_end

case_begin "sh-installer-twice-keeps-user-lines" "install/linux/global-gitignore.sh"
XDG="$TMP_ROOT/xdg-user"
IGNORE="$XDG/git/ignore"
mkdir -p "$XDG/git"
printf '%s\n' "user-before" "$BEGIN_MARK" "stale-line" "$END_MARK" "user-after" >"$IGNORE"
install_sh "$XDG" || fail "user/first-run-rc-0" "$(cat "$TMP_ROOT/inst-out")"
FIRST="$(cat "$IGNORE")"
install_sh "$XDG" || fail "user/second-run-rc-0" "$(cat "$TMP_ROOT/inst-out")"
SECOND="$(cat "$IGNORE")"
assert_eq "$(count_exact "$SECOND" "$NEW_LINE")" "1"
assert_eq "$(count_exact "$SECOND" "stale-line")" "0"
assert_eq "$(count_exact "$SECOND" "user-before")" "1"
assert_eq "$(count_exact "$SECOND" "user-after")" "1"
if [[ "$FIRST" == "$SECOND" ]]; then pass "user/second-run-unchanged"; else fail "user/second-run-unchanged" "first=[$FIRST] second=[$SECOND]"; fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
