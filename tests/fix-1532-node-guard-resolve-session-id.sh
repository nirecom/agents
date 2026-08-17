#!/usr/bin/env bash
# tests/fix-1532-node-guard-resolve-session-id.sh
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, node-misinvocation, invariance, scope:issue-specific, pwsh-not-required, TL2
#
# One entry point per guarded command: bin/select-tests.sh Tier 1 selects tests by
# filename stem, so this filename is what makes an edit to bin/resolve-session-id
# select a suite that actually checks it. All logic lives in fix-1532-node-guard/.
# TL3 gap: asynchronous-stderr platforms and the installed ~/.local/bin shims are
# out of reach from this host. Full list and its mitigation (SSOT):
# tests/fix-1532-node-guard/common.sh, "TL3 gap".
GUARD_TARGET=resolve-session-id
. "$(cd "$(dirname "$0")" && pwd)/fix-1532-node-guard/dispatch.sh"
