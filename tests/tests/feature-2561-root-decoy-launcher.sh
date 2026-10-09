#!/usr/bin/env bash
# tests/tests/feature-2561-root-decoy-launcher.sh
# Tests: bin/lib/run-all-launch.sh, tests/lib/harness.sh, tests/lib/root-decoy-build.js, tests/lib/root-decoy.sh
# Tags: tests, root-decoy, run-all, harness, security, scope:issue-specific, tl2
# TL3 gap (what this test does NOT catch):
# - a full 15-lane run: only one or two fixture tests go through tests/run-all.sh here
# - tests that never source the harness and are started without the launcher
# Closest-to-action mitigation: the full run of this issue's final step, compared with its baseline.

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

ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
readonly ROOT_N
readonly CACHE="$TMP_ROOT/cache dir"
readonly REAL_CFG="$TMP_ROOT/pretend real"
readonly FIX="$TMP_ROOT/fixture tests"
readonly BUILDER="$ROOT_N/tests/lib/root-decoy-build.js"
mkdir -p "$CACHE" "$REAL_CFG" "$FIX" "$TMP_ROOT/work one" "$TMP_ROOT/work two" "$TMP_ROOT/work three" "$TMP_ROOT/neutral" "$TMP_ROOT/home" || exit 1
# No process started here reads the developer's home (Node on Windows reads USERPROFILE).
export HOME="$TMP_ROOT/home" USERPROFILE="$TMP_ROOT/home"
printf 'RUN_TL3=off\nRUN_TL4=on\nROOT_DECOY_MARKER=pretend-real\n' >"$REAL_CFG/.env"

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1" "both sides are $2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) fail "$1" "unexpected: $3 in: $2" ;; *) pass "$1" ;; esac; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
marker_of() { cat "$1/.env" 2>/dev/null || true; }

TAB="$(printf '\t')"
readonly TAB
# Without the list every per-name loop below would pass with zero rounds, so stop here.
RETIRED_LIST="$(node "$BUILDER" --print-retired-env-names)" || { echo "cannot read the retired environment names" >&2; exit 1; }
RETIRED_NAMES=()
while IFS= read -r name; do
  name="${name%$'\r'}"
  [[ -n "$name" ]] && RETIRED_NAMES+=("$name")
done <<<"$RETIRED_LIST"
[[ "${#RETIRED_NAMES[@]}" -ge 1 ]] || { echo "the retired environment name list is empty" >&2; exit 1; }
UNSET_ARGS=(-u ROOT_DECOY_DIR -u ROOT_DECOY_REAL_AGENTS_MAIN_ROOT -u ROOT_DECOY_TEST_ID -u RUN_TL3 -u RUN_TL4)
for name in ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"}; do UNSET_ARGS+=(-u "$name"); done
# launched <command...> — a 120 s run from a neutral directory in the state a developer shell
# has before any decoy exists: the main root names the pretend-real settings, the cache is a
# temp dir, and no decoy or retired variable is inherited.
launched() {
  (cd "$TMP_ROOT/neutral" && env "${UNSET_ARGS[@]}" RUN_ALL_CACHE_DIR="$CACHE" RUN_ALL_PROGRESS=off AGENTS_MAIN_ROOT="$REAL_CFG" bash "$RWT" 120 "$@")
}

cat >"$TMP_ROOT/pin-driver.sh" <<'DRIVER'
source "$1/bin/lib/run-all-launch.sh" || exit 90
for fn in run_all_pin_root_decoy run_all_pin_test_env; do
  declare -F "$fn" >/dev/null 2>&1 || echo "MISSING:$fn"
done
declare -F run_all_pin_test_env >/dev/null 2>&1 || exit 91
run_all_pin_test_env "$2" || { printf 'FAILED-MAIN=%s\nFAILED-DIR=<%s>\n' "${AGENTS_MAIN_ROOT:-}" "${ROOT_DECOY_DIR:-}"; exit 92; }
printf 'MAIN=%s\nDIR=%s\nREAL=%s\nSTATE=%s\nPLANS=%s\nTL3=%s\nTL4=%s\n' "${AGENTS_MAIN_ROOT:-}" "${ROOT_DECOY_DIR:-}" "${ROOT_DECOY_REAL_AGENTS_MAIN_ROOT:-}" "${WORKFLOW_STATE_DIR:-}" "${WORKFLOW_PLANS_DIR:-}" "${RUN_TL3:-}" "${RUN_TL4:-}"
for n in "${@:3}"; do printf 'OLD:%s=%s\n' "$n" "${!n:-}"; done
bash -c 'printf "CHILD=%s|%s|%s|%s\n" "${AGENTS_MAIN_ROOT:-}" "${ROOT_DECOY_DIR:-}" "${RUN_TL3:-}" "${RUN_TL4:-}"'
source "$1/tests/lib/root-decoy.sh" || exit 93
root_decoy_use_real_main_root
printf 'OPTIN=%s|%s\n' "$?" "${AGENTS_MAIN_ROOT:-}"
DRIVER
cat >"$TMP_ROOT/harness-driver.sh" <<'DRIVER'
source "$1/tests/lib/harness.sh" || exit 90
printf 'MAIN=%s\nDIR=%s\nREAL=%s\n' "${AGENTS_MAIN_ROOT:-}" "${ROOT_DECOY_DIR:-}" "${ROOT_DECOY_REAL_AGENTS_MAIN_ROOT:-}"
for n in "${@:2}"; do printf 'OLD:%s=%s\n' "$n" "${!n:-}"; done
bash -c 'printf "CHILD=%s\n" "${AGENTS_MAIN_ROOT:-}"'
DRIVER
cat >"$TMP_ROOT/report-driver.sh" <<'DRIVER'
source "$1/bin/lib/run-all-launch.sh" || exit 90
run_all_pin_test_env "$2" || exit 92
main_hits="$ROOT_DECOY_DIR/main/hits"; old_hits="$ROOT_DECOY_DIR/old/hits"
mkdir -p "$main_hits" "$old_hits" || exit 93
printf 'stub=other/run.js\ntest_id=run-other-1:tests/foo.sh\n' >"$main_hits/case-other.hit"
printf 'stub=stale/no-id.js\ntest_id=\n' >"$main_hits/case-stale.hit"
touch -t 200101010000 "$main_hits/case-stale.hit" || exit 94
sleep 1
printf 'stub=fresh/no-id.js\ntest_id=\n' >"$main_hits/case-fresh.hit"
printf 'stub=mine/own.js\ntest_id=%s:tests/x.sh\n' "$_RUN_ALL_DECOY_RUN" >"$old_hits/case-mine.hit"
printf 'RUN=%s\n' "$_RUN_ALL_DECOY_RUN"
run_all_root_decoy_report 2>"$3"
printf 'REPORT_RC=%s\n' "$?"
for f in "$main_hits/case-other.hit" "$main_hits/case-stale.hit" "$main_hits/case-fresh.hit" "$old_hits/case-mine.hit"; do
  if [[ -e "$f" ]]; then printf 'KEPT:%s\n' "${f##*/}"; else printf 'GONE:%s\n' "${f##*/}"; fi
done
run_all_root_decoy_report 2>>"$3"
printf 'SECOND_RC=%s\n' "$?"
rm -f "$main_hits"/case-*.hit "$old_hits"/case-*.hit
DRIVER
# The fixture header is composed here so that this file carries one such header line only.
FIX_HEAD="$(printf '#!/usr/bin/env bash\n# %s: none' Tests)"
readonly FIX_HEAD
# write_fixture <path> — the header above, then stdin as the body.
write_fixture() { { printf '%s\n' "$FIX_HEAD"; cat; } >"$1"; }
write_fixture "$FIX/clean-one.sh" <<'FIXTURE'
echo "ID-ONE=<${ROOT_DECOY_TEST_ID:-}>"
echo "MARKER-ONE=<$(cat "${AGENTS_MAIN_ROOT:-/nonexistent}/.env" 2>/dev/null | tr '\n' ' ')>"
exit 0
FIXTURE
write_fixture "$FIX/clean-two.sh" <<'FIXTURE'
echo "ID-TWO=<${ROOT_DECOY_TEST_ID:-}>"
exit 0
FIXTURE
write_fixture "$FIX/swallowed-hit.sh" <<'FIXTURE'
echo "ID-HIT=<${ROOT_DECOY_TEST_ID:-}>"
if grep -q '^ROOT_DECOY_MARKER=main$' "${AGENTS_MAIN_ROOT:-/nonexistent}/.env" 2>/dev/null; then
  node "$AGENTS_MAIN_ROOT/hooks/lib/load-env.js" >/dev/null 2>&1 || true
fi
exit 0
FIXTURE
# RD_OLD_NAME carries a retired name, so the fixture reaches the old tree without spelling one.
write_fixture "$FIX/swallowed-old-hit.sh" <<'FIXTURE'
echo "ID-OLD=<${ROOT_DECOY_TEST_ID:-}>"
old_name="${RD_OLD_NAME:-}"
old_root=""
[[ -n "$old_name" ]] && old_root="${!old_name:-}"
echo "OLD-ROOT-SET=<${old_root:+yes}>"
if grep -q '^ROOT_DECOY_MARKER=old$' "${old_root:-/nonexistent}/.env" 2>/dev/null; then
  node "$old_root/hooks/lib/load-env.js" >/dev/null 2>&1 || true
fi
exit 0
FIXTURE

case_begin "retired-env-name-list-is-readable" "tests/lib/root-decoy-build.js"
TRACKED_NAMES="$(sed -n '/^# retired-names:begin$/,/^# retired-names:end$/s/^# env //p' "$ROOT_N/tests/bin/feature-2561-root-names-residue.sh" | tr -d '\r' | sort)"
expect_ne "the tracked list names at least one retired env name" "$TRACKED_NAMES" ""
expect_eq "the builder prints exactly the env names of the tracked list" "$(printf '%s\n' "${RETIRED_NAMES[@]}" | sort)" "$TRACKED_NAMES"
case_end

PIN_OUT="$(launched bash "$TMP_ROOT/pin-driver.sh" "$ROOT_N" "$TMP_ROOT/work one" ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"} 2>&1)"
PIN_RC=$?
PIN_DIR="$(field "$PIN_OUT" DIR)"

case_begin "pin-test-env-switches-main-root-to-the-decoy" "bin/lib/run-all-launch.sh"
expect_lacks "run_all_pin_root_decoy is defined" "$PIN_OUT" "MISSING:run_all_pin_root_decoy"
expect_lacks "run_all_pin_test_env is defined" "$PIN_OUT" "MISSING:run_all_pin_test_env"
expect_eq "run_all_pin_test_env succeeds" "$PIN_RC" "0"
expect_has "the decoy lives under the run-all cache dir" "$PIN_DIR" "$CACHE/"
expect_eq "the main root is the decoy main tree" "$(field "$PIN_OUT" MAIN)" "$PIN_DIR/main"
expect_eq "the decoy main tree carries the main marker" "$(marker_of "$PIN_DIR/main")" "ROOT_DECOY_MARKER=main"
expect_has "the switch is exported to child processes" "$PIN_OUT" "CHILD=$PIN_DIR/main|$PIN_DIR|"
expect_eq "the value before the switch is kept" "$(field "$PIN_OUT" REAL)" "$REAL_CFG"
case_end

case_begin "pin-test-env-points-every-retired-name-at-old" "bin/lib/run-all-launch.sh"
expect_eq "the decoy old tree carries the old marker" "$(marker_of "$PIN_DIR/old")" "ROOT_DECOY_MARKER=old"
for name in ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"}; do
  expect_has "retired name $name points at the old tree" "$PIN_OUT" "OLD:$name=$PIN_DIR/old"
done
case_end

case_begin "pin-test-env-still-pins-the-state-dirs" "bin/lib/run-all-launch.sh"
expect_eq "the workflow state dir is pinned under the work dir" "$(field "$PIN_OUT" STATE)" "$TMP_ROOT/work one/workflow"
expect_eq "the plans dir is pinned under the work dir" "$(field "$PIN_OUT" PLANS)" "$TMP_ROOT/work one/plans"
case_end

case_begin "test-control-settings-are-carried-across-the-switch" "bin/lib/run-all-launch.sh"
expect_eq "RUN_TL3 is read from the real settings before the switch" "$(field "$PIN_OUT" TL3)" "off"
expect_eq "RUN_TL4 is read from the real settings before the switch" "$(field "$PIN_OUT" TL4)" "on"
expect_has "the carried settings are exported" "$PIN_OUT" "|off|on"
KEEP_OUT="$(RUN_TL3=on launched env RUN_TL3=on bash "$TMP_ROOT/pin-driver.sh" "$ROOT_N" "$TMP_ROOT/work two" 2>&1)"
expect_eq "a value already in the environment is kept" "$(field "$KEEP_OUT" TL3)" "on"
expect_eq "the other key is still carried" "$(field "$KEEP_OUT" TL4)" "on"
case_end

case_begin "real-main-root-is-restored-on-request" "tests/lib/root-decoy.sh"
expect_has "the opt-in returns the value the launcher recorded" "$PIN_OUT" "OPTIN=0|$REAL_CFG"
case_end

case_begin "pin-test-env-fails-without-the-retired-name-list" "bin/lib/run-all-launch.sh"
BARE="$TMP_ROOT/bare checkout"
mkdir -p "$BARE/bin/lib" "$BARE/tests/lib" "$BARE/hooks/lib"
cp "$ROOT_N"/bin/lib/*.sh "$BARE/bin/lib/"
cp "$ROOT_N/bin/run-with-timeout.sh" "$ROOT_N/bin/test-language-registry" "$ROOT_N/bin/get-config-var" "$BARE/bin/"
cp "$ROOT_N"/hooks/lib/test-language-registry.* "$ROOT_N/hooks/lib/load-env.js" "$BARE/hooks/lib/"
cp "$ROOT_N/tests/lib/root-decoy-build.js" "$ROOT_N/tests/lib/root-decoy.sh" "$BARE/tests/lib/"
# A tracked tree, so the builder could list its files: only the retired-name list is missing.
git init -q "$BARE"
git -C "$BARE" config core.hooksPath /dev/null
git -C "$BARE" -c core.autocrlf=false -c core.safecrlf=false add -A
expect_ne "the copied checkout tracks files the builder could mirror" "$(git -C "$BARE" ls-files | wc -l | tr -d ' ')" "0"
BARE_OUT="$(launched bash "$TMP_ROOT/pin-driver.sh" "$BARE" "$TMP_ROOT/work two" 2>&1)"
expect_eq "the pin reports failure instead of running without the old-name decoy" "$?" "92"
expect_has "the failure names the missing retired-name list" "$BARE_OUT" "retired environment names are unavailable"
expect_has "the main root is left as it was" "$BARE_OUT" "FAILED-MAIN=$REAL_CFG"
expect_has "no decoy directory is exported" "$BARE_OUT" "FAILED-DIR=<>"
case_end

RUN_OUT="$(launched bash "$ROOT_N/tests/run-all.sh" -j 1 "$FIX/clean-one.sh" "$FIX/clean-two.sh" 2>&1)"
RUN_RC=$?
ID_ONE="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^ID-ONE=<\(.*\)>$/\1/p')"
ID_TWO="$(printf '%s\n' "$RUN_OUT" | sed -n 's/^ID-TWO=<\(.*\)>$/\1/p')"

case_begin "run-all-gives-each-test-its-own-test-id" "bin/lib/run-all-launch.sh"
expect_eq "a run without hits passes" "$RUN_RC" "0"
expect_has "both fixture tests ran" "$RUN_OUT" "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2"
expect_ne "the first test receives a test id" "$ID_ONE" ""
expect_ne "the second test receives a test id" "$ID_TWO" ""
expect_ne "the two test ids differ" "$ID_ONE" "$ID_TWO"
expect_has "a launched test sees the decoy as its main root" "$RUN_OUT" "MARKER-ONE=<ROOT_DECOY_MARKER=main"
case_end

HIT_OUT="$(launched bash "$ROOT_N/tests/run-all.sh" -j 1 "$FIX/swallowed-hit.sh" 2>&1)"
HIT_RC=$?
ID_HIT="$(printf '%s\n' "$HIT_OUT" | sed -n 's/^ID-HIT=<\(.*\)>$/\1/p')"

case_begin "run-all-fails-the-run-when-a-stub-was-reached" "bin/lib/run-all-launch.sh"
expect_has "the fixture test itself passed" "$HIT_OUT" "PASS: $FIX/swallowed-hit.sh"
expect_ne "a swallowed stub hit fails the whole run" "$HIT_RC" "0"
expect_has "the report names the stub that was reached" "$HIT_OUT" "hooks/lib/load-env.js"
expect_ne "the test that reached the stub has a test id" "$ID_HIT" ""
expect_eq "the report names the test id next to the stub" "$(printf '%s\n' "$HIT_OUT" | grep -v '^ID-HIT=' | grep -F -- "hooks/lib/load-env.js" | grep -c -F -- "${ID_HIT:-<no test id>}" || true)" "1"
expect_eq "the pretend-real settings dir was never written" "$(find "$REAL_CFG" -type f | wc -l | tr -d ' ')" "1"
case_end

OLD_OUT="$(launched env RD_OLD_NAME="${RETIRED_NAMES[0]}" bash "$ROOT_N/tests/run-all.sh" -j 1 "$FIX/swallowed-old-hit.sh" 2>&1)"
OLD_RC=$?
ID_OLD="$(printf '%s\n' "$OLD_OUT" | sed -n 's/^ID-OLD=<\(.*\)>$/\1/p')"

case_begin "run-all-fails-the-run-when-an-old-tree-stub-was-reached" "bin/lib/run-all-launch.sh"
expect_has "the fixture test itself passed" "$OLD_OUT" "PASS: $FIX/swallowed-old-hit.sh"
expect_has "the retired name reached the test" "$OLD_OUT" "OLD-ROOT-SET=<yes>"
expect_ne "a swallowed hit in the old tree fails the whole run" "$OLD_RC" "0"
expect_ne "the test that reached the old stub has a test id" "$ID_OLD" ""
expect_has "the report names the old tree, the stub and the test id" "$OLD_OUT" "root decoy hit: old/hooks/lib/load-env.js$TAB${ID_OLD:-<no test id>}"
case_end

REPORT_ERR="$TMP_ROOT/report.err"
REPORT_OUT="$(launched bash "$TMP_ROOT/report-driver.sh" "$ROOT_N" "$TMP_ROOT/work three" "$REPORT_ERR" 2>&1)"
REPORT_TEXT="$(cat "$REPORT_ERR" 2>/dev/null || true)"
REPORT_RUN="$(field "$REPORT_OUT" RUN)"

case_begin "hit-report-counts-only-this-run-and-fresh-unnamed-records" "bin/lib/run-all-launch.sh"
expect_ne "the run has a token" "$REPORT_RUN" ""
expect_eq "two hits fail the report" "$(field "$REPORT_OUT" REPORT_RC)" "1"
expect_has "the count covers exactly the two records" "$REPORT_TEXT" "] 2 root decoy hit(s)"
expect_has "this run's record is reported with its test id" "$REPORT_TEXT" "root decoy hit: old/mine/own.js$TAB${REPORT_RUN:-<no run>}:tests/x.sh"
expect_has "a fresh record without a test id is reported" "$REPORT_TEXT" "root decoy hit: main/fresh/no-id.js$TAB(no test id)"
expect_lacks "a record of another run is ignored" "$REPORT_TEXT" "other/run.js"
expect_lacks "a record without a test id from before the pin is ignored" "$REPORT_TEXT" "stale/no-id.js"
expect_has "this run's record is removed after the report" "$REPORT_OUT" "GONE:case-mine.hit"
expect_has "another run's record is left for that run" "$REPORT_OUT" "KEPT:case-other.hit"
expect_has "the stale unnamed record is left alone" "$REPORT_OUT" "KEPT:case-stale.hit"
expect_has "the fresh unnamed record is left alone" "$REPORT_OUT" "KEPT:case-fresh.hit"
expect_eq "a second report in the same run is silent" "$(field "$REPORT_OUT" SECOND_RC)" "0"
expect_eq "the hits are reported once" "$(printf '%s\n' "$REPORT_TEXT" | grep -c -F -- 'root decoy hit:' || true)" "2"
case_end

HARNESS_OUT="$(cd "$TMP_ROOT/neutral" && env "${UNSET_ARGS[@]}" -u AGENTS_MAIN_ROOT RUN_ALL_CACHE_DIR="$TMP_ROOT/harness cache" bash "$RWT" 120 bash "$TMP_ROOT/harness-driver.sh" "$ROOT_N" ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"} 2>&1)"
HARNESS_DIR="$(field "$HARNESS_OUT" DIR)"

case_begin "harness-alone-builds-and-exports-the-decoy" "tests/lib/harness.sh"
expect_has "a standalone test gets a decoy under the cache dir" "$HARNESS_DIR" "$TMP_ROOT/harness cache/"
expect_eq "its main root is the decoy main tree" "$(field "$HARNESS_OUT" MAIN)" "${HARNESS_DIR:-<no decoy>}/main"
expect_eq "the main tree carries the main marker" "$(marker_of "$HARNESS_DIR/main")" "ROOT_DECOY_MARKER=main"
expect_has "the main root is exported to child processes" "$HARNESS_OUT" "CHILD=${HARNESS_DIR:-<no decoy>}/main"
for name in ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"}; do
  expect_has "the harness points $name at the old tree" "$HARNESS_OUT" "OLD:$name=${HARNESS_DIR:-<no decoy>}/old"
done
case_end

case_begin "harness-reuses-the-decoy-the-launcher-provided" "tests/lib/harness.sh"
GIVEN="$TMP_ROOT/given decoy"
run_with_timeout 120 node "$BUILDER" --out "$GIVEN"
expect_eq "a decoy can be built for the launcher role" "$?" "0"
GIVEN_OUT="$(cd "$TMP_ROOT/neutral" && env "${UNSET_ARGS[@]}" ROOT_DECOY_DIR="$GIVEN" ROOT_DECOY_REAL_AGENTS_MAIN_ROOT="$REAL_CFG" AGENTS_MAIN_ROOT="$GIVEN/main" RUN_ALL_CACHE_DIR="$TMP_ROOT/unused cache" bash "$RWT" 120 bash "$TMP_ROOT/harness-driver.sh" "$ROOT_N" ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"} 2>&1)"
expect_eq "the provided decoy is kept" "$(field "$GIVEN_OUT" DIR)" "$GIVEN"
expect_eq "the main root stays on the provided decoy" "$(field "$GIVEN_OUT" MAIN)" "$GIVEN/main"
expect_eq "the launcher-recorded real value is kept" "$(field "$GIVEN_OUT" REAL)" "$REAL_CFG"
for name in ${RETIRED_NAMES[@]+"${RETIRED_NAMES[@]}"}; do
  expect_has "the harness points $name at the provided old tree" "$GIVEN_OUT" "OLD:$name=$GIVEN/old"
done
if [[ -e "$TMP_ROOT/unused cache" ]]; then fail "no second decoy is built" "$TMP_ROOT/unused cache exists"; else pass "no second decoy is built"; fi
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
