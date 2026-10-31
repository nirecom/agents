#!/bin/bash
# tests/bin/feature-workflow-init-driver-directive-contract.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/directive.js, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/write-context.js
# Tags: workflow-init, driver, directive-contract, security, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-directive-contract.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-directive-contract.sh" "bin/workflow/workflow-init-driver"
driver_entry_run driver-directive-contract.sh
case_end
[ "$FAIL" -eq 0 ]
