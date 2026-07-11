# Sourced by tests/feature-wip-state.sh — not executed directly (no shebang).
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-abandon.sh
# Tags: wip-state, github, scope:issue-specific
_ABANDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/abandon"
. "$_ABANDON_DIR/mock.sh"
. "$_ABANDON_DIR/core.sh"
. "$_ABANDON_DIR/edge.sh"
. "$_ABANDON_DIR/regression.sh"
