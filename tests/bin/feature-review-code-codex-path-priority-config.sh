#!/bin/bash
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, priority, path-ordering, budget, config-threshold, scope:issue-specific, pwsh-not-required, TL2
# Issues #1976 / #1750 (#2723 split) — the P-series: the budget as a configuration value.
# Fixtures + helpers: feature-review-code-codex/_lib.sh and path-priority/helpers.sh.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/_lib.sh"

. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/helpers.sh"
pp_install_capturing_mock
PP_ENV=()
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/config-threshold.sh"

rcc_finish
