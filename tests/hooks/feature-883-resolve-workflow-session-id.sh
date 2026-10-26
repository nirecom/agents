#!/bin/bash
# tests/hooks/feature-883-resolve-workflow-session-id.sh
# Tests: hooks/lib/resolve-workflow-session-id.js, hooks/lib/supervisor-state-writer.js
# Tags: supervisor, em-supervisor, session-id, workflow-state, layer2, scope:issue-specific
# RED for issue #883.
# L3 gap: the full Stop hook wiring (covered by G20/G21 in feature-719-supervisor-guard-hook.sh); real-dir mtime quirks (temp dirs only).
# Closest-to-action mitigation: hook-registration / skill-orchestration categories in bin/check-verification-gate.sh.
# Case functions live in feature-883-resolve-workflow-session-id/ (_lib.sh, cases-*.sh); this file pins isolation and dispatches them.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly F883_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$F883_TMP_ROOT"' EXIT
mkdir -p "$F883_TMP_ROOT/state" "$F883_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$F883_TMP_ROOT/state" WORKFLOW_PLANS_DIR="$F883_TMP_ROOT/plans"

# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/hooks/feature-883-resolve-workflow-session-id/_lib.sh
. "$SCRIPT_DIR/feature-883-resolve-workflow-session-id/_lib.sh"
# shellcheck source=tests/hooks/feature-883-resolve-workflow-session-id/cases-r0-r10.sh
. "$SCRIPT_DIR/feature-883-resolve-workflow-session-id/cases-r0-r10.sh"
# shellcheck source=tests/hooks/feature-883-resolve-workflow-session-id/cases-r11-r25.sh
. "$SCRIPT_DIR/feature-883-resolve-workflow-session-id/cases-r11-r25.sh"

case_begin "R0" "hooks/lib/resolve-workflow-session-id.js"
run_r0
case_end
case_begin "R0b" "hooks/lib/resolve-workflow-session-id.js"
run_r0b
case_end
case_begin "R3" "hooks/lib/resolve-workflow-session-id.js"
run_r3
case_end
case_begin "R4" "hooks/lib/resolve-workflow-session-id.js"
run_r4
case_end
case_begin "R5" "hooks/lib/resolve-workflow-session-id.js"
run_r5
case_end
case_begin "R6" "hooks/lib/resolve-workflow-session-id.js"
run_r6
case_end
case_begin "R7" "hooks/lib/resolve-workflow-session-id.js"
run_r7
case_end
case_begin "R8" "hooks/lib/resolve-workflow-session-id.js"
run_r8
case_end
case_begin "R9" "hooks/lib/resolve-workflow-session-id.js"
run_r9
case_end
case_begin "R10" "hooks/lib/resolve-workflow-session-id.js"
run_r10
case_end
case_begin "R11" "hooks/lib/supervisor-state-writer.js"
run_r11
case_end
case_begin "R12" "hooks/lib/resolve-workflow-session-id.js"
run_r12
case_end
case_begin "R13" "hooks/lib/resolve-workflow-session-id.js"
run_r13
case_end
case_begin "R15" "hooks/lib/resolve-workflow-session-id.js"
run_r15
case_end
case_begin "R16" "hooks/lib/resolve-workflow-session-id.js"
run_r16
case_end
case_begin "R17" "hooks/lib/resolve-workflow-session-id.js"
run_r17
case_end
case_begin "R18" "hooks/lib/resolve-workflow-session-id.js"
run_r18
case_end
case_begin "R19" "hooks/lib/resolve-workflow-session-id.js"
run_r19
case_end
case_begin "R20" "hooks/lib/resolve-workflow-session-id.js"
run_r20
case_end
case_begin "R21" "hooks/lib/resolve-workflow-session-id.js"
run_r21
case_end
case_begin "R22" "hooks/lib/resolve-workflow-session-id.js"
run_r22
case_end
case_begin "R23" "hooks/lib/resolve-workflow-session-id.js"
run_r23
case_end
case_begin "R24" "hooks/lib/resolve-workflow-session-id.js"
run_r24
case_end
case_begin "R25" "hooks/lib/resolve-workflow-session-id.js"
run_r25
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
