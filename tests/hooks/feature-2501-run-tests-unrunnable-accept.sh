#!/usr/bin/env bash
# tests/hooks/feature-2501-run-tests-unrunnable-accept.sh
# Tests: hooks/workflow-mark/run-tests-accept-handler.js, hooks/lib/sentinel-patterns.js, hooks/workflow-mark.js
# Tags: TL1, TL2, hooks, workflow-mark, run-tests, sentinel, unrunnable, escape-hatch, security, scope:issue-specific
# The UNRUNNABLE escape hatch (#2501 D5-7): <<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: {reason}>>
# completes a run_tests that is pending only because tests could not run, and nothing else.
# Real PostToolUse payloads drive the real workflow-run-tests.js and workflow-mark.js hooks.
# Cases live in tests/hooks/feature-2501-run-tests-unrunnable-accept/*.sh.
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
mkdir -p "$T/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"

UA_CASES="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2501-run-tests-unrunnable-accept"
# shellcheck source=feature-2501-run-tests-unrunnable-accept/_lib.sh
. "$UA_CASES/_lib.sh"

case_begin "handler-module-present" "hooks/workflow-mark/run-tests-accept-handler.js"
if [ -f "$HANDLER_JS" ]; then
  pass "present: hooks/workflow-mark/run-tests-accept-handler.js"
else
  fail "present: hooks/workflow-mark/run-tests-accept-handler.js" "missing — the accept cases fail too"
fi
case_end

# shellcheck source=feature-2501-run-tests-unrunnable-accept/regex.sh
. "$UA_CASES/regex.sh"
# shellcheck source=feature-2501-run-tests-unrunnable-accept/accept.sh
. "$UA_CASES/accept.sh"
# shellcheck source=feature-2501-run-tests-unrunnable-accept/reject.sh
. "$UA_CASES/reject.sh"
# shellcheck source=feature-2501-run-tests-unrunnable-accept/missing-file.sh
. "$UA_CASES/missing-file.sh"

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
