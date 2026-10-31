#!/bin/bash
# Tests: bin/github-issues/wip-state.sh
# Tags: issue-create, github, workflow, issues, plans, scope:issue-specific
# The abandon verb cases of bin/github-issues/wip-state.sh (38 cases); split out of feature-wip-state.sh (#2723).
# RED: fails clean while bin/github-issues/wip-state.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-wip-state/_lib.sh"

# shellcheck source=/dev/null
. "$SUB_DIR/abandon.sh"

wip_finish
