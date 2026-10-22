#!/bin/bash
# Tests: bin/review-code-codex, bin/resolve-merge-base.sh, skills/review-code-security/scripts/run-quality-gates.sh
# Tags: codex, review, truncation, priority, path-ordering, budget, merge-base, scope:issue-specific, pwsh-not-required, TL2
# Issues #1976 / #1750 (#2723 split) — the P-series: which lines survive a truncated diff.
# Fixtures + helpers: feature-review-code-codex/_lib.sh; BIG_REPO and Y_AT_REPO / Y_OVER_REPO are rebuilt here.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/_lib.sh"

. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/big-repo-fixture.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/y-fixtures.sh"
case_begin "path-priority" "bin/review-code-codex"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority.sh"
case_end

rcc_finish
