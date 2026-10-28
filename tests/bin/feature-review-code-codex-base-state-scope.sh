#!/bin/bash
# Tests: bin/review-code-codex
# Tags: codex, review, merge-base, base-state, truncation, boundary, prompt-order, scope:issue-specific, pwsh-not-required, TL2
# Issue #1638 (#2723 split) — the Y-series: remaining base states, the exact truncation boundary, scope-line order.
# Fixtures + helpers: feature-review-code-codex/_lib.sh.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/_lib.sh"

. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/base-state-scope.sh"

rcc_finish
