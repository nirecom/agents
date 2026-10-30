#!/bin/bash
# Tests: bin/review-code-codex
# Tags: codex, review, truncation, priority, path-ordering, concerns-file, scope:issue-specific, pwsh-not-required, TL2
# Issues #1976 / #1750 (#2723 split) — the P-series: concerns-file parsing rows, then the H (untracked hardening) and UW (untracked withheld reporting) rows.
# Fixtures + helpers: feature-review-code-codex/_lib.sh and path-priority/helpers.sh.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/_lib.sh"

. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/helpers.sh"
pp_install_capturing_mock
PP_ENV=()
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/concerns-file-parsing.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/untracked-hardening.sh"
. "$AGENTS_ROOT/tests/bin/feature-review-code-codex/path-priority/untracked-withheld-reporting.sh"

rcc_finish
