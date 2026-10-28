#!/bin/bash
# tests/bin/feature-workflow-init-driver-issue-comments-reopen-cache.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-issue-comments/reopen-cache.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-issue-comments/reopen-cache.sh" "bin/workflow/workflow-init-driver"
driver_entry_run driver-issue-comments/reopen-cache.sh
case_end
[ "$FAIL" -eq 0 ]
