#!/usr/bin/env bash
# Tests: bin/lib/worktree-base-prune.sh, bin/worktree-base
# Tags: feature-3138, worktree-base, prune, find, letter-case, fail-closed, scope:issue-specific, TL2, pwsh-not-required
# TL3 gap: the review-* --all scans are not run end to end against a host whose real volume
# disagrees with the platform fold rule; the prune function is driven with stub CLIs here.
#
# #3138: worktree_base_prune_args reads WORKTREE_BASE_FOLD_CASE from bin/worktree-base first.
# on: the fixed ./.claude/worktrees clause and the resolver-base clause use -ipath (and the
# prefix test folds); off: -path. When the CLI fails, the fixed clause is -ipath, no base clause
# is added, and one warning goes to stderr. Each stub tree holds a copy of the prune library with
# bin/worktree-base replaced, so the library's own root resolution picks the stub.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

set -euo pipefail

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

PRUNE_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/worktree-base-prune.sh"
SB="$TMP_ROOT/sb"
mkdir -p "$SB"

# make_stub <name> <mode> — <SB>/<name>/bin/{worktree-base,lib/worktree-base-prune.sh}.
# mode: on | off | fail | on-upper | off-upper (-upper prints the base under an upper-cased CWD).
make_stub() {
  local dir="$SB/$1" mode="$2"
  mkdir -p "$dir/bin/lib"
  cp "$PRUNE_LIB" "$dir/bin/lib/worktree-base-prune.sh"
  printf '%s\n' '#!/usr/bin/env bash' "mode=$mode" \
    'if [[ "$mode" == fail ]]; then exit 1; fi' \
    'here="$(pwd -W 2>/dev/null || pwd)"' \
    'if [[ "$mode" == *-upper ]]; then here="${here^^}"; fi' \
    'echo "WORKTREE_BASE=$here/Wt-Rel"' 'echo "MAIN_DIR=$here"' 'echo "WORKTREE_BASE_SOURCE=explicit"' \
    'echo "WORKTREE_BASE_FOLD_CASE=${mode%-upper}"' >"$dir/bin/worktree-base"
  printf '%s' "$dir"
}

# make_fixture <name> <rel-dir> — a scan root holding keep.txt, a misspelled fixed base and <rel-dir>.
make_fixture() {
  local dir="$SB/$1"
  mkdir -p "$dir/.Claude/Worktrees/t" "$dir/$2/a"
  printf 'x\n' >"$dir/keep.txt"
  printf 'x\n' >"$dir/.Claude/Worktrees/t/f.txt"
  printf 'x\n' >"$dir/$2/a/f.txt"
  printf '%s' "$dir"
}

SCAN="" SCAN_ERR="" SCAN_RC=0
# scan <stub-dir> <fixture-dir> — runs the prune function from the fixture and lists files.
scan() {
  SCAN_RC=0
  (cd "$2" && . "$1/bin/lib/worktree-base-prune.sh" && worktree_base_prune_args 2>"$TMP_ROOT/scan-err" &&
    find . "${WT_BASE_PRUNE_ARGS[@]}" -type f -print) >"$TMP_ROOT/scan-out" || SCAN_RC=$?
  SCAN="$(tr -d '\r' <"$TMP_ROOT/scan-out")"
  SCAN_ERR="$(cat "$TMP_ROOT/scan-err" 2>/dev/null || true)"
}
walked() { printf '%s\n' "$SCAN" | grep -qxF "$1"; }
expect_walked() { if walked "$2"; then pass "$1"; else fail "$1" "missing $2 in: $SCAN"; fi; }
expect_pruned() { if walked "$2"; then fail "$1" "$2 was walked: $SCAN"; else pass "$1"; fi; }

ON="$(make_stub stub-on on)"
OFF="$(make_stub stub-off off)"
FAILING="$(make_stub stub-fail fail)"
ON_UP="$(make_stub stub-on-upper on-upper)"
OFF_UP="$(make_stub stub-off-upper off-upper)"
FX="$(make_fixture fx wt-rel)"
FX_EXACT="$(make_fixture fx-exact Wt-Rel)"
# fx-spelled: both bases spelled exactly as the stub and the fixed clause name them.
FX_SPELLED="$SB/fx-spelled"
mkdir -p "$FX_SPELLED/.claude/worktrees/t" "$FX_SPELLED/Wt-Rel/a"
printf 'x\n' >"$FX_SPELLED/keep.txt"
printf 'x\n' >"$FX_SPELLED/.claude/worktrees/t/f.txt"
printf 'x\n' >"$FX_SPELLED/Wt-Rel/a/f.txt"

case_begin "fold-on-prunes-misspelled-bases" "bin/lib/worktree-base-prune.sh"
scan "$ON" "$FX"
assert_eq "$SCAN_RC" "0"
expect_walked "on/keeps-other-files" "./keep.txt"
expect_pruned "on/fixed-base-ipath" "./.Claude/Worktrees/t/f.txt"
expect_pruned "on/rel-base-ipath" "./wt-rel/a/f.txt"
case_end

case_begin "fold-off-walks-misspelled-bases" "bin/lib/worktree-base-prune.sh"
scan "$OFF" "$FX"
assert_eq "$SCAN_RC" "0"
expect_walked "off/keeps-other-files" "./keep.txt"
expect_walked "off/fixed-base-exact-path" "./.Claude/Worktrees/t/f.txt"
expect_walked "off/rel-base-exact-path" "./wt-rel/a/f.txt"
# off still prunes both bases when spelled exactly (guards against dropping the -path clauses).
scan "$OFF" "$FX_SPELLED"
assert_eq "$SCAN_RC" "0"
expect_walked "off-spelled/keeps-other-files" "./keep.txt"
expect_pruned "off-spelled/fixed-base-pruned" "./.claude/worktrees/t/f.txt"
expect_pruned "off-spelled/rel-base-pruned" "./Wt-Rel/a/f.txt"
case_end

case_begin "prefix-test-folds-only-when-on" "bin/lib/worktree-base-prune.sh"
scan "$ON_UP" "$FX_EXACT"
expect_pruned "on-upper/base-under-cwd-despite-case" "./Wt-Rel/a/f.txt"
scan "$OFF_UP" "$FX_EXACT"
expect_walked "off-upper/base-not-under-cwd" "./Wt-Rel/a/f.txt"
case_end

case_begin "cli-failure-prunes-fixed-base-case-insensitively-and-warns" "bin/lib/worktree-base-prune.sh"
scan "$FAILING" "$FX"
assert_eq "$SCAN_RC" "0"
expect_walked "fail/keeps-other-files" "./keep.txt"
expect_pruned "fail/fixed-base-ipath" "./.Claude/Worktrees/t/f.txt"
expect_walked "fail/configured-base-not-pruned" "./wt-rel/a/f.txt"
if [[ -n "${SCAN_ERR//[[:space:]]/}" ]]; then pass "fail/warning-on-stderr"; else fail "fail/warning-on-stderr" "stderr empty"; fi
if [[ "$(printf '%s\n' "$SCAN_ERR" | grep -c .)" -eq 1 ]]; then pass "fail/one-line-warning"; else fail "fail/one-line-warning" "stderr: $SCAN_ERR"; fi
# The stub is silent on stderr, so this text can only come from the prune library itself.
if [[ "${SCAN_ERR,,}" == *".claude/worktrees"* ]]; then
  pass "fail/warning-names-fixed-clause"
else
  fail "fail/warning-names-fixed-clause" "warning does not mention .claude/worktrees: $SCAN_ERR"
fi
case_end

case_begin "real-cli-prints-fold-flag-from-platform" "bin/worktree-base"
REPO="$SB/repo"
mkdir -p "$REPO" "$SB/home" "$SB/conf"
harness_git_init "$REPO"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Darwin) want_fold=on ;;
  *) want_fold=off ;;
esac
CLI_OUT="$(cd "$REPO" && env -u WORKTREE_BASE_DIR -u CLAUDE_CODE_SESSION_ID "HOME=$SB/home" "USERPROFILE=$SB/home" \
  "AGENTS_MAIN_ROOT=$SB/conf" bash "$SCRIPT_CHECKOUT_ROOT/bin/worktree-base" --repo "$REPO" | tr -d '\r')" || true
assert_eq "$(printf '%s\n' "$CLI_OUT" | sed -n 's/^WORKTREE_BASE_FOLD_CASE=//p')" "$want_fold"
if printf '%s\n' "$CLI_OUT" | grep -q '^WORKTREE_BASE='; then pass "cli/base-line-kept"; else fail "cli/base-line-kept" "out=$CLI_OUT"; fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
