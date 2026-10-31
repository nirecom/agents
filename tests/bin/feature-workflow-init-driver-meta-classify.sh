#!/bin/bash
# tests/bin/feature-workflow-init-driver-meta-classify.sh
# Tests: bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/lib/workflow-init/phases/route-decision.js, bin/workflow/workflow-init-driver
# Tags: workflow-init, driver, meta-classify, pagination, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-meta-classify.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-meta-classify.sh" "bin/workflow/lib/workflow-init/phases/meta-classify.js"
driver_entry_run driver-meta-classify.sh
case_end
[ "$FAIL" -eq 0 ]
