#!/bin/bash
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, base-state, scope, verdict-family, scope:issue-specific, pwsh-not-required, TL2
# Issue #1638 (#2723 split) — the X-series: truncation and base-state scope lines under the distinct Scope label.
# Fixtures + helpers: feature-review-code-codex/_lib.sh.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/_lib.sh"

. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/truncation-scope.sh"

rcc_finish
