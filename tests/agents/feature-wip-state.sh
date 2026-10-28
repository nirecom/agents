#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/workflow-plans-dir, bin/github-issues/lib/board-card.sh, bin/github-issues/lib/origin-repo.sh
# Tags: issue-create, github, workflow, issues, plans, scope:issue-specific
# Tests for bin/github-issues/wip-state.sh — Issue #362 WIP signaling helper. Verbs: set <N> (fingerprint
# before Status=In Progress), check <N> (same|other|none), clear <N> (Done, idempotent), abandon <N>
# (OPEN-only, Status=Todo), setup (ID discovery via gh api graphql, append to .env).
# 30 base cases + 38 abandon cases; inline-gh-mock pattern from feature-issue-create-skill.sh.
# This entrypoint runs set, check, clear and cross-verb; -abandon, -new and -resolver run the rest (#2723 split).
# RED: fails clean while bin/github-issues/wip-state.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-wip-state/_lib.sh"

# shellcheck source=/dev/null
. "$SUB_DIR/set.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/check.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/clear.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/cross-verb.sh"

wip_finish
