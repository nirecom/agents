#!/usr/bin/env bash
# Tests: tests/lib/command-guard.sh, tests/lib/command-guard-build.js, bin/lib/run-all-launch.sh
# Tags: scope:issue-specific, tl2, command-guard, fixture-isolation
#
# The command guard (#2590) refuses to start half-built: command_guard_ensure, the builder and
# run_all_pin_command_guard each return non-zero with a one-line reason instead of leaving a test
# run without a guard. Every library call runs in a subshell so its PATH / env pins stay out of
# this script. Fixtures and setup: feature-2590-command-guard/setup.sh (cg_setup).

# TL3 gap: a host with no git outside the guard (command_guard_ensure "no git on PATH") needs a
# PATH stripped of git, which this fixture cannot build without losing node.
# TL3 gap: the builder's csc.exe-missing failure on Windows cannot be simulated safely.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

. "$SCRIPT_DIR/feature-2590-command-guard/setup.sh"

BUILDER="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/command-guard-build.js")"
LIB_CG="$SCRIPT_CHECKOUT_ROOT/tests/lib/command-guard.sh"
LIB_LAUNCH="$SCRIPT_CHECKOUT_ROOT/bin/lib/run-all-launch.sh"
readonly BUILDER LIB_CG LIB_LAUNCH

# sub_run <snippet> — the snippet in a subshell with the guard / run-root variables cleared;
# sets RC and ERR_TEXT. The snippet sees LIB_CG and LIB_LAUNCH.
sub_run() {
  RC=0
  (
    set +u
    unset TEST_RUN_ROOT COMMAND_GUARD_DIR _COMMAND_GUARD_PIN _TEST_RUN_ROOT_PIN
    export PATH="$SAFE_PATH"
    eval "$1"
  ) >"$TMP_ROOT/sub.out" 2>"$TMP_ROOT/sub.err" || RC=$?
  ERR_TEXT="$(cat "$TMP_ROOT/sub.err")"
}

# build_run <builder args...> — the builder under node; sets RC and ERR_TEXT.
build_run() {
  RC=0
  (cd "$TMP_ROOT" && PATH="$SAFE_PATH" HOME="$FHOME" USERPROFILE="$FHOME" TEST_HOST_TMPDIR="$HOST" \
    bash "$RWT" 120 node "$BUILDER" "$@") >"$TMP_ROOT/build.out" 2>"$TMP_ROOT/build.err" || RC=$?
  ERR_TEXT="$(cat "$TMP_ROOT/build.err")"
}

cg_setup || { echo "FAIL: fixture setup"; exit 1; }

case_begin "ensure-without-a-run-root-fails" "tests/lib/command-guard.sh"
sub_run '. "$LIB_CG"; command_guard_ensure'
expect_ne "B1: returns non-zero" "$RC" "0"
expect_has "B1: names TEST_RUN_ROOT" "$ERR_TEXT" "TEST_RUN_ROOT is unset"
case_end

case_begin "ensure-detects-a-guard-dir-without-conf" "tests/lib/command-guard.sh"
mkdir -p "$TMP_ROOT/broken guard/bin"
export BROKEN_GUARD="$TMP_ROOT/broken guard"
sub_run '. "$LIB_CG"; COMMAND_GUARD_DIR="$BROKEN_GUARD"; command_guard_ensure'
expect_ne "B2: returns non-zero" "$RC" "0"
expect_has "B2: says there is no guard.conf" "$ERR_TEXT" "has no guard.conf"
sub_run '. "$LIB_CG"; COMMAND_GUARD_DIR="$BROKEN_GUARD"; command_guard_ensure || exit 7; echo reached-after-failure'
expect_eq "B2: the caller sees the failure" "$RC" "7"
expect_lacks "B2: PATH is not pinned to the broken guard" "$(cat "$TMP_ROOT/sub.out")" "reached-after-failure"
case_end

case_begin "builder-rejects-a-missing-real-git" "tests/lib/command-guard-build.js"
build_run --instance "$(np "$TMP_ROOT/b3 inst")" --allowed "$(np "$RR")" --realgit "$(np "$TMP_ROOT/no-such-dir/git")"
expect_eq "B3: exits 1" "$RC" "1"
expect_has "B3: says the real git does not exist" "$ERR_TEXT" "the real git does not exist"
expect_eq "B3: no guard.conf written" "$([[ -e "$TMP_ROOT/b3 inst/guard.conf" ]] && echo yes)" ""
build_run --out "$(np "$TMP_ROOT/b3 out")" --realgit "$(np "$TMP_ROOT/no-such-dir/git")"
expect_eq "B3 --out ignores --realgit: still builds" "$RC" "0"
build_run --instance "$(np "$TMP_ROOT/b3 inst2")" --allowed "$(np "$RR")"
expect_eq "B3 --instance without --realgit: exits 2" "$RC" "2"
expect_has "B3 --instance without --realgit: usage message" "$ERR_TEXT" "requires --allowed"
build_run --bogus
expect_eq "B3 unknown argument: exits 2" "$RC" "2"
build_run
expect_eq "B3 no mode: exits 2" "$RC" "2"
case_end

case_begin "builder-refuses-the-guards-own-git" "tests/lib/command-guard-build.js"
if cg_require "builder refuses the guard's own git"; then
  build_run --instance "$(np "$TMP_ROOT/b4 inst")" --allowed "$(np "$RR")" --realgit "$GDIR/bin/git$CG_EXE"
  expect_eq "B4: exits 1" "$RC" "1"
  expect_has "B4: refuses the guard's own git" "$ERR_TEXT" "refusing the guard's own git"
  expect_eq "B4: no guard.conf written" "$([[ -e "$TMP_ROOT/b4 inst/guard.conf" ]] && echo yes)" ""
fi
case_end

case_begin "pin-fails-when-the-guard-lib-is-not-loaded" "bin/lib/run-all-launch.sh"
sub_run '. "$LIB_LAUNCH"; unset -f command_guard_ensure; run_all_pin_command_guard'
expect_ne "C1: returns non-zero" "$RC" "0"
expect_has "C1: says the lib is not loaded" "$ERR_TEXT" "not loaded"
case_end

case_begin "pin-fails-without-a-run-root" "bin/lib/run-all-launch.sh"
sub_run '. "$LIB_LAUNCH"; run_all_pin_command_guard'
expect_ne "C2: returns non-zero" "$RC" "0"
expect_has "C2: names TEST_RUN_ROOT" "$ERR_TEXT" "TEST_RUN_ROOT is unset"
if cg_require "pin never reuses an inherited guard"; then
  export INHERITED_GUARD="$GDIR"
  sub_run '. "$LIB_LAUNCH"; COMMAND_GUARD_DIR="$INHERITED_GUARD"; run_all_pin_command_guard'
  expect_ne "C2: a valid inherited guard is not reused" "$RC" "0"
  expect_has "C2: inherited guard ignored, run root demanded" "$ERR_TEXT" "TEST_RUN_ROOT is unset"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
