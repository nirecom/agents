#!/usr/bin/env bash
# tests/feature-2338-review-plan-codex.sh
# Tests: bin/review-plan-codex
# Tags: scope:issue-specific, TL2, dup-group-keep:distinct-layer
# Class-members wiring tests are now in feature-review-plan-codex/class-members-wiring.sh
# and run by feature-review-plan-codex.sh. This file delegates to that runner.
AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$AGENTS_ROOT/tests/feature-review-plan-codex.sh"
