#!/usr/bin/env bash
# tests/bin/feature-2669-baseline-hits.sh
# Tests: bin/run-tests-baseline, bin/workflow/lib/run-tests-baseline-evidence.js, hooks/workflow-mark/run-tests-baseline-accept-handler.js, hooks/workflow-run-tests.js, tests/run-all.sh
# Tags: run-tests, baseline, command-guard, hit-attribution, scope:issue-specific, pwsh-not-required, TL2
#
# #2669: a failing test that also reached the command guard is that test's one FAIL, so the
# hook keeps a failing list the baseline CLI can classify. A hit no test can own (HITS>0) gets
# its own exit (6) and is never accepted through the user's sentinel.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OWN_CACHE_DIR=""
if [[ -z "${RUN_ALL_CACHE_DIR:-}" ]]; then
  OWN_CACHE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t root-decoy-cache)"
  [[ -n "$OWN_CACHE_DIR" && -d "$OWN_CACHE_DIR" ]] || { echo "cannot create a decoy cache directory" >&2; exit 1; }
  export RUN_ALL_CACHE_DIR="$OWN_CACHE_DIR"
fi
readonly OWN_CACHE_DIR
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
ISO_FIRST="$(make_tmp)"
harness_isolate "$ISO_FIRST"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# The baseline fixtures (mk_fixture_repo, rtb_cli_run, read_step_field) and the sentinel driver
# (ca_mark, ca_grant). helpers.sh re-pins both state dirs under its own TMPROOT and owns the trap.
SUB_2431="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline"
# shellcheck source=tests/bin/feature-2431-run-tests-baseline/helpers.sh
source "$SUB_2431/helpers.sh"
rm -rf "$ISO_FIRST"
# shellcheck source=tests/bin/feature-2431-run-tests-baseline/cli-accept.sh
source "$SUB_2431/cli-accept.sh"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

T_PRE="tests/bin/test-preexisting.sh"

bh_ck() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — want=[$2] got=[$3]"; fi; }
bh_has() { printf '%s\n' "$2" | grep -qE -- "$3" && pass "$1" || fail "$1 — no line matching [$3] in: $2"; }
bh_lacks() { printf '%s\n' "$2" | grep -qE -- "$3" && fail "$1 — unexpected line matching [$3] in: $2" || pass "$1"; }
bh_count() { printf '%s\n' "$1" | tr -d '\r' | grep -cE -- "$2"; }
bh_last() { printf '%s\n' "$1" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1; }

# bh_hook <sid> <exit-code> <stdout> — the stdout of `bash tests/run-all.sh` through the real hook.
cat >"$TMPROOT/bh-payload.js" <<'EOF'
"use strict";
const [command, code, stdout, sid, cwd] = process.argv.slice(2);
process.stdout.write(JSON.stringify({ tool_name: "Bash", session_id: sid,
  tool_input: { command, cwd }, tool_response: { exit_code: Number(code), stdout } }));
EOF
bh_hook() {
  node "$(np "$TMPROOT/bh-payload.js")" "bash $AGENTS_WIN/tests/run-all.sh" "$2" "$3" "$1" "$AGENTS_WIN" \
    >"$TMPROOT/bh-hook-in.json"
  run_with_timeout 30 node "$AGENTS_WIN/hooks/workflow-run-tests.js" <"$TMPROOT/bh-hook-in.json" >/dev/null 2>&1 || true
}

# bh_run_all <test...> — the real launcher, run from a neutral dir with no inherited decoy or
# guard, so the guard it pins is this run's own; sets BH_OUT and BH_RC (stderr is dropped).
bh_run_all() {
  local -a unset_env=(-u ROOT_DECOY_DIR -u ROOT_DECOY_REAL_AGENTS_MAIN_ROOT -u ROOT_DECOY_TEST_ID -u RUN_TL3 -u RUN_TL4
    -u TEST_RUN_ROOT -u TEST_HOST_TMPDIR -u COMMAND_GUARD_DIR -u CLAUDE_CODE_SESSION_ID)
  local name
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] && unset_env+=(-u "$name")
  done < <(node "$AGENTS_WIN/tests/lib/root-decoy-build.js" --print-retired-env-names 2>/dev/null)
  mkdir -p "$TMPROOT/neutral" "$TMPROOT/bh-cache" "$TMPROOT/pretend-real" || return 1
  printf 'RUN_TL3=off\nRUN_TL4=off\nROOT_DECOY_MARKER=pretend-real\n' >"$TMPROOT/pretend-real/.env"
  BH_RC=0
  BH_OUT="$(cd "$TMPROOT/neutral" && env "${unset_env[@]}" TEST_HOST_TMPDIR="$TMPROOT/bh-cache" \
    RUN_ALL_CACHE_DIR="$TMPROOT/bh-cache" RUN_ALL_PROGRESS=off AGENTS_MAIN_ROOT="$TMPROOT/pretend-real" \
    bash "$RWT" 120 bash "$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh" -j 1 "$@" 2>/dev/null)" || BH_RC=$?
}

# A fixture repo whose base copy of the test fails cleanly and whose HEAD copy also reaches gh.
bh_repo() {
  local repo="$1"
  mk_fixture_repo "$repo" >/dev/null
  printf '#!/usr/bin/env bash\ngh --version >/dev/null 2>&1 || true\nexit 1\n' >"$repo/$T_PRE"
  git -C "$repo" add "$T_PRE"
  git -C "$repo" commit -q -m "the head copy also reaches gh"
}

# A run with one unattributed hit, as tests/run-all.sh prints it once HITS exists.
bh_hits_stdout() {
  printf '%s\n' "PASS: tests/bin/test-broken.sh" \
    "HIT: worktree-change tests/bin/test-broken.sh tree=/fixture kind=tracked paths=clean.txt" "" \
    "Results: PASS=1  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0  HITS=1" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 HITS=1"
}

run_failing_test_with_a_hit() {
  local repo="$TMPROOT/repo-hit-fail" sid="bh-t1-$$" fails hook_out
  bh_repo "$repo"
  bh_run_all "$repo/$T_PRE"
  fails="$(bh_count "$BH_OUT" '^FAIL: .* \(exit -?[0-9]+\)$')"
  bh_ck "T1: the run prints one file-level FAIL line" "1" "$fails"
  bh_ck "T1: that FAIL line is the test's own, with its exit code" "1" \
    "$(bh_count "$BH_OUT" "^FAIL: .*/$T_PRE \\(exit 1\\)\$")"
  bh_ck "T1: the contract is one failure of one executed test, no HITS" \
    "RUN_CONTRACT: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0" "$(bh_last "$BH_OUT")"
  bh_lacks "T1: no HIT line" "$BH_OUT" '^HIT:'
  bh_ck "T1: run-all exits 1" "1" "$BH_RC"

  # The hook reads the run as the user's checkout would print it (repo-relative path).
  hook_out="$(printf '%s\n' "$BH_OUT" | sed -E "s#[^ ]*/($T_PRE)#\\1#g")"
  bh_hook "$sid" 1 "$hook_out"
  bh_ck "T1: the hook records the failing list" "[\"$T_PRE\"]" "$(read_step_field "$sid" run_tests failing_tests)"
  bh_ck "T1: the hook records hit_count=0" "0" "$(read_step_field "$sid" run_tests hit_count)"
  bh_ck "T1: the hook records run_outcome=fail" '"fail"' "$(read_step_field "$sid" run_tests run_outcome)"

  rtb_cli_run "$(mkdir -p "$TMPROOT/cache-t1" && np "$TMPROOT/cache-t1")" "$repo" "$sid"
  [[ "$RTB_CLI_RC" != 3 ]] && pass "T1: the CLI does not exit 3 (a failing list exists)" \
    || fail "T1: the CLI exited 3 — out: $RTB_CLI_OUT"
  bh_has "T1: the CLI classifies the test preexisting" "$RTB_CLI_OUT" \
    "^BASELINE: preexisting $T_PRE fails-at-base-exit-1\$"
  bh_ck "T1: every failure pre-existed, so the CLI exits 0" "0" "$RTB_CLI_RC"
}

BH_HITS_SID="bh-t5-$$"
run_unattributed_hit_exit() {
  local repo="$TMPROOT/repo-hits" sid="$BH_HITS_SID"
  mk_fixture_repo "$repo" >/dev/null
  bh_hook "$sid" 1 "$(bh_hits_stdout)"
  bh_ck "T5: the hook records run_outcome=fail" '"fail"' "$(read_step_field "$sid" run_tests run_outcome)"
  bh_ck "T5: the hook records hit_count=1" "1" "$(read_step_field "$sid" run_tests hit_count)"
  bh_has "T5: the hook records the hit in hit_summary" "$(read_step_field "$sid" run_tests hit_summary)" \
    'worktree-change tests/bin/test-broken.sh'
  bh_ck "T5: the hit is not a failing test" "(absent)" "$(read_step_field "$sid" run_tests failing_tests)"

  rtb_cli_run "$(mkdir -p "$TMPROOT/cache-t5" && np "$TMPROOT/cache-t5")" "$repo" "$sid"
  bh_ck "T5: the CLI exits 6 on unattributed hits" "6" "$RTB_CLI_RC"
  bh_has "T5: the CLI prints the hit count" "$RTB_CLI_OUT" '^BASELINE_HITS: count=1$'
  bh_has "T5: the CLI prints the hit line" "$RTB_CLI_OUT" '^HIT: .*worktree-change tests/bin/test-broken\.sh'
  bh_lacks "T5: nothing is classified" "$RTB_CLI_OUT" '^BASELINE_SUMMARY:'
  bh_ck "T5: run_tests stays pending" '"pending"' "$(read_step_field "$sid" run_tests status)"
}

run_hits_refuse_the_sentinel() {
  local repo="$TMPROOT/repo-hits" sid="$BH_HITS_SID" out
  # The listless path (failing-list-unrecorded) is what a FAIL=0 HITS=1 run would otherwise get.
  out="$(ca_mark "$sid" "$repo" "these fail on main too")"
  bh_ck "T7: the sentinel records no grant on a run with hits" "(absent)" \
    "$(read_step_field "$sid" run_tests baseline_accept)"
  bh_has "T7: the sentinel names the unattributed hits" "$out" 'unattributed hit'
  # A grant that got there anyway (written directly) is still refused at accept time.
  bh_ck "T7: fixture — a grant written directly" "ok" "$(ca_grant "$sid" failing-list-unrecorded)"
  rtb_cli_run "$(mkdir -p "$TMPROOT/cache-t7" && np "$TMPROOT/cache-t7")" "$repo" "$sid"
  bh_lacks "T7: the CLI does not accept the grant" "$RTB_CLI_OUT" '^BASELINE_ACCEPTED'
  bh_ck "T7: the CLI still exits 6" "6" "$RTB_CLI_RC"
  bh_ck "T7: run_tests stays pending" '"pending"' "$(read_step_field "$sid" run_tests status)"
  bh_ck "T7: no completion_basis" "(absent)" "$(read_step_field "$sid" run_tests completion_basis)"
}

# End to end through the real run-all: a failing list AND an unattributed hit in one run. The
# hit outranks the list, so the CLI stops at exit 6 and the sentinel refuses the run.
run_real_run_with_list_and_hit() {
  local repo="$TMPROOT/repo-real-hit" sid="bh-t10-$$" t_noid="tests/bin/test-noid-hit.sh" hook_out out
  bh_repo "$repo"
  printf '#!/usr/bin/env bash\nenv -u ROOT_DECOY_TEST_ID gh --version >/dev/null 2>&1 || true\nexit 0\n' \
    >"$repo/$t_noid"
  git -C "$repo" add "$t_noid"
  git -C "$repo" commit -q -m "a passing test whose hit carries no test id"
  bh_run_all "$repo/$T_PRE" "$repo/$t_noid"
  bh_ck "T10: the failing test is its own one FAIL line" "1" "$(bh_count "$BH_OUT" '^FAIL: ')"
  bh_has "T10: the run prints the hit with no test id" "$BH_OUT" '^HIT: command-guard \(no test id\)'
  bh_ck "T10: the contract carries the failure and HITS=1" \
    "RUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0 HITS=1" "$(bh_last "$BH_OUT")"
  bh_ck "T10: run-all exits 1" "1" "$BH_RC"

  hook_out="$(printf '%s\n' "$BH_OUT" | sed -E "s#[^ ]*/(tests/bin/test-[a-z-]+\\.sh)#\\1#g")"
  bh_hook "$sid" 1 "$hook_out"
  bh_ck "T10: the hook records the failing list" "[\"$T_PRE\"]" "$(read_step_field "$sid" run_tests failing_tests)"
  bh_ck "T10: the hook records hit_count=1" "1" "$(read_step_field "$sid" run_tests hit_count)"
  bh_has "T10: the hook records the hit in hit_summary" "$(read_step_field "$sid" run_tests hit_summary)" \
    'command-guard \(no test id\)'

  rtb_cli_run "$(mkdir -p "$TMPROOT/cache-t10" && np "$TMPROOT/cache-t10")" "$repo" "$sid"
  bh_ck "T10: the CLI exits 6 although a failing list exists" "6" "$RTB_CLI_RC"
  bh_has "T10: the CLI prints the hit count" "$RTB_CLI_OUT" '^BASELINE_HITS: count=1$'
  bh_has "T10: the CLI prints the hit line" "$RTB_CLI_OUT" '^HIT: .*command-guard \(no test id\)'
  bh_lacks "T10: nothing is classified" "$RTB_CLI_OUT" '^BASELINE(_SUMMARY)?: '
  bh_ck "T10: run_tests stays pending" '"pending"' "$(read_step_field "$sid" run_tests status)"

  out="$(ca_mark "$sid" "$repo" "these fail on main too")"
  bh_has "T10: the sentinel names the unattributed hits" "$out" 'unattributed hit'
  bh_ck "T10: the sentinel records no grant" "(absent)" "$(read_step_field "$sid" run_tests baseline_accept)"
}

case_begin "real-run-with-a-failing-list-and-a-hit-exits-6" "bin/run-tests-baseline"
run_real_run_with_list_and_hit
case_end

case_begin "failing-test-with-a-guard-hit-is-classifiable" "bin/run-tests-baseline"
run_failing_test_with_a_hit
case_end

case_begin "unattributed-hits-exit-6-with-hit-lines" "bin/run-tests-baseline"
run_unattributed_hit_exit
case_end

case_begin "hits-refuse-the-baseline-accept-sentinel" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
run_hits_refuse_the_sentinel
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
