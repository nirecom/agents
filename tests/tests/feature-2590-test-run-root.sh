#!/usr/bin/env bash
# Tests: tests/lib/test-run-root.sh, tests/lib/harness.sh
# Tags: scope:issue-specific, tl2, fixture-isolation, run-root
#
# The run root (#2590): the one directory a test may write in. Every child runs with a fixture
# HOME / USERPROFILE and a fixture TEST_HOST_TMPDIR, so nothing lands outside $TMP_ROOT.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
nlow() { [[ -n "$1" ]] || return 0; np "$1" | tr 'A-Z\\' 'a-z/' | sed 's#/$##'; }
is_dir() { [[ -n "$1" && -d "$1" ]] && echo yes; }

HOST="$TMP_ROOT/host tmp"
OS_TMP="$TMP_ROOT/os tmp"
FHOME="$TMP_ROOT/home"
mkdir -p "$HOST" "$OS_TMP" "$FHOME"

# Driver: the harness itself (mode harness) or the run-root library alone (mode lib); prints
# what a test would see afterwards.
cat >"$TMP_ROOT/driver.sh" <<'DRIVER'
if [[ "$2" == harness ]]; then
  source "$1/tests/lib/harness.sh" || exit 90
else
  source "$1/tests/lib/test-run-root.sh" || exit 90
  test_run_root_ensure || exit 91
fi
printf 'RUN_ROOT=%s\nTMPDIR=%s\nTMP=%s\nTEMP=%s\nHOST=%s\n' "${TEST_RUN_ROOT:-}" "${TMPDIR:-}" "${TMP:-}" "${TEMP:-}" "${TEST_HOST_TMPDIR:-}"
printf 'CACHE=%s\n' "$(node "$1/tests/lib/root-decoy-build.js" --cache-dir 2>/dev/null)"
printf 'MKTEMP=%s\n' "$(mktemp -d)"
DRIVER

# drive <mode> [env args...] — a clean child: no inherited run root, guard or decoy; the extra
# env args (-u NAME or NAME=value) apply last.
drive() {
  local mode="$1"
  shift
  (cd "$TMP_ROOT" && env -u TEST_RUN_ROOT -u COMMAND_GUARD_DIR -u ROOT_DECOY_DIR -u RUN_ALL_CACHE_DIR \
    HOME="$FHOME" USERPROFILE="$FHOME" TMPDIR="$OS_TMP" TMP="$OS_TMP" TEMP="$OS_TMP" TEST_HOST_TMPDIR="$HOST" env "$@" \
    bash "$RWT" 120 bash "$TMP_ROOT/driver.sh" "$SCRIPT_CHECKOUT_ROOT" "$mode" 2>&1)
}

case_begin "harness-creates-the-run-root-and-pins-temp" "tests/lib/harness.sh"
OUT1="$(drive harness)"
RR1="$(field "$OUT1" RUN_ROOT)"
expect_ne "harness exports TEST_RUN_ROOT" "$RR1" ""
expect_eq "the run root exists" "$(is_dir "$RR1")" "yes"
PARENT="${RR1%/*}"
case "$(nlow "$PARENT")" in
  "$(nlow "$HOST")"/agents-test-runs-*) pass "the run root sits in <TEST_HOST_TMPDIR>/agents-test-runs-<user>" ;;
  *) fail "the run root sits in <TEST_HOST_TMPDIR>/agents-test-runs-<user>" "got=$RR1" ;;
esac
case "${RR1##*/}" in
  run-*-*) pass "the run root is named run-<pid>-<rand>" ;;
  *) fail "the run root is named run-<pid>-<rand>" "got=${RR1##*/}" ;;
esac
for v in TMPDIR TMP TEMP; do
  expect_eq "$v points at <run root>/tmp" "$(nlow "$(field "$OUT1" "$v")")" "$(nlow "${RR1:-unset}/tmp")"
done
case "$(nlow "$(field "$OUT1" MKTEMP)")" in
  "$(nlow "${RR1:-unset}")"/tmp/*) pass "mktemp lands under the run root" ;;
  *) fail "mktemp lands under the run root" "got=$(field "$OUT1" MKTEMP)" ;;
esac
expect_eq "nothing under HOME except the existing decoy cache" "$(find "$FHOME" -mindepth 1 -maxdepth 1 ! -name .claude | wc -l | tr -d ' ')" "0"
case_end

case_begin "an-existing-run-root-is-reused" "tests/lib/test-run-root.sh"
GIVEN="$TMP_ROOT/given root"
mkdir -p "$GIVEN"
OUT2="$(drive lib TEST_RUN_ROOT="$GIVEN")"
expect_eq "TEST_RUN_ROOT is kept" "$(nlow "$(field "$OUT2" RUN_ROOT)")" "$(nlow "$GIVEN")"
expect_eq "TMPDIR follows the given run root" "$(nlow "$(field "$OUT2" TMPDIR)")" "$(nlow "$GIVEN/tmp")"
expect_eq "<given>/tmp is created" "$(is_dir "$GIVEN/tmp")" "yes"
expect_eq "no new run root under the host temp area" "$(find "$HOST" -maxdepth 2 -name 'run-*' | wc -l | tr -d ' ')" "$(if [[ -n "$RR1" ]]; then echo 1; else echo 0; fi)"
case_end

case_begin "run-roots-older-than-a-day-are-cleaned" "tests/lib/test-run-root.sh"
if [[ -z "$RR1" ]]; then
  fail "cleanup needs the run-root parent" "the first case created no run root"
else
  mkdir -p "$PARENT/run-1-old/tmp" "$PARENT/run-2-fresh/tmp" "$PARENT/not-a-run"
  printf 'x\n' >"$PARENT/run-1-old/tmp/file"
  touch -d '2 days ago' "$PARENT/run-1-old/tmp/file" "$PARENT/run-1-old/tmp" "$PARENT/run-1-old" "$PARENT/not-a-run"
  OUT3="$(drive lib)"
  expect_eq "an old run-* is removed" "$(is_dir "$PARENT/run-1-old")" ""
  expect_eq "a fresh run-* is kept" "$(is_dir "$PARENT/run-2-fresh")" "yes"
  expect_eq "an old non-run dir is kept" "$(is_dir "$PARENT/not-a-run")" "yes"
  expect_eq "the new run root is created" "$(is_dir "$(field "$OUT3" RUN_ROOT)")" "yes"
fi
case_end

case_begin "host-temp-is-kept-and-the-cache-is-stable" "tests/lib/test-run-root.sh"
OUT4="$(drive lib)"
OUT5="$(drive lib)"
expect_eq "a preset TEST_HOST_TMPDIR is kept" "$(nlow "$(field "$OUT4" HOST)")" "$(nlow "$HOST")"
expect_ne "two runs get two run roots" "$(field "$OUT4" RUN_ROOT)" "$(field "$OUT5" RUN_ROOT)"
C4="$(field "$OUT4" CACHE)"
expect_ne "the cache dir resolves after TMPDIR is pinned" "$C4" ""
expect_eq "the cache dir is the same across runs" "$(nlow "$(field "$OUT5" CACHE)")" "$(nlow "$C4")"
case "$(nlow "$C4")" in
  "$(nlow "$HOST")"/agents-test-cache-*) pass "the cache stays under TEST_HOST_TMPDIR, not the run root" ;;
  *) fail "the cache stays under TEST_HOST_TMPDIR, not the run root" "got=$C4" ;;
esac
OUT6="$(drive lib -u TEST_HOST_TMPDIR)"
expect_eq "an unset TEST_HOST_TMPDIR takes the incoming TMPDIR" "$(nlow "$(field "$OUT6" HOST)")" "$(nlow "$OS_TMP")"
case "$(nlow "$(field "$OUT6" RUN_ROOT)")" in
  "$(nlow "$OS_TMP")"/agents-test-runs-*/run-*) pass "the run root follows the incoming TMPDIR" ;;
  *) fail "the run root follows the incoming TMPDIR" "got=$(field "$OUT6" RUN_ROOT)" ;;
esac
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
