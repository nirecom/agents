#!/usr/bin/env bash
# Tests: hooks/post-compact.js
# Tags: post-compact, hook, TL3, run-e2e, scope:permanent, scope:issue-specific
#
# Issue #943 — per-hook seam TL3 test: post-compact.js (PostCompact). TL3 GAP ONLY.
# TL3 gap: PostCompact fires only on real conversation compaction, which cannot be
# triggered inside a short `claude -p` session, and the hook produces no
# deterministic side-effect file to assert against. No real TL3 test is implemented;
# this file documents the residual gap and always skips (exit 77).
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

# shellcheck source=tests/hooks/TL3-hook-post-compact/main.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-post-compact/main.sh"

# TL3 gap only — no assertable real invocation. Exit skipped.
exit 77
