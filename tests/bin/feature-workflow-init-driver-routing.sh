#!/bin/bash
# tests/bin/feature-workflow-init-driver-routing.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/detect-issues.js, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/wip-check.js, bin/workflow/lib/workflow-init/phases/closed-detection.js, bin/workflow/lib/workflow-init/phases/label-extract.js, bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/lib/workflow-init/phases/route-decision.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/spawn-env.js, hooks/lib/parse-remote-url.js
# Tags: workflow-init, driver, routing, directive-contract, meta-classify, origin-resolution, fail-closed, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-routing.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-routing.sh" "bin/workflow/workflow-init-driver"
driver_entry_run driver-routing.sh
case_end
[ "$FAIL" -eq 0 ]
