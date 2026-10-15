#!/usr/bin/env bash
# Tests: experimental/test-jail/run-jailed.sh, experimental/test-jail/trace-stub.js
# Tags: scope:issue-specific, tl2, test-jail, fixture-isolation
#
# #2591: run-jailed.sh unsets the retired root-name variables (the list is read at run time from
# tests/lib/root-decoy-build.js, never copied here) and fails closed with rc 96 when it cannot
# read the list; trace-stub.js records the four root names and the retired names by exact match.

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
jt_make_tree "$T_NONE" none-fn && jt_make_tree "$T_STATE" state-fn || { echo "FAIL: fixture tree"; exit 1; }

# The retired names, read from their one owner.
RETIRED=()
while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ -n "$line" ]] && RETIRED+=("$line")
done < <(node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js")" --print-retired-env-names 2>/dev/null)

# jt_retired_env — JT_ENVV: every retired name set to a value, plus JT_NAMES listing them.
jt_retired_env() {
  local n
  JT_ENVV=()
  for n in "${RETIRED[@]}"; do JT_ENVV+=("$n=jt-value"); done
  JT_ENVV+=("JT_NAMES=${RETIRED[*]}")
}

case_begin "retired-name-list-is-read-not-copied" "experimental/test-jail/run-jailed.sh"
if [[ "${#RETIRED[@]}" -gt 0 ]]; then
  pass "the builder lists ${#RETIRED[@]} retired names"
else
  fail "the builder lists retired names" "empty list: --print-retired-env-names printed nothing"
fi
for n in "${RETIRED[@]}"; do
  [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "retired name is a valid variable name" "$n"
done
case_end

case_begin "retired-names-unset-for-none-and-state-pins" "experimental/test-jail/run-jailed.sh"
jt_retired_env
jt_exec "$T_NONE/tests/env-probe.sh"
for n in "${RETIRED[@]}"; do expect_has "premise: $n is set without the jail" "$JT_OUT" "$n=set"; done
jt_retired_env
jt_jail --tree "$T_NONE" --pin none tests/env-probe.sh
expect_eq "pin none: probe rc" "$JT_RC" "0"
for n in "${RETIRED[@]}"; do expect_has "pin none: $n is unset" "$JT_OUT" "$n=unset"; done
jt_retired_env
jt_jail --tree "$T_STATE" --pin state tests/env-probe.sh
expect_eq "pin state: probe rc" "$JT_RC" "0"
for n in "${RETIRED[@]}"; do expect_has "pin state: $n is unset" "$JT_OUT" "$n=unset"; done
case_end

case_begin "probe-reports-the-count-not-the-names" "experimental/test-jail/run-jailed.sh"
jt_jail --probe
expect_eq "probe rc" "$JT_RC" "0"
expect_eq "probe: retired-env-unset count" "$(printf '%s\n' "$JT_OUT" | sed -n 's/^retired-env-unset: //p')" "${#RETIRED[@]}"
for n in "${RETIRED[@]}"; do expect_lacks "probe does not print $n" "$JT_ALL" "$n"; done
case_end

case_begin "unreadable-name-list-fails-closed" "experimental/test-jail/run-jailed.sh"
COPY="$TMP_ROOT/copy"
mkdir -p "$COPY/experimental" && cp -r "$JT_DIR" "$COPY/experimental/test-jail"
jt_exec "$COPY/experimental/test-jail/run-jailed.sh" --probe
expect_eq "no builder next to the scripts: rc" "$JT_RC" "96"
expect_has "no builder: SAFE-RUN message" "$JT_ERR" "SAFE-RUN: cannot read the retired env names"
case_end

case_begin "trace-stub-filters-by-exact-name" "experimental/test-jail/trace-stub.js"
# The four root names are given to the child only so the stub can be seen to keep them.
ROOT4=(AGENTS_MAIN_ROOT SCRIPT_CHECKOUT_ROOT TARGET_MAIN_ROOT TARGET_CHECKOUT_ROOT)
STUB="$(np "$JT_DIR/trace-stub.js")"
TRACE="$TMP_ROOT/trace.txt"
# trace_run <names-value> — one stub run, called directly (never inside $(...), which would lose
# the exit code): JT_RC holds the stub's exit code, ENVLINE the env line it recorded.
trace_run() {
  local n unsets=(-u TRACE_STUB_NAMES) sets=("TRACE_STUB_OUT=$(np "$TRACE")" "TRACE_STUB_NAMES=$1" MY_ROOT_X=1 SOME_CONFIG=1 X_AGENTS_Y=1)
  for n in "${ROOT4[@]}"; do sets+=("$n=jt-root"); done
  for n in "${RETIRED[@]}"; do
    if [[ -n "$1" ]]; then sets+=("$n=jt-value"); else unsets+=(-u "$n"); fi
  done
  : >"$TRACE"
  JT_RC=0
  env "${unsets[@]}" "${sets[@]}" node "$STUB" >/dev/null 2>&1 || JT_RC=$?
  ENVLINE="$(sed -n 's/^env=//p' "$TRACE")"
}
trace_run "${RETIRED[*]}"
expect_eq "stub exits 97 like a decoy stub" "$JT_RC" "97"
for n in "${ROOT4[@]}" "${RETIRED[@]}"; do expect_has "recorded: $n" "$ENVLINE" "\"$n\":"; done
for n in MY_ROOT_X SOME_CONFIG X_AGENTS_Y; do expect_lacks "not recorded (partial match only): $n" "$ENVLINE" "\"$n\":"; done
if [[ -n "${ROOT_DECOY_DIR:-}" ]]; then expect_lacks "not recorded: an unrelated ROOT variable" "$ENVLINE" "\"ROOT_DECOY_DIR\":"; fi
trace_run ""
expect_eq "empty TRACE_STUB_NAMES: stub exit code" "$JT_RC" "97"
for n in "${ROOT4[@]}"; do expect_has "empty names: still recorded $n" "$ENVLINE" "\"$n\":"; done
for n in "${RETIRED[@]}"; do expect_lacks "empty names: $n not recorded" "$ENVLINE" "\"$n\":"; done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
