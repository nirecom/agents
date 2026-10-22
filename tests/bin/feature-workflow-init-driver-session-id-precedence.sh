#!/bin/bash
# tests/bin/feature-workflow-init-driver-session-id-precedence.sh
# Tests: bin/workflow/workflow-init-driver, bin/resolve-session-id
# Tags: workflow-init, driver, session-id, ssot, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-session-id-precedence.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-session-id-precedence.sh" "bin/workflow/workflow-init-driver"
driver_entry_run driver-session-id-precedence.sh
case_end
[ "$FAIL" -eq 0 ]
