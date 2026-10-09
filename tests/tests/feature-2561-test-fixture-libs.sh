#!/usr/bin/env bash
# tests/tests/feature-2561-test-fixture-libs.sh
# Tests: tests/lib/script-checkout-fixture.sh, tests/lib/target-repo-fixture.sh
# Tags: tests, fixture, worktree, security, idempotency, scope:issue-specific, tl2
# TL3 gap (what this test does NOT catch):
# - whether the tests that need a copied checkout or a target repository actually use these libs
# - symlinked tracked files on a host that checks them out as real symlinks
# Closest-to-action mitigation: the static residue check and the per-area tests of this issue.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# Run standalone, the harness would build its decoy under the real ~/.claude/run-all.
OWN_CACHE_DIR=""
if [[ -z "${RUN_ALL_CACHE_DIR:-}" ]]; then
  OWN_CACHE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t root-decoy-cache)"
  [[ -n "$OWN_CACHE_DIR" && -d "$OWN_CACHE_DIR" ]] || { echo "cannot create a decoy cache directory" >&2; exit 1; }
  export RUN_ALL_CACHE_DIR="$OWN_CACHE_DIR"
fi
readonly OWN_CACHE_DIR
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(np "$(make_tmp)")"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"; [[ -z "$OWN_CACHE_DIR" ]] || rm -rf "$OWN_CACHE_DIR"' EXIT
harness_isolate "$TMP_ROOT"

readonly FX="$TMP_ROOT/fx checkout"
readonly COPY_LIB="$FX/tests/lib/script-checkout-fixture.sh"
readonly TARGET_LIB="$SCRIPT_CHECKOUT_ROOT/tests/lib/target-repo-fixture.sh"
readonly META_REL="bin/it's \$(touch INJECTED);x.sh"

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
files_under() { (cd "$1" && find . -type f | LC_ALL=C sort); }
tracked_under() { git -C "$FX" -c core.quotePath=false ls-files -z -- "${@}" | tr '\0' '\n' | sed 's|^|./|' | LC_ALL=C sort; }
copy() { run_with_timeout 120 bash "$TMP_ROOT/copy-driver.sh" "$COPY_LIB" "$@"; }
target_run() { (cd "$TMP_ROOT" && run_with_timeout 120 bash "$TMP_ROOT/target-driver.sh" "$TARGET_LIB" "$@"); }

mkdir -p "$FX/tests/lib" "$FX/bin/lib" "$FX/hooks/lib" "$FX/skills/demo" "$FX/docs"
cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh" "$FX/tests/lib/"
printf '#!/usr/bin/env bash\nsource "$(dirname "${BASH_SOURCE[0]}")/lib/helper.sh"\nhelper_say\n' >"$FX/bin/tool.sh"
printf 'helper_say() { echo REAL-HELPER; }\n' >"$FX/bin/lib/helper.sh"
printf 'echo meta\n' >"$FX/$META_REL"
printf 'console.log("hook");\n' >"$FX/hooks/hook.js"
printf 'module.exports = 1;\n' >"$FX/hooks/lib/mod.js"
printf '# demo\n' >"$FX/skills/demo/SKILL.md"
printf 'doc\n' >"$FX/docs/guide.md"
chmod +x "$FX/bin/tool.sh"
harness_git_init "$FX"
git -C "$FX" add -A
git -C "$FX" update-index --chmod=+x bin/tool.sh
printf 'echo untracked\n' >"$FX/bin/untracked.sh"
cat >"$TMP_ROOT/copy-driver.sh" <<'DRIVER'
source "$1" || exit 90
shift
script_checkout_fixture_copy "$@"
rc=$?
if declare -p _SCRIPT_CHECKOUT_FIXTURE_SCRIPT_CHECKOUT_ROOT 2>/dev/null | grep -q -- '-x'; then echo "EXPORTED-ROOT"; fi
exit "$rc"
DRIVER
cat >"$TMP_ROOT/target-driver.sh" <<'DRIVER'
source "$1" || exit 90
shift
target_repo_fixture_create "$@"
rc=$?
printf 'RC=%s\nMAIN=%s\nLINKED=%s\n' "$rc" "${TARGET_MAIN_ROOT:-}" "${TARGET_CHECKOUT_ROOT:-}"
bash -c 'printf "CHILD=%s|%s\n" "${TARGET_MAIN_ROOT:-}" "${TARGET_CHECKOUT_ROOT:-}"'
DRIVER

case_begin "copy-defaults-to-the-three-code-prefixes" "tests/lib/script-checkout-fixture.sh"
COPY_OUT="$(copy "$TMP_ROOT/copy all")"
expect_eq "default copy exits 0" "$?" "0"
expect_eq "copied files equal the tracked bin/hooks/skills files" "$(files_under "$TMP_ROOT/copy all")" "$(tracked_under bin hooks skills)"
expect_eq "untracked file is not copied" "$(rc_of test -e "$TMP_ROOT/copy all/bin/untracked.sh")" "1"
expect_eq "path outside the default prefixes is not copied" "$(rc_of test -e "$TMP_ROOT/copy all/docs")" "1"
expect_eq "file content is kept" "$(cat "$TMP_ROOT/copy all/bin/lib/helper.sh")" "$(cat "$FX/bin/lib/helper.sh")"
expect_eq "the library root variable is not exported" "$COPY_OUT" ""
case_end

case_begin "copied-script-resolves-siblings-inside-the-copy" "tests/lib/script-checkout-fixture.sh"
expect_eq "copied script runs against the copied sibling" "$(bash "$TMP_ROOT/copy all/bin/tool.sh")" "REAL-HELPER"
printf 'helper_say() { echo STUB-HELPER; }\n' >"$TMP_ROOT/copy all/bin/lib/helper.sh"
expect_eq "a stub placed in the copy is reached" "$(bash "$TMP_ROOT/copy all/bin/tool.sh")" "STUB-HELPER"
expect_eq "the source checkout is left untouched" "$(bash "$FX/bin/tool.sh")" "REAL-HELPER"
if [[ -x "$TMP_ROOT/copy all/bin/tool.sh" ]]; then pass "executable bit is kept"; else fail "executable bit is kept" "bin/tool.sh is not executable in the copy"; fi
case_end

case_begin "copy-is-limited-to-the-given-prefixes" "tests/lib/script-checkout-fixture.sh"
copy "$TMP_ROOT/copy part" hooks/lib docs
expect_eq "prefix copy exits 0" "$?" "0"
expect_eq "only the named prefixes are copied" "$(files_under "$TMP_ROOT/copy part")" "$(tracked_under hooks/lib docs)"
case_end

case_begin "repeated-copy-keeps-placed-stubs" "tests/lib/script-checkout-fixture.sh"
copy "$TMP_ROOT/copy all" bin
expect_eq "second copy exits 0" "$?" "0"
expect_eq "the stub survives an overlapping copy" "$(bash "$TMP_ROOT/copy all/bin/tool.sh")" "STUB-HELPER"
expect_eq "the file set is unchanged" "$(files_under "$TMP_ROOT/copy all")" "$(tracked_under bin hooks skills)"
case_end

case_begin "copy-treats-metacharacter-names-as-data" "tests/lib/script-checkout-fixture.sh"
expect_eq "metacharacter file is copied under its literal name" "$(cat "$TMP_ROOT/copy all/$META_REL" 2>/dev/null)" "echo meta"
copy "$TMP_ROOT/dest \$(touch INJECTED) dir" hooks
expect_eq "metacharacter destination is used literally" "$(rc_of test -f "$TMP_ROOT/dest \$(touch INJECTED) dir/hooks/hook.js")" "0"
expect_eq "no command embedded in a name ran" "$(find "$TMP_ROOT" "$FX" -name INJECTED | wc -l | tr -d ' ')" "0"
case_end

case_begin "copy-rejects-missing-destination-and-foreign-source" "tests/lib/script-checkout-fixture.sh"
expect_eq "missing destination argument fails" "$(rc_of copy)" "1"
mkdir -p "$TMP_ROOT/not a repo/tests/lib"
cp "$COPY_LIB" "$TMP_ROOT/not a repo/tests/lib/"
ERR_OUT="$(cd "$TMP_ROOT/not a repo" && GIT_CEILING_DIRECTORIES="$TMP_ROOT" run_with_timeout 120 bash "$TMP_ROOT/copy-driver.sh" "$TMP_ROOT/not a repo/tests/lib/script-checkout-fixture.sh" "$TMP_ROOT/copy none" 2>&1)"
expect_ne "a library outside a git checkout fails" "$?" "0"
expect_has "the failure names the listing step" "$ERR_OUT" "cannot list tracked files"
expect_eq "a failed copy leaves no files" "$(find "$TMP_ROOT/copy none" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
case_end

case_begin "real-checkout-prefix-copy-matches-git" "tests/lib/script-checkout-fixture.sh"
run_with_timeout 120 bash "$TMP_ROOT/copy-driver.sh" "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh" "$TMP_ROOT/copy real" bin/lib
expect_eq "real checkout copy exits 0" "$?" "0"
REAL_WANT="$(git -C "$SCRIPT_CHECKOUT_ROOT" -c core.quotePath=false ls-files -- bin/lib | sed 's|^|./|' | LC_ALL=C sort)"
expect_ne "the real checkout tracks bin/lib files" "$REAL_WANT" ""
expect_eq "real checkout copy equals its tracked bin/lib files" "$(files_under "$TMP_ROOT/copy real")" "$REAL_WANT"
case_end

mkdir -p "$TMP_ROOT/target base"
TARGET_OUT="$(target_run "$TMP_ROOT/target base")"
T_MAIN="$(printf '%s\n' "$TARGET_OUT" | sed -n 's/^MAIN=//p')"
T_LINKED="$(printf '%s\n' "$TARGET_OUT" | sed -n 's/^LINKED=//p')"

case_begin "target-fixture-has-a-main-and-a-linked-worktree" "tests/lib/target-repo-fixture.sh"
expect_has "create succeeds" "$TARGET_OUT" "RC=0"
expect_eq "main root lives under the base directory" "$T_MAIN" "$TMP_ROOT/target base/target-main"
expect_eq "linked root lives under the base directory" "$T_LINKED" "$TMP_ROOT/target base/target-linked"
expect_ne "the two roots differ" "$T_MAIN" "$T_LINKED"
expect_eq "main root is a main worktree" "$(git -C "$T_MAIN" rev-parse --git-dir)" ".git"
expect_eq "linked root is a linked worktree of the main root" "$(np "$(git -C "$T_LINKED" rev-parse --path-format=absolute --git-common-dir)")" "$T_MAIN/.git"
expect_ne "linked root has its own git dir" "$(git -C "$T_LINKED" rev-parse --absolute-git-dir)" "$(git -C "$T_MAIN" rev-parse --absolute-git-dir)"
expect_eq "both worktrees are registered" "$(git -C "$T_MAIN" worktree list --porcelain | grep -c '^worktree ')" "2"
expect_eq "the fixture has one commit" "$(git -C "$T_LINKED" rev-list --count HEAD)" "1"
case_end

case_begin "target-fixture-is-isolated-from-the-agents-repository" "tests/lib/target-repo-fixture.sh"
HOOKS_PATH="$(git -C "$T_LINKED" config core.hooksPath | tr '[:upper:]' '[:lower:]')"
expect_eq "git hooks point at the null device" "${HOOKS_PATH/#nul//dev/null}" "/dev/null"
expect_eq "the fixture has no remote" "$(git -C "$T_MAIN" remote | wc -l | tr -d ' ')" "0"
expect_ne "the fixture is not the agents repository" "$(git -C "$T_MAIN" rev-list --max-parents=0 HEAD)" "$(git -C "$SCRIPT_CHECKOUT_ROOT" rev-list --max-parents=0 HEAD | head -1)"
expect_eq "the fixture carries no agents code" "$(rc_of test -e "$T_MAIN/bin")" "1"
expect_eq "a commit in the fixture needs no host identity" "$(rc_of git -C "$T_LINKED" commit -q --allow-empty -m probe)" "0"
case_end

case_begin "target-roots-are-not-exported" "tests/lib/target-repo-fixture.sh"
expect_eq "a child process sees neither root" "$(printf '%s\n' "$TARGET_OUT" | tr -d '\r' | grep -c -x -F -- 'CHILD=|' || true)" "1"
expect_eq "roots use forward slashes only" "$(printf '%s%s' "$T_MAIN" "$T_LINKED" | tr -d -c '\\' | wc -c | tr -d ' ')" "0"
case_end

case_begin "target-fixture-rejects-bad-or-used-base" "tests/lib/target-repo-fixture.sh"
SECOND_OUT="$(target_run "$TMP_ROOT/target base" 2>/dev/null)"
expect_has "a second create in the same base fails" "$SECOND_OUT" "RC=1"
expect_eq "the first fixture is left intact" "$(git -C "$T_MAIN" worktree list --porcelain | grep -c '^worktree ')" "2"
expect_has "a missing base directory fails" "$(target_run "$TMP_ROOT/absent base" 2>/dev/null)" "RC=1"
expect_eq "a missing base directory is not created" "$(rc_of test -e "$TMP_ROOT/absent base")" "1"
expect_has "an absent argument fails" "$(target_run 2>/dev/null)" "RC=1"
case_end

case_begin "target-fixture-treats-a-metacharacter-base-as-data" "tests/lib/target-repo-fixture.sh"
mkdir -p "$TMP_ROOT/base \$(touch INJECTED) it's"
META_OUT="$(target_run "$TMP_ROOT/base \$(touch INJECTED) it's")"
expect_has "create succeeds under a metacharacter base" "$META_OUT" "RC=0"
expect_has "the linked root keeps the literal base" "$META_OUT" "LINKED=$TMP_ROOT/base \$(touch INJECTED) it's/target-linked"
expect_eq "no command embedded in the base ran" "$(find "$TMP_ROOT" -name INJECTED | wc -l | tr -d ' ')" "0"
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
