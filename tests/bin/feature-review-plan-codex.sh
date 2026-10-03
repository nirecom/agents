#!/bin/bash
# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# Serial: injection guards assert the fixed paths /tmp/plan-injection-marker and /tmp/plan-injection-marker2 stay absent
# Tests for bin/review-plan-codex
# Verifies: SKIPPED/PERFORMED/FAILED status labels, JSONL logging,
# exit-0 guarantee, security (no shell injection from plan content),
# format-specific output, adversarial preamble, and idempotency.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-plan-codex"
ERRORS=0
AGENTS_DIR="$AGENTS_ROOT"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

# Shared harness for the case markers the sub-files use; the local reporters below override it.
AGENTS_DIR="${AGENTS_DIR:-$AGENTS_ROOT}"
# shellcheck source=../lib/harness.sh
. "$AGENTS_ROOT/tests/lib/harness.sh"

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Setup: temp dir with a plan file (no git repo needed)
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
LOG_DIR="$TMPDIR_BASE/.claude/projects/codex-review"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PLAN_FILE="$TMPDIR_BASE/test-plan.md"
cat > "$PLAN_FILE" << 'PLAN_EOF'
# Implementation Plan

## Phase 1: Setup
- Create directory structure
- Initialize configuration files

## Phase 2: Core logic
- Implement main function
- Add error handling

## Phase 3: Tests
- Write unit tests
- Write integration tests
PLAN_EOF

# Mock codex bin dir
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"

# Portable: use system timeout if available
_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 70 "$@"
    else
        perl -e 'alarm 70; exec @ARGV' -- "$@"
    fi
}

# Run script with a given PATH and HOME
run_script() {
    local _path="${1}"; shift
    local _home="$TMPDIR_BASE"
    PATH="$_path" HOME="$_home" _timeout bash "$SCRIPT" --input "$PLAN_FILE" "$@" || true
}

# Per-case test bodies live under ./feature-review-plan-codex/, grouped by
# behavior area (see rules/coding/file-split.md Pattern A). status-labels.sh
# must source first: it defines MINIMAL_PATH, reused by several later files.
SCRIPT_DIR="$(dirname "$0")/feature-review-plan-codex"

# One case per sourced area file; each target is the path that area exercises.
case_begin "status-labels" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/status-labels.sh
. "$SCRIPT_DIR/status-labels.sh"
case_end
case_begin "security" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/security.sh
. "$SCRIPT_DIR/security.sh"
case_end
case_begin "idempotency-logging" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/idempotency-logging.sh
. "$SCRIPT_DIR/idempotency-logging.sh"
case_end
case_begin "arg-validation" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/arg-validation.sh
. "$SCRIPT_DIR/arg-validation.sh"
case_end
case_begin "format-verdicts" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/format-verdicts.sh
. "$SCRIPT_DIR/format-verdicts.sh"
case_end
case_begin "adversarial-preamble" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/adversarial-preamble.sh
. "$SCRIPT_DIR/adversarial-preamble.sh"
case_end
case_begin "context-wiring" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/context-wiring.sh
. "$SCRIPT_DIR/context-wiring.sh"
case_end
case_begin "skill-md-wiring" "skills/_shared/codex-review-loop.md"
# shellcheck source=./feature-review-plan-codex/skill-md-wiring.sh
. "$SCRIPT_DIR/skill-md-wiring.sh"
case_end
case_begin "cli-args-329" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/cli-args-329.sh
. "$SCRIPT_DIR/cli-args-329.sh"
case_end
case_begin "repo-root-mcp" "bin/run-codex-review-loop"
# shellcheck source=./feature-review-plan-codex/repo-root-mcp.sh
. "$SCRIPT_DIR/repo-root-mcp.sh"
case_end
case_begin "class-members-wiring" "bin/review-plan-codex"
# shellcheck source=./feature-review-plan-codex/class-members-wiring.sh
. "$SCRIPT_DIR/class-members-wiring.sh"
case_end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
