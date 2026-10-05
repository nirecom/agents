#!/usr/bin/env bash
# Tests: hooks/jev-shadow-pre.js, hooks/jev-shadow-post.js, hooks/lib/jev/test-overrides.js, hooks/lib/jev/provider-core.js, bin/workflow/lib/jev-complexity-adapter.js, hooks/lib/jev/pending.js, hooks/lib/jev/breaker.js, hooks/lib/jev/decision-record.js, hooks/lib/jev/retention.js, settings.json
# Tags: TL2, hooks, jev, shadow-mode, complexity-judge, mock-server, dispatcher, scope:issue-specific, pwsh-not-required
# Dispatcher for the #2460 Jev shadow-mode suite; fragments live under
# tests/hooks/feature-2460-jev-shadow/ (rules/coding/file-split.md Pattern A). Each
# fragment is self-contained (own fixtures, own mock Jev on 127.0.0.1:0), so one
# fragment's red never masks another's; exit 77 from a fragment counts as a skip.

# TL3 gap (what this test does NOT catch): every fragment feeds synthetic hook payloads;
# only tests/hooks/TL3-hook-agent-jev-shadow.sh (RUN_TL3=on) observes the real host's
# Agent payload shape, the settings.json registration firing, and that no [JEV] text
# reaches the main transcript (shadow mode injects nothing).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
SUITE_DIR="$AGENTS_DIR/tests/hooks/feature-2460-jev-shadow"
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

echo "=== feature-2460 Jev shadow mode ==="
case_begin "jev-a-fastexit" "hooks/jev-shadow-pre.js"
run_suite a-fastexit.sh
case_end
case_begin "jev-b-config-boundary" "hooks/lib/jev/test-overrides.js"
run_suite b-config-boundary.sh
case_end
case_begin "jev-c-provider" "hooks/lib/jev/provider-core.js"
run_suite c-provider.sh
case_end
case_begin "jev-d-adapter" "bin/workflow/lib/jev-complexity-adapter.js"
run_suite d-adapter.sh
case_end
case_begin "jev-e-pairing" "hooks/lib/jev/pending.js"
run_suite e-pairing.sh
case_end
case_begin "jev-f-breaker" "hooks/lib/jev/breaker.js"
run_suite f-breaker.sh
case_end
case_begin "jev-g-log" "hooks/lib/jev/decision-record.js"
run_suite g-log.sh
case_end
case_begin "jev-h-block" "hooks/jev-shadow-post.js"
run_suite h-block.sh
case_end
case_begin "jev-i-retention" "hooks/lib/jev/retention.js"
run_suite i-retention.sh
case_end
case_begin "jev-j-registration" "settings.json"
run_suite j-registration.sh
case_end
case_begin "jev-k-fallbacks" "hooks/lib/jev/pending.js"
run_suite k-fallbacks.sh
case_end
case_begin "jev-l-no-inject" "hooks/jev-shadow-post.js"
run_suite l-no-inject.sh
case_end

echo ""
echo "Results (fragments): $PASS passed, $FAIL failed, $SKIP skipped"
exit "$RC_ALL"
