#!/usr/bin/env bash
# Tests: hooks/post-compact.js
# Tags: post-compact, hook, e2e, run-e2e, scope:issue-specific
#
# Issue #943 — per-hook seam L3 test: post-compact.js (PostCompact). L3 GAP ONLY.
# L3 gap: PostCompact fires only on real conversation compaction, which cannot be
# triggered inside a short `claude -p` session, and the hook produces no
# deterministic side-effect file to assert against. No real E2E is implemented;
# this file documents the residual gap and always skips (exit 77).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

# shellcheck source=tests/feature-943-e2e-post-compact/e2e-main.sh
. "$AGENTS_DIR/tests/feature-943-e2e-post-compact/e2e-main.sh"

# L3 gap only — no assertable real invocation. Exit skipped.
exit 77
