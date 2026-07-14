#!/usr/bin/env bash
# tests/feature-1351-skip-conditions-from-complexity/_lib.sh
# Shared variables and utilities for the feature-1351 test suite.
# Sourced by the dispatcher and behavioral suite; guarded against double-sourcing.

if [ -n "${_SC_COMPLEXITY_LIB_SOURCED:-}" ]; then
    return 0
fi
_SC_COMPLEXITY_LIB_SOURCED=1

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js"
RESOLVER_N="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"
STATEIO="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"

CI_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
MOP_SKILL="$AGENTS_DIR/skills/make-outline-plan/SKILL.md"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP (pre-impl): $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$desc"
    else
        fail "$desc -- want [$want], got [$got]"
    fi
}

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# --- API presence probe (behavioral cases skip when absent) ------------------
API_READY="$(node -e "
  try {
    const r = require('$RESOLVER_N');
    console.log(typeof r.resolveSkipConditionsFromComplexity === 'function' ? 'true' : 'false');
  } catch (e) { console.log('false'); }
" 2>/dev/null || echo "false")"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"

# record a complexity evaluation via the state-io write API.
node_record() {
    local sid="$1" verdict="$2" signals_json="$3"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    io.recordComplexityEvaluation('$sid', '$verdict', $signals_json);
  " 2>&1
}

# call resolveSkipConditionsFromComplexity; print canonical-key-sorted JSON or 'null'.
node_resolve() {
    local sid="$1" step="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.resolveSkipConditionsFromComplexity('$sid', '$step');
    if (v === null || v === undefined) { console.log('null'); }
    else {
      const sorted = {};
      for (const k of Object.keys(v).sort()) sorted[k] = v[k];
      console.log(JSON.stringify(sorted));
    }
  " 2>/dev/null
}

# Hand-craft a high-level record whose signals array is empty (SC-8 boundary).
record_high_empty_signals() {
    local sid="$1"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$sid');
    s.complexity_evaluation = { level: 'high', signals: [], recorded_at: new Date().toISOString() };
    io.writeState('$sid', s);
  " 2>/dev/null
}

write_raw_state() {
    local sid="$1" raw="$2"
    printf '%s' "$raw" > "$WORKFLOW_DIR/${sid}.json"
}

# Write an arbitrary complexity_evaluation JSON blob into a valid state file.
write_ce_state() {
    local sid="$1" ce_json="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$sid');
    s.complexity_evaluation = $ce_json;
    io.writeState('$sid', s);
  " 2>/dev/null
}
