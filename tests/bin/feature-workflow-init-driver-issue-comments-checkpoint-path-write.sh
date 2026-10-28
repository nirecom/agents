#!/bin/bash
# tests/bin/feature-workflow-init-driver-issue-comments-checkpoint-path-write.sh
# Tests: bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/workflow-init-driver
# Tags: workflow-init, driver, checkpoint, path-separator, win32, fail-closed, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-issue-comments/checkpoint-path-write.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-issue-comments/checkpoint-path-write.sh" "bin/workflow/lib/workflow-init/checkpoint.js"
driver_entry_run driver-issue-comments/checkpoint-path-write.sh
case_end
[ "$FAIL" -eq 0 ]
