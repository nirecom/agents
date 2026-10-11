# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/common.sh
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, run-tests, worker-dispatch, shared-lib, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh after it pins the state and plans
# dirs. Every state read and fixture write goes through probe.js.

F2544_ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
F2544_AGENTS="$F2544_ROOT_N"
export F2544_AGENTS
F2544_PROBE="$F2544_ROOT_N/tests/hooks/feature-2544-dispatch-outcome/probe.js"
F2544_HOOK="$F2544_ROOT_N/hooks/workflow-run-tests.js"
F2544_MARK="$F2544_ROOT_N/hooks/workflow-mark.js"

F2544_M_CONTRACT="hooks/lib/worker-outcome-contract.js"
F2544_M_SETTLEMENT="hooks/workflow-state/dispatch-settlement.js"
F2544_M_REGISTRY="hooks/lib/plans-artifact-registry.js"

# State annotation names: one place, so a rename in the implementation is a one-line follow-up.
F2544_KEY_SOURCE="outcome_source"
F2544_KEY_UNSETTLED="dispatch_unsettled"

F2544_T="worker-test-runner"
F2544_FAILING_REL="tests/hooks/feature-2544-dispatch-outcome.sh"
F2544_UNRELATED_CMD="git status"

f2544_probe() { node "$F2544_PROBE" "$@" 2>/dev/null; }

f2544_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$name"
  else fail "$name" "want=[$expected] got=[$actual]"; fi
}

f2544_ne() {
  local name="$1" actual="$2" unwanted="$3"
  if [[ "$actual" != "$unwanted" ]]; then pass "$name"
  else fail "$name" "got the unwanted value [$unwanted]"; fi
}

f2544_status() { f2544_probe field "$1" run_tests status; }
f2544_field() { f2544_probe field "$1" run_tests "$2"; }
f2544_events() { f2544_probe events "$1"; }
f2544_seq() { f2544_probe field "$1" run_tests updated_seq; }
# f2544_source_stem <sid> — the stem named by run_tests.outcome_source, or "absent".
f2544_source_stem() { f2544_probe path "$1" run_tests "$F2544_KEY_SOURCE" stem; }
f2544_ready() { f2544_probe prefix "$1"; }

# f2544_hook <sid> <command> [exit] [stdout] [cwd] -> F2544_HOOK_OUT / F2544_HOOK_RC
F2544_HOOK_OUT=""
F2544_HOOK_RC=0
f2544_hook() {
  local input
  input="$(f2544_probe hook-input "$1" "$2" "${3:-0}" "${4:-}" "${5:-}")"
  F2544_HOOK_RC=0
  F2544_HOOK_OUT="$(printf '%s' "$input" | run_with_timeout 60 node "$F2544_HOOK" 2>/dev/null)" || F2544_HOOK_RC=$?
}

f2544_hook_times() {
  local n="$1" i
  shift
  for ((i = 0; i < n; i++)); do f2544_hook "$@"; done
}

# f2544_mark <sid> <command> [dir] — sentinel route through hooks/workflow-mark.js.
f2544_mark() {
  local input dir="${3:-$F2544_TMP_ROOT}"
  input="$(f2544_probe mark-input "$1" "$2")"
  (cd "$dir" && printf '%s' "$input" | run_with_timeout 60 node "$F2544_MARK" >/dev/null 2>&1) || true
}

# f2544_dispatched <sid> <stem> — published payload plus its dispatch marker.
f2544_dispatched() {
  f2544_probe payload "$1" "$2" "$F2544_ROOT_N"
  f2544_probe touch "$1" "$2.dispatched"
}

# f2544_pass_outcome <sid> <stem> / f2544_fail_outcome <sid> <stem>
f2544_pass_outcome() { f2544_probe outcome "$1" "$2" pass 3 0 '[]'; }
f2544_fail_outcome() { f2544_probe outcome "$1" "$2" fail 2 1 "[\"$F2544_FAILING_REL\"]"; }

# f2544_worker_yaml <status> — the dispatcher's rendered stdout shape, contract first.
f2544_worker_yaml() {
  printf 'RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9\n'
  printf 'status: %s\nexit_code: 0\nduration_seconds: 4\n' "$1"
  printf "summary: 'worker run'\nfailing_tests: []\nlog_tail: |\n  PASS: alpha\n"
}

# f2544_ingested <name> <sid> <stem> — precondition gate: returns 1 (and fails once)
# when the outcome was not ingested, so later assertions never pass vacuously.
f2544_ingested() {
  if [[ "$(f2544_probe exists "$2" "$3.ingested")" == "yes" ]]; then
    pass "$1"
    return 0
  fi
  fail "$1" "no ingested marker for $3 (run_tests=$(f2544_status "$2"))"
  return 1
}
