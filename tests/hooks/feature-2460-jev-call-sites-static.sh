#!/bin/bash
# tests/hooks/feature-2460-jev-call-sites-static.sh
# Tests: skills/_shared/jev-two-stage-judge.md, skills/_shared/complexity-and-outline-skip.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: complexity, prompt-static, consumers, producers, jev, shared-procedure, call-sites, stage-5, scope:issue-specific
# Issue #2460 stage 5 (detail plan L856-891): every judge point in the skills is a
# 1-line reference to skills/_shared/jev-two-stage-judge.md, the shared procedure's
# own JJ steps are pinned, and the retired skip wiring is gone from skills/.
# Moved out of the feature-2099 suite so that suite stays green from stage 1
# (plan L329); every case here stays red until stage 5 rewrites the skills.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
ERRORS=0

# Same <desc> <want> <got> shape as the feature-2099 cases these came from; they
# override harness's two-argument assert_eq.
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — want: [$2], got: [$3]"; fi
}

assert_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1 — expected to contain [$2], got: [$3]" ;;
    esac
}

assert_not_contains() {
    case "$3" in
        *"$2"*) fail "$1 — expected NOT to contain [$2], got: [$3]" ;;
        *) pass "$1" ;;
    esac
}

# Static reads only: no hook, CLI or workflow state is touched, so no fixture
# directory or state pin is needed.
# shellcheck source=./feature-2099-complexity-stage-routing/skill-section-helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2099-complexity-stage-routing/skill-section-helpers.sh"

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2460-jev-call-sites-static"

# One dispatch case: per-scenario markers live in each sourced case file.
case_begin "dispatch-call-site-files" "skills/_shared/jev-two-stage-judge.md"
# shellcheck source=./feature-2460-jev-call-sites-static/consumer-call-sites.sh
. "$CASE_DIR/consumer-call-sites.sh"
# shellcheck source=./feature-2460-jev-call-sites-static/producer-call-sites.sh
. "$CASE_DIR/producer-call-sites.sh"
# shellcheck source=./feature-2460-jev-call-sites-static/shared-procedure-static.sh
. "$CASE_DIR/shared-procedure-static.sh"
case_end

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
