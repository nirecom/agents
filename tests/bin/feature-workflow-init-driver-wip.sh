#!/bin/bash
# tests/bin/feature-workflow-init-driver-wip.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/wip-check.js
# Tags: workflow-init, driver, wip-check, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-wip.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-wip.sh" "bin/workflow/workflow-init-driver"
driver_entry_run driver-wip.sh
case_end
[ "$FAIL" -eq 0 ]
