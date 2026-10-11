#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js, rules/shell-commands.md, settings.json
# Tags: TL2, hooks, subagent-dispatch, updated-input, dispatcher, scope:issue-specific, pwsh-not-required
# Dispatcher for the #2263 PreToolUse prompt-append hook; fragments live under
# tests/hooks/feature-2263-subagent-dispatch-prompt/ (rules/coding/file-split.md Pattern A).
# Each fragment runs in its own process; exit 77 from a fragment counts as a skip.

# TL3 gap (what this test does NOT catch): every fragment calls decide() or main() with a
# synthetic payload; only tests/hooks/TL3-hook-subagent-dispatch-prompt.sh (RUN_TL3=on)
# observes that the host applies updatedInput, keeps permissions, and coexists with jev.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
SUITE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2263-subagent-dispatch-prompt"
RC_ALL=0

# run_suite <fragment>: run one fragment in its own process and fold its exit code in.
run_suite() {
  local rc=0
  bash "$SUITE_DIR/$1" || rc=$?
  if [ "$rc" -eq 0 ]; then pass "$1"
  elif [ "$rc" -eq 77 ]; then skip "$1 (prerequisite missing)"
  else fail "$1" "exit $rc"; RC_ALL=1
  fi
}

echo "=== feature-2263 subagent dispatch prompt hook ==="
case_begin "sdp-decide" "hooks/subagent-dispatch-prompt.js"
run_suite decide.sh
case_end
case_begin "sdp-canonical-match" "hooks/subagent-dispatch-prompt.js"
run_suite canonical-match.sh
case_end
case_begin "sdp-json-prompt" "hooks/subagent-dispatch-prompt.js"
run_suite json-prompt.sh
case_end
case_begin "sdp-exemption" "hooks/subagent-dispatch-prompt.js"
run_suite exemption.sh
case_end
case_begin "sdp-registration" "settings.json"
run_suite registration.sh
case_end
case_begin "sdp-line-sync" "rules/shell-commands.md"
run_suite line-sync.sh
case_end

echo ""
echo "Results (fragments): $PASS passed, $FAIL failed, $SKIP skipped"
exit "$RC_ALL"
