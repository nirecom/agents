#!/usr/bin/env bash
# tests/bin/feature-2501-launch-classify.sh
# Tests: bin/lib/run-all-classify.sh, bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, classify, timeout, unrunnable, case-results, scope:issue-specific, pytest
# The test launcher's common layer (#2501): rac_classify / rac_effective_timeout, and run_all_exec
# with the result directory, UNRUNNABLE, {wrapper}/{minVersion}, the entry/env timeout and the bash
# column of the regression matrix. Cases live in tests/bin/feature-2501-launch-classify/*.sh.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available (the test language registry loader needs it)"
  exit 77
fi

TMPBASE="$(make_tmp)"
FX_PIDS=""
cleanup_fx() {
  local p
  for p in $FX_PIDS; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$TMPBASE"
}
trap cleanup_fx EXIT
harness_isolate "$TMPBASE/iso"
# The launcher's effective timeout takes the min with this env; an ambient value must not leak in.
unset RUN_ALL_TIMEOUT_SECONDS RUN_ALL_RESULT_DIR RUN_ALL_RESULT_OWNER

LC_CASES="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2501-launch-classify"
# shellcheck source=feature-2501-launch-classify/_lib.sh
. "$LC_CASES/_lib.sh"

case_begin "classify-lib-present" "bin/lib/run-all-classify.sh"
if [ -f "$RAC_LIB" ]; then
  pass "present: bin/lib/run-all-classify.sh"
else
  fail "present: bin/lib/run-all-classify.sh" "missing — every classify case fails too"
fi
case_end

# shellcheck source=feature-2501-launch-classify/classify.sh
. "$LC_CASES/classify.sh"
# shellcheck source=feature-2501-launch-classify/exec.sh
. "$LC_CASES/exec.sh"
# shellcheck source=feature-2501-launch-classify/setup-failure.sh
. "$LC_CASES/setup-failure.sh"
# shellcheck source=feature-2501-launch-classify/matrix.sh
. "$LC_CASES/matrix.sh"
# shellcheck source=feature-2501-launch-classify/security.sh
. "$LC_CASES/security.sh"
# shellcheck source=feature-2501-launch-classify/pytest-launch.sh
. "$LC_CASES/pytest-launch.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
