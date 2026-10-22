#!/bin/bash
# tests/bin/feature-workflow-init-driver-issue-comments-reopen-authz.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/issue-comments.js
# Tags: workflow-init, driver, issue-comments, checkpoint-resume, answer-validation, reopen, prompt-injection, scope:issue-specific
# One split group of the workflow-init-driver suite (#2445): feature-workflow-init-driver/driver-issue-comments/reopen-authz.sh.
# Guard and runner: feature-workflow-init-driver/_entry-guard.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
case_begin "driver-issue-comments/reopen-authz.sh" "bin/workflow/workflow-init-driver"
driver_entry_run driver-issue-comments/reopen-authz.sh
case_end
[ "$FAIL" -eq 0 ]
