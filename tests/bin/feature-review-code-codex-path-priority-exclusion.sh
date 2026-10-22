#!/bin/bash
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, priority, path-ordering, budget, exclusion, scope:issue-specific, pwsh-not-required, TL2
# Issues #1976 / #1750 (#2723 split) — the P-series: exclusion and cross-reference rows, then budget and breakdown rows.
# Fixtures + helpers: feature-review-code-codex/_lib.sh and path-priority/helpers.sh.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/_lib.sh"

. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/helpers.sh"
pp_install_capturing_mock
PP_ENV=()
# PP_BIG: the same 6000-line BIG_REPO the whole-file run inherits from the truncation part.
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/big-repo-fixture.sh"
PP_BIG="$BIG_REPO"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/exclusion-and-cross-reference.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/budget-and-breakdown.sh"

rcc_finish
