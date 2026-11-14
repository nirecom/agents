#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-branch-paths.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, branch-rerun, scope:issue-specific, pwsh-not-required, TL2, timeout, budget
# #2956 S4 step 4 / S8 table 2 - an interrupted branch run (rc 124 / 142) missing a base FAIL case is
# pending (never a proof); with every base case it is compared as usual; a finished fails-alone run
# missing one counts it as fixed and stays preexisting; an unjudgeable re-run (timeout, decoy,
# unrunnable) is decided here too. Kill, skip and flaky rows: feature-2956-baseline-branch-kill-skip.sh.
# Other table 2 rows: feature-2688-branch-{cache,rerun}.sh and feature-2431-run-tests-baseline/cli-unsupported.sh.
# TL3 gap: a real harness stopped mid-case by its own alarm is out of scope.

set -uo pipefail

# Pin once at top level for the isolation checker; _lib.sh re-points both into its own temp root.
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-2956-branch-paths-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-2956-branch-paths-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"
# shellcheck source=tests/bin/feature-2956-baseline-ledger-paths/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2956-baseline-ledger-paths/_lib.sh"

R="$TMPROOT/t2"; MK="$R.marks"
lp_rows_run "$R" 'i124|a b|1|a|124
i124all|a b|1|a b|124
i142|a b|1|a|142
alone|a b|1|a|1'

case_begin "interrupted-run-missing-a-base-case-is-pending" "bin/run-tests-baseline"
ck "t2: exit 1 (pending rows present)" 1 "$RTB_RC"
for s in i124 i142; do
  present "$s: the branch copy ran" "$MK/branch-$s"
  has_line "$s: partial records are not a proof" "BASELINE: new-case-failure-on-branch tests/bin/$s.sh case-records-missing-on-branch"
  lacks_line "$s: not preexisting" "BASELINE: preexisting tests/bin/$s.sh"
done
case_end

case_begin "interrupted-run-with-every-base-case-is-compared" "bin/run-tests-baseline"
has_line "i124all: same lines - preexisting" "BASELINE: preexisting tests/bin/i124all.sh"
case_end

case_begin "fails-alone-missing-a-base-case-stays-preexisting" "bin/lib/run-tests-baseline-branch.sh"
present "alone: the branch copy ran" "$MK/branch-alone"
has_line "alone: a finished run counts the absent case as fixed" "BASELINE: preexisting tests/bin/alone.sh"
has_line "t2: summary counts" "file_verdict=0 new_on_branch=2"
case_end

# #2688 T2: when the standalone re-run itself cannot be judged, S8 table 2 decides: a timeout under an
# explicit --per-test-timeout below the derived one (the #3015 exception) is undetermined budget-exhausted
# (exit 8), never cached as timeout-after-<N>s; a decoy HIT or UNRUNNABLE leaves no branch records, so it is
# new-case-failure-on-branch case-records-missing-on-branch (pending, fail-closed). The seed is exit 124, so
# misreading it as "standalone pass" would emit a flaky line.
# commit_branch <repo> - commit the changes on feature (keeps the own checkout clean).
commit_branch() { git -C "$1" add -A; git -C "$1" commit -q -m "branch variant"; }
# no_branch_verdict <label> - no branch-side pass line appears and no base-only preexisting is emitted.
no_branch_verdict() {
  lacks_line "$1: no flaky line" "flaky-timeout-on-branch"
  lacks_line "$1: no passes-alone line" "passes-alone-on-branch"
  lacks_line "$1: not a base-only preexisting" "BASELINE: preexisting tests/bin/t.sh"
}
# records_missing_pending <label> <sid> - the unjudgeable branch copy holds run_tests pending.
records_missing_pending() {
  ck "$1: exit 1 (pending)" 1 "$RTB_RC"
  has_line "$1: records-missing line" "BASELINE: new-case-failure-on-branch tests/bin/t.sh case-records-missing-on-branch"
  no_branch_verdict "$1"
  ck "$1: run_tests stays pending" "pending" "$(field "$2" status)"
}

case_begin "branch-rerun-timeout-is-budget-exhausted" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/inc-to"; mk_repo "$R" 0; S="br-inc-to-$$"; mkdir -p "$R.cache"
printf '#!/usr/bin/env bash\ntouch "%s"\nsleep 30\nexit 0\n' "$(np "$R.marks")/branch" > "$R/tests/bin/t.sh"
commit_branch "$R"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
present "inc-to: the branch copy started alone" "$R.marks/branch"
ck "inc-to: exit 8 (explicit 10s below the derived 300s, re-run requested)" 8 "$RTB_RC"
has_line "inc-to: budget-exhausted line" "BASELINE: undetermined tests/bin/t.sh budget-exhausted"
has_line "inc-to: the unrecorded timeout is announced" "run-tests-baseline: timeout not recorded: tests/bin/t.sh requested 10s;"
ck "inc-to: no timeout-after- row in the branch cache" "" "$(grep -ls 'timeout-after-' "$R.cache"/branch.v2.*.seg)"
no_branch_verdict "inc-to"
case_end

case_begin "branch-rerun-decoy-hit-is-records-missing" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/inc-decoy"; mk_repo "$R" 0; S="br-inc-decoy-$$"; mkdir -p "$R.cache"
ROOT_VAR="AGENTS_MAIN""_ROOT"
printf '#!/usr/bin/env bash\ntouch "%s"\nnode "$%s/hooks/lib/load-env.js" >/dev/null 2>&1 || true\nexit 0\n' \
  "$(np "$R.marks")/branch" "$ROOT_VAR" > "$R/tests/bin/t.sh"
commit_branch "$R"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S" ROOT_DECOY_DIR="$(np "$TMPROOT/decoy-inc")"
present "inc-decoy: the branch copy ran alone" "$R.marks/branch"
records_missing_pending "inc-decoy" "$S"
case_end

case_begin "branch-rerun-unrunnable-is-records-missing" "bin/lib/run-tests-baseline-branch.sh"
# shellcheck source=tests/lib/test-language-registry-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/test-language-registry-fixture.sh"
R="$TMPROOT/inc-unr"; mk_repo "$R" 0; S="br-inc-unr-$$"; mkdir -p "$R.cache"
# The launcher is also placed on main (keeps the diff small so the merge base is not SUSPECT), and only the feature side
# is made to require a tool absent from the registry's bash entry. The base launcher runs normally.
git -C "$R" checkout -q main
mkdir -p "$R/bin" "$R/hooks/lib"
cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$R/bin/"
cp "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$R/bin/run-with-timeout.sh"
install_test_language_registry "$R" "$SCRIPT_CHECKOUT_ROOT" && git -C "$R" add -A && git -C "$R" commit -q -m launcher
git -C "$R" checkout -q feature
git -C "$R" merge -q --no-edit main
if [ -f "$R/hooks/lib/test-language-registry.json" ] && run_with_timeout 20 node -e '
const fs = require("fs"); const p = process.argv[1]; const t = JSON.parse(fs.readFileSync(p, "utf8"));
t.entries.find((e) => e.id === "bash").launch.requires = "no-such-tool-2688";
fs.writeFileSync(p, JSON.stringify(t, null, 2) + "\n");' "$(np "$R/hooks/lib/test-language-registry.json")"; then
  commit_branch "$R"
  seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
  rtb "$R.cache" "$R" "$S"
  absent "inc-unr: the branch copy never ran (UNRUNNABLE)" "$R.marks/branch"
  records_missing_pending "inc-unr" "$S"
else
  fail "inc-unr: fixture error — could not install the branch registry"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
