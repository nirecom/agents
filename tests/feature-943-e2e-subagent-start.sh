#!/usr/bin/env bash
# Tests: hooks/subagent-start.js
# Tags: subagent-start, hook, e2e, run-e2e, scope:issue-specific
#
# Issue #943 — per-hook seam L3 test: subagent-start.js (SubagentStart). L3 GAP ONLY.
# L3 gap: the hook injects additionalContext into a spawned sub-agent but leaves
# no observable side-effect file; the only signal is the sub-agent's output
# language, which is non-deterministic. No real E2E is implemented; this file
# documents the residual gap and always skips (exit 77).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

# shellcheck source=tests/feature-943-e2e-subagent-start/e2e-main.sh
. "$AGENTS_DIR/tests/feature-943-e2e-subagent-start/e2e-main.sh"

# L3 gap only — no assertable real invocation. Exit skipped.
exit 77
