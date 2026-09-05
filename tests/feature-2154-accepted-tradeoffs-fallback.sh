#!/usr/bin/env bash
# tests/feature-2154-accepted-tradeoffs-fallback.sh — TL2 dispatcher, issue #2154 causes 1+2.
# Tests: bin/resolve-accepted-tradeoffs-file, skills/review-tests/scripts/run-codex-review-loop.sh, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh, bin/review-plan-codex
# Tags: codex, review, accepted-tradeoffs, fallback, settled-decisions, scope:issue-specific
# Split per rules/coding/file-split.md (Pattern A): this file holds fixture setup
# and shared helpers only; the cases live in the sibling folder of the same name.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - The real codex CLI is mocked in BOTH layers, so "the deferred/delegated
#   decision lands as settled and is not re-raised as a HIGH concern" is never
#   observed — only that the bytes reach codex's stdin.
# - Whether the limiting sentence measurably reduces review round-trips.
# Closest-to-action mitigation: operational observation after merge — intent.md
# `## Constraints` defers effectiveness verification to measuring re-raise
# frequency in later review-tests / review-plan-security runs.

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$AGENTS_ROOT/bin/resolve-accepted-tradeoffs-file"
REVIEW_PLAN_CODEX="$AGENTS_ROOT/bin/review-plan-codex"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then pass "$name"
  else echo "FAIL: $name — want=[$want] got=[$got]"; FAIL=$((FAIL + 1)); fi
}

# Fixture isolation: rules/test/fixture-isolation.md.
TMPROOT="$(mktemp -d)"
trap 'cd /; chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
norm() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
TMPROOT="$(norm "$TMPROOT")"
export CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPROOT/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
cd "$TMPROOT" || exit 1

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 90 "$@"; else perl -e 'alarm 90; exec @ARGV' -- "$@"; fi
}

# resolve <plans-dir> <sid> [suffixes...] → RES_OUT / RES_RC
resolve() {
  RES_OUT="$(with_timeout bash "$RESOLVER" "$@" 2>/dev/null)"
  RES_RC=$?
}

# make_plans <name> <suffix>... → prints the plans dir, one non-empty file per suffix
make_plans() {
  local name="$1"; shift
  local d="$TMPROOT/plans-$name"
  mkdir -p "$d"
  local s
  for s in "$@"; do printf '# %s\n\n## Accepted Tradeoffs\n\nkeep it\n' "$s" > "$d/SID-$s.md"; done
  printf '%s' "$d"
}

CASE_DIR="$TESTS_DIR/feature-2154-accepted-tradeoffs-fallback"

# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/layer-a-resolution.sh
. "$CASE_DIR/layer-a-resolution.sh"
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/layer-b-prompt.sh
. "$CASE_DIR/layer-b-prompt.sh"
# Layer B first: the forgery cases consume its run_rpc / prompt_* helpers.
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/prompt-delimiter-forgery.sh
. "$CASE_DIR/prompt-delimiter-forgery.sh"
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/prompt-guard-placement.sh
. "$CASE_DIR/prompt-guard-placement.sh"
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/wrapper-resolver-failure.sh
. "$CASE_DIR/wrapper-resolver-failure.sh"
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/resolver-edge-security.sh
. "$CASE_DIR/resolver-edge-security.sh"
# Containment first: it owns the S0 executability guard and the shared helpers
# (resolve_e, assert_contained, canon_verdict) the three files below consume.
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/resolver-untrusted-input-injection.sh
. "$CASE_DIR/resolver-untrusted-input-injection.sh"
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/resolver-substrate-modes.sh
. "$CASE_DIR/resolver-substrate-modes.sh"
# shellcheck source=./feature-2154-accepted-tradeoffs-fallback/resolver-arg-boundary.sh
. "$CASE_DIR/resolver-arg-boundary.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[[ "$FAIL" -eq 0 ]]
