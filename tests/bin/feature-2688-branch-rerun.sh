#!/usr/bin/env bash
# tests/bin/feature-2688-branch-rerun.sh
# Tests: bin/lib/run-tests-baseline-branch.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, branch-rerun, flaky, budget, cache, input-version, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:runtime-limit
# dup-group-keep: together with feature-2688-branch-cache.sh (same Tests:), the real CLI runs overlap and exceed the 120 s limit.
# #2688 T2 - standalone re-run on the branch side. exit 124 + standalone pass is flaky-timeout-on-branch (auto-accepted),
# any other exit + standalone pass is passes-alone-on-branch (pending), and a standalone failure proceeds to the next stage (base).
# The budget slice (including boundaries) and cache (input_version) cases are in feature-2688-branch-cache.sh.
# TL3 gap: the path where a real /run-tests records failing_test_exits is substituted by seed.

set -uo pipefail

# Pin once at top level for the isolation checker; _lib.sh re-points both into its own temp root.
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-2688-rerun-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-2688-rerun-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"

case_begin "branch-lib-present" "bin/lib/run-tests-baseline-branch.sh"
[ -f "$BRANCH_LIB" ] && pass "run-tests-baseline-branch.sh exists" \
  || fail "run-tests-baseline-branch.sh exists" "missing (not implemented yet)"
case_end

case_begin "timeout-then-pass-alone-is-flaky" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/j1"; mk_repo "$R" 0; S="br-j1-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
ck "j1: exit 0 (recorded)" 0 "$RTB_RC"
has_line "j1: flaky line" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
present "j1: the branch copy ran alone" "$R.marks/branch"
absent "j1: the base copy never ran" "$R.marks/base"
ck "j1: completion_basis" "baseline-auto-accepted" "$(field "$S" completion_basis)"
ck "j1: run_tests complete" "complete" "$(field "$S" status)"
case_end

case_begin "other-exit-then-pass-alone-is-pending" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/j2"; mk_repo "$R" 0; S="br-j2-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":1}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
ck "j2: exit 1 (pending)" 1 "$RTB_RC"
has_line "j2: passes-alone line" "BASELINE: passes-alone-on-branch tests/bin/t.sh"
present "j2: the branch copy ran alone" "$R.marks/branch"
absent "j2: the base copy never ran" "$R.marks/base"
ck "j2: run_tests stays pending" "pending" "$(field "$S" status)"
ck "j2: no completion_basis" "(absent)" "$(field "$S" completion_basis)"
case_end

case_begin "unknown-exit-then-pass-alone-is-pending" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/j3"; mk_repo "$R" 0; S="br-j3-$$"; mkdir -p "$R.cache"
seed "$S" none tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
ck "j3: exit 1 (pending)" 1 "$RTB_RC"
has_line "j3: passes-alone line" "BASELINE: passes-alone-on-branch tests/bin/t.sh"
present "j3: the branch copy ran alone" "$R.marks/branch"
ck "j3: run_tests stays pending" "pending" "$(field "$S" status)"
case_end

case_begin "fails-alone-goes-on-to-base" "bin/run-tests-baseline"
R="$TMPROOT/j4"; mk_repo "$R" 1; S="br-j4-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
ck "j4: exit 0 (preexisting at base)" 0 "$RTB_RC"
present "j4: the branch copy ran alone first" "$R.marks/branch"
present "j4: then the base copy ran" "$R.marks/base"
has_line "j4: preexisting line" "BASELINE: preexisting tests/bin/t.sh"
lacks_line "j4: no flaky line" "flaky-timeout-on-branch"
ck "j4: completion_basis" "baseline-preexisting" "$(field "$S" completion_basis)"
case_end

# With multiple failing tests, each is judged individually. If even one is pending, the whole result is pending (exit 1).
case_begin "mixed-flaky-and-passes-alone-is-pending" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/mix1"; mk_repo "$R" 0; add_test "$R" u.sh 1 0; S="br-mix1-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124,"tests/bin/u.sh":1}' tests/bin/t.sh tests/bin/u.sh
rtb "$R.cache" "$R" "$S"
ck "mix1: exit 1 (one pending wins)" 1 "$RTB_RC"
has_line "mix1: t is flaky" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
has_line "mix1: u passes alone" "BASELINE: passes-alone-on-branch tests/bin/u.sh"
lacks_line "mix1: u is not flaky" "flaky-timeout-on-branch tests/bin/u.sh"
present "mix1: t ran alone" "$R.marks/branch"
present "mix1: u ran alone" "$R.marks/branch-u"
ck "mix1: run_tests stays pending" "pending" "$(field "$S" status)"
ck "mix1: no completion_basis" "(absent)" "$(field "$S" completion_basis)"
case_end

case_begin "mixed-flaky-and-fails-alone-is-recorded" "bin/run-tests-baseline"
R="$TMPROOT/mix2"; mk_repo "$R" 0; add_test "$R" u.sh 1 1; S="br-mix2-$$"; mkdir -p "$R.cache"
seed "$S" '{"tests/bin/t.sh":124,"tests/bin/u.sh":124}' tests/bin/t.sh tests/bin/u.sh
rtb "$R.cache" "$R" "$S"
ck "mix2: exit 0 (flaky + preexisting)" 0 "$RTB_RC"
has_line "mix2: t is flaky" "BASELINE: flaky-timeout-on-branch tests/bin/t.sh"
has_line "mix2: u is preexisting" "BASELINE: preexisting tests/bin/u.sh"
absent "mix2: t never ran at base" "$R.marks/base"
present "mix2: u ran at base" "$R.marks/base-u"
ck "mix2: completion_basis (one auto-accept wins)" "baseline-auto-accepted" "$(field "$S" completion_basis)"
ck "mix2: run_tests complete" "complete" "$(field "$S" status)"
case_end

# When the standalone re-run itself cannot be judged (timeout, decoy HIT, UNRUNNABLE), the branch side
# makes no judgment and proceeds to the base stage. The seed is exit 124, so misreading it as "standalone pass" would emit a flaky line.
# commit_branch <repo> - commit the changes on feature (keeps the own checkout clean).
commit_branch() { git -C "$1" add -A; git -C "$1" commit -q -m "branch variant"; }
# goes_on_to_base <label> <repo> <sid> - base runs and yields preexisting, and no branch-side line appears.
goes_on_to_base() {
  ck "$1: exit 0 (preexisting at base)" 0 "$RTB_RC"
  present "$1: the base copy ran" "$2.marks/base"
  has_line "$1: preexisting line" "BASELINE: preexisting tests/bin/t.sh"
  lacks_line "$1: no flaky line" "flaky-timeout-on-branch"
  lacks_line "$1: no passes-alone line" "passes-alone-on-branch"
  ck "$1: completion_basis" "baseline-preexisting" "$(field "$3" completion_basis)"
}

case_begin "branch-rerun-timeout-goes-on-to-base" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/inc-to"; mk_repo "$R" 0; S="br-inc-to-$$"; mkdir -p "$R.cache"
printf '#!/usr/bin/env bash\ntouch "%s"\nsleep 30\nexit 0\n' "$(np "$R.marks")/branch" > "$R/tests/bin/t.sh"
commit_branch "$R"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S"
present "inc-to: the branch copy started alone" "$R.marks/branch"
goes_on_to_base "inc-to" "$R" "$S"
case_end

case_begin "branch-rerun-decoy-hit-goes-on-to-base" "bin/lib/run-tests-baseline-branch.sh"
R="$TMPROOT/inc-decoy"; mk_repo "$R" 0; S="br-inc-decoy-$$"; mkdir -p "$R.cache"
ROOT_VAR="AGENTS_MAIN""_ROOT"
printf '#!/usr/bin/env bash\ntouch "%s"\nnode "$%s/hooks/lib/load-env.js" >/dev/null 2>&1 || true\nexit 0\n' \
  "$(np "$R.marks")/branch" "$ROOT_VAR" > "$R/tests/bin/t.sh"
commit_branch "$R"
seed "$S" '{"tests/bin/t.sh":124}' tests/bin/t.sh
rtb "$R.cache" "$R" "$S" ROOT_DECOY_DIR="$(np "$TMPROOT/decoy-inc")"
present "inc-decoy: the branch copy ran alone" "$R.marks/branch"
goes_on_to_base "inc-decoy" "$R" "$S"
case_end

case_begin "branch-rerun-unrunnable-goes-on-to-base" "bin/lib/run-tests-baseline-branch.sh"
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
  goes_on_to_base "inc-unr" "$R" "$S"
else
  fail "inc-unr: fixture error — could not install the branch registry"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
