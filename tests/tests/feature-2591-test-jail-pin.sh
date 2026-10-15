#!/usr/bin/env bash
# Tests: experimental/test-jail/run-jailed.sh, experimental/test-jail/run-one.sh, experimental/test-jail/run-list.sh
# Tags: scope:issue-specific, tl2, test-jail, fixture-isolation
#
# #2591: a pin the tree cannot give is an error (rc 94) unless --allow-weaker-pin is passed, and
# the pin level actually obtained is recorded: "PINNED: obtained=<x> requested=<y>" in the log
# and a 4th results.tsv column. Fixture trees (stub launchers, no real decoy): common.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2591-test-jail/common.sh"
jt_setup || { echo "FAIL: fixture setup"; exit 1; }
T_NONE="$TMP_ROOT/tree-none"
T_STATE="$TMP_ROOT/tree-state"
T_FULL="$TMP_ROOT/tree-full"
jt_make_tree "$T_NONE" none-fn && jt_make_tree "$T_STATE" state-fn && jt_make_tree "$T_FULL" full-fn \
  || { echo "FAIL: fixture tree"; exit 1; }

case_begin "pin-full-unmet-is-an-error" "experimental/test-jail/run-jailed.sh"
jt_sentinel p1
jt_jail --tree "$T_NONE" --pin full tests/ok.sh
expect_eq "full on a tree without pin functions: rc" "$JT_RC" "94"
expect_has "full unmet: SAFE-RUN line" "$JT_ERR" "SAFE-RUN: pin unmet"
expect_has "full unmet: names the flag" "$JT_ERR" "--allow-weaker-pin"
expect_lacks "full unmet: no obtained= line" "$JT_ALL" "PINNED: obtained="
expect_eq "full unmet: test body did not run (no sentinel)" "$(jt_ran)" "no"
case_end

case_begin "pin-state-unmet-is-an-error" "experimental/test-jail/run-jailed.sh"
jt_sentinel p2
jt_jail --tree "$T_NONE" --pin state tests/ok.sh
expect_eq "state on a tree without pin functions: rc" "$JT_RC" "94"
expect_has "state unmet: SAFE-RUN line" "$JT_ERR" "SAFE-RUN: pin unmet"
expect_has "state unmet: names the flag" "$JT_ERR" "--allow-weaker-pin"
expect_lacks "state unmet: no obtained= line" "$JT_ALL" "PINNED: obtained="
expect_eq "state unmet: test body did not run (no sentinel)" "$(jt_ran)" "no"
case_end

case_begin "weaker-pin-allowed-falls-to-none" "experimental/test-jail/run-jailed.sh"
jt_sentinel p3
jt_jail --tree "$T_NONE" --pin full --allow-weaker-pin tests/ok.sh
expect_eq "full -> none with the flag: rc" "$JT_RC" "0"
expect_has "full -> none: first PINNED line" "$(jt_first_pinned)" "PINNED: obtained=none requested=full"
expect_has "full -> none: test body ran" "$JT_OUT" "JT_BODY_RAN"
expect_eq "full -> none: sentinel reached the test" "$(jt_ran)" "yes"
case_end

case_begin "state-launcher-full-request" "experimental/test-jail/run-jailed.sh"
jt_sentinel p4a
jt_jail --tree "$T_STATE" --pin full tests/ok.sh
expect_eq "full on a state-only tree: rc" "$JT_RC" "94"
expect_eq "full on a state-only tree: test body did not run (no sentinel)" "$(jt_ran)" "no"
jt_sentinel p4b
jt_jail --tree "$T_STATE" --pin full --allow-weaker-pin tests/ok.sh
expect_eq "full -> state with the flag: rc" "$JT_RC" "0"
expect_has "full -> state: first PINNED line" "$(jt_first_pinned)" "PINNED: obtained=state requested=full"
expect_eq "full -> state with the flag: sentinel reached the test" "$(jt_ran)" "yes"
jt_sentinel p4c
jt_jail --tree "$T_STATE" --pin state tests/ok.sh
expect_eq "state on a state tree needs no flag: rc" "$JT_RC" "0"
expect_has "state on a state tree: first PINNED line" "$(jt_first_pinned)" "PINNED: obtained=state requested=state"
expect_eq "state on a state tree: sentinel reached the test" "$(jt_ran)" "yes"
case_end

case_begin "full-launcher-gets-full" "experimental/test-jail/run-jailed.sh"
jt_sentinel p5
jt_jail --tree "$T_FULL" --pin full tests/ok.sh
expect_eq "full on a full tree: rc" "$JT_RC" "0"
expect_has "full on a full tree: first PINNED line" "$(jt_first_pinned)" "PINNED: obtained=full requested=full"
expect_eq "full on a full tree: sentinel reached the test" "$(jt_ran)" "yes"
case_end

case_begin "pin-none-needs-no-flag" "experimental/test-jail/run-jailed.sh"
jt_sentinel p6
jt_jail --tree "$T_NONE" --pin none tests/ok.sh
expect_eq "none on any tree: rc" "$JT_RC" "0"
expect_has "none: first PINNED line" "$(jt_first_pinned)" "PINNED: obtained=none requested=none"
expect_eq "none: sentinel reached the test" "$(jt_ran)" "yes"
case_end

case_begin "run-one-passes-the-flag-and-records-obtained" "experimental/test-jail/run-one.sh"
R7="$TMP_ROOT/run-one-allow"
mkdir -p "$R7/logs"
JT_ENVV=(JAIL_RUN_DIR="$R7" JAIL_TREE="$T_NONE" JAIL_PIN=full JAIL_SECS=60 JAIL_ALLOW_WEAKER_PIN=1)
jt_sentinel p7a
jt_exec run-one.sh tests/ok.sh
expect_eq "run-one with JAIL_ALLOW_WEAKER_PIN=1: rc" "$JT_RC" "0"
expect_eq "run-one allow: sentinel reached the test" "$(jt_ran)" "yes"
expect_eq "run-one allow: results.tsv columns" "$(awk -F'\t' 'NR==1{print NF}' "$R7/results.tsv")" "4"
expect_eq "run-one allow: rc column" "$(awk -F'\t' 'NR==1{print $1}' "$R7/results.tsv")" "0"
expect_eq "run-one allow: test column" "$(awk -F'\t' 'NR==1{print $3}' "$R7/results.tsv")" "tests/ok.sh"
expect_eq "run-one allow: obtained column" "$(awk -F'\t' 'NR==1{print $4}' "$R7/results.tsv")" "none"
R7B="$TMP_ROOT/run-one-deny"
mkdir -p "$R7B/logs"
JT_ENVV=(-u JAIL_ALLOW_WEAKER_PIN JAIL_RUN_DIR="$R7B" JAIL_TREE="$T_NONE" JAIL_PIN=full JAIL_SECS=60)
jt_sentinel p7b
jt_exec run-one.sh tests/ok.sh
expect_eq "run-one deny: test body did not run (no sentinel)" "$(jt_ran)" "no"
expect_eq "run-one without the flag: results.tsv columns" "$(awk -F'\t' 'NR==1{print NF}' "$R7B/results.tsv")" "4"
expect_eq "run-one deny: rc column" "$(awk -F'\t' 'NR==1{print $1}' "$R7B/results.tsv")" "94"
expect_eq "run-one deny: obtained column" "$(awk -F'\t' 'NR==1{print $4}' "$R7B/results.tsv")" "unknown"
expect_has "run-one deny: log has SAFE-RUN" "$(cat "$R7B/logs/tests__ok.sh.log")" "SAFE-RUN:"
case_end

case_begin "run-list-weaker-pin-argument" "experimental/test-jail/run-list.sh"
LIST8="$TMP_ROOT/list8.txt"
printf '%s\n' tests/ok.sh tests/missing.sh >"$LIST8"
R8="$TMP_ROOT/run-list-allow"
jt_run_list "$LIST8" "$R8" "$T_NONE" full allow
if [[ "$JT_RC" -eq 4 ]]; then
  skip "run-list weaker-pin: no host test lane could be acquired (rc 4); lanes are a host-wide resource"
else
  expect_eq "run-list allow: rc" "$JT_RC" "0"
  expect_eq "run-list allow: results.tsv columns" "$(awk -F'\t' 'NR==1{print NF}' "$R8/results.tsv")" "4"
  expect_eq "run-list allow: obtained column" "$(awk -F'\t' 'NR==1{print $4}' "$R8/results.tsv")" "none"
  expect_eq "run-list allow: requested.txt equals the list" "$(cat "$R8/requested.txt" 2>/dev/null)" "$(cat "$LIST8")"
  jt_run_list "$LIST8" "$TMP_ROOT/run-list-bad" "$T_NONE" full maybe
  expect_eq "run-list: unknown 7th argument value: rc" "$JT_RC" "2"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
