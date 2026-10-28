#!/bin/bash
# Tests: bin/github-issues/wip-state.sh
# Tags: issue-create, github, workflow, issues, plans, scope:issue-specific
# The session-id resolver, #1082 and #1899 origin-repo cases of bin/github-issues/wip-state.sh; split out of feature-wip-state.sh (#2723).
# RED: fails clean while bin/github-issues/wip-state.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-wip-state/_lib.sh"

# shellcheck source=/dev/null
. "$SUB_DIR/resolver.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/t-1082.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/origin-repo-1899.sh"

wip_finish
