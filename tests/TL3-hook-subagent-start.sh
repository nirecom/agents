#!/usr/bin/env bash
# Tests: hooks/subagent-start.js
# Tags: subagent-start, hook, TL3, run-e2e, scope:permanent
#
# Issue #943 — per-hook seam TL3 test: subagent-start.js (SubagentStart). TL3 GAP ONLY.
# TL3 gap: the hook injects additionalContext into a spawned sub-agent but leaves
# no observable side-effect file; the only signal is the sub-agent's output
# language, which is non-deterministic. No real TL3 test is implemented; this file
# documents the residual gap and always skips (exit 77).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

# shellcheck source=tests/TL3-hook-subagent-start/main.sh
. "$AGENTS_DIR/tests/TL3-hook-subagent-start/main.sh"

# TL3 gap only — no assertable real invocation. Exit skipped.
exit 77
