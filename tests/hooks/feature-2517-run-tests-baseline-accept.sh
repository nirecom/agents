#!/usr/bin/env bash
# tests/hooks/feature-2517-run-tests-baseline-accept.sh
# Tests: hooks/workflow-mark/run-tests-baseline-accept-handler.js, hooks/lib/sentinel-patterns.js, hooks/workflow-mark.js
# Tags: TL1, TL2, hooks, workflow-mark, run-tests, baseline, sentinel, escape-hatch, security, scope:issue-specific
# The baseline accept grant (#2517): <<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: {reason}>> records a
# user grant on a failing run_tests that the baseline could not prove pre-existing; it never
# completes the step itself. Real PostToolUse payloads drive the real workflow-mark.js hook.
# Cases live in tests/hooks/feature-2517-run-tests-baseline-accept/*.sh.
# TL3 gap: the settings.json ask prompt for the sentinel is checked by
# tests/install/feature-2280-settings-deny-anchor.sh, not by a live session.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

T="$(make_tmp)"
readonly T
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$T/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"

BA_CASES="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2517-run-tests-baseline-accept"
# shellcheck source=feature-2517-run-tests-baseline-accept/_lib.sh
. "$BA_CASES/_lib.sh"

case_begin "handler-module-present" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
if [ -f "$HANDLER_JS" ]; then
  pass "present: hooks/workflow-mark/run-tests-baseline-accept-handler.js"
else
  fail "present: hooks/workflow-mark/run-tests-baseline-accept-handler.js" "missing — the grant cases fail too"
fi
case_end

# shellcheck source=feature-2517-run-tests-baseline-accept/regex.sh
. "$BA_CASES/regex.sh"
# shellcheck source=feature-2517-run-tests-baseline-accept/grant.sh
. "$BA_CASES/grant.sh"
# shellcheck source=feature-2517-run-tests-baseline-accept/reject.sh
. "$BA_CASES/reject.sh"
# shellcheck source=feature-2517-run-tests-baseline-accept/strict.sh
. "$BA_CASES/strict.sh"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
