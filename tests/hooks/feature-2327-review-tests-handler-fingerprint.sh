#!/bin/bash
# Tests: hooks/workflow-mark/review-tests-handler.js, hooks/workflow-state/state-io/review-tests.js
# Tags: scope:issue-specific review-tests fingerprint handler, tl2, workflow, write-code, rereview, reopen, warnings-accepted, pwsh-not-required
#
# Dispatcher: shared setup, then p1 (#2327 fingerprint handler) and p2 (#2482
# WARNINGS_ACCEPTED recovery of a write_code-reopened review_tests).

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

TMPDIR_BASE="$(make_tmp)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true

SCRIPT_DIR="$AGENTS_DIR/tests/hooks/feature-2327-review-tests-handler-fingerprint"

case_begin "fingerprint-handler" "hooks/workflow-mark/review-tests-handler.js"
# shellcheck source=./feature-2327-review-tests-handler-fingerprint/p1-fingerprint.sh
. "$SCRIPT_DIR/p1-fingerprint.sh"
case_end

case_begin "accept-reopened-review-tests" "hooks/workflow-state/state-io/review-tests.js"
# shellcheck source=./feature-2327-review-tests-handler-fingerprint/p2-accept-reopened.sh
. "$SCRIPT_DIR/p2-accept-reopened.sh"
case_end

case_begin "accept-terminal-in-progress-review-tests" "hooks/workflow-state/state-io/review-tests.js"
# shellcheck source=./feature-2327-review-tests-handler-fingerprint/p3-accept-terminal-in-progress.sh
. "$SCRIPT_DIR/p3-accept-terminal-in-progress.sh"
case_end

echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
