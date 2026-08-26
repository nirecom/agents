#!/usr/bin/env bash
# tests/feature-1351-skip-conditions-from-complexity/_lib.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/state-io.js
# Tags: complexity, skip-conditions, resolver, helpers, scope:issue-specific
# Shared variables and utilities for the feature-1351 test suite.
# Sourced by the dispatcher and behavioral suite; guarded against double-sourcing.

if [ -n "${_SC_COMPLEXITY_LIB_SOURCED:-}" ]; then
    return 0
fi
_SC_COMPLEXITY_LIB_SOURCED=1

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/workflow-state/skip-signal-resolver.js"
RESOLVER_N="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"
STATEIO="$AGENTS_DIR/hooks/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"
ROUTING="$AGENTS_DIR/hooks/workflow-state/complexity-routing.js"
ROUTING_N="$(cygpath -m "$ROUTING" 2>/dev/null || echo "$ROUTING")"

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

# --- required-API assertion (NOT a skip gate) --------------------------------
# resolveSkipConditionsFromComplexity is a REQUIRED class member of #2099
# (detail.md "Class members", 4th consumer), and detail.md item 7 requires its
# decision to run through isZeroSignalLow() from complexity-routing.js. An
# absent required member is a FAILURE: the earlier `if [ "$API_READY" = true ]`
# gate turned "the implementation does not exist" into "0 failed, N skipped",
# which is exactly the false-green the fail-before-fix discipline forbids.
# Every behavioral case below therefore runs unconditionally and reports its own
# real reason (MODULE_NOT_FOUND, wrong arity, old contract) when it cannot pass.
REQUIRED_API_REPORT="$(node -e "
  const out = [];
  function probe(label, fn) {
    try { out.push(label + '=' + fn()); }
    catch (e) { out.push(label + '=' + String((e && e.code) || (e && e.name) || 'ERROR')); }
  }
  probe('resolve', function () {
    const r = require('$RESOLVER_N');
    if (typeof r.resolveSkipConditionsFromComplexity !== 'function') { return 'missing'; }
    // Callable, not merely present: fail-open on an unknown session id.
    r.resolveSkipConditionsFromComplexity('probe-no-such-session', 'outline');
    return 'callable';
  });
  probe('readStage', function () {
    const r = require('$RESOLVER_N');
    return typeof r.readStageComplexityLevel === 'function' ? 'callable' : 'missing';
  });
  probe('isZeroSignalLow', function () {
    const cr = require('$ROUTING_N');
    return typeof cr.isZeroSignalLow === 'function' ? 'callable' : 'missing';
  });
  probe('recordArity', function () {
    const io = require('$STATEIO_N');
    return typeof io.recordComplexityEvaluation === 'function'
      ? String(io.recordComplexityEvaluation.length) : 'missing';
  });
  console.log(out.join(' '));
" 2>/dev/null || echo 'PROBE_CRASHED')"
assert_eq "SC-API. every required member of the #2099 skip-resolution path exists and is callable" \
    'resolve=callable readStage=callable isZeroSignalLow=callable recordArity=2' \
    "$REQUIRED_API_REPORT"
# This probe pins the member's PRESENCE only. That the resolver actually
# DELEGATES its decision to it — rather than duplicating the predicate inline —
# is proven by SD-1/SD-3 in
# tests/feature-2099-complexity-stage-routing/skip-delegation-cases.sh.

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"

# record a complexity evaluation via the state-io write API.
# Signals-only since #2099: the level is derived, never supplied by the caller.
node_record() {
    local sid="$1" signals_json="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    io.recordComplexityEvaluation('$sid', $signals_json);
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

write_raw_state() {
    local sid="$1" raw="$2"
    printf '%s' "$raw" > "$WORKFLOW_DIR/${sid}.json"
}

# Seed an arbitrary complexity_evaluation shape via the REAL event store.
# `complexity_evaluation` is a projection key (#1733), so the older
# `s.complexity_evaluation = ...; writeState()` seeder was stripped on persist
# and every case built on it asserted an ABSENT record, not a malformed one.
# `provenance` and contiguous 1-based `seq` are load-bearing: assertStreamIntegrity()
# rejects the file otherwise and readState() yields null.
inject_ce_event() {
    local sid="$1" ce_json="$2"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const fs = require('fs');
    const path = require('path');
    const io = require('$STATEIO_N');
    const s = io.createInitialState('$sid');
    s.events = (s.events || []).concat([Object.assign({
      kind: 'complexity_evaluation',
      provenance: 'observed',
      origin: 'test-injection',
      at: new Date().toISOString(),
    }, $ce_json)]);
    s.events.forEach(function (e, i) { e.seq = i + 1; });
    const p = io.getStatePath('$sid');
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify(s, null, 2));
  " 2>/dev/null
}

# Persistence pre-assertion for inject_ce_event: prints the record as the real
# projection folded it, or 'null'. Malformed-record cases call this FIRST, so a
# silently-vanished injection cannot make the assertion after it vacuous.
ce_projected() {
    local sid="$1"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.readState('$sid');
    if (!s) { console.log('__NO_STATE__'); }
    else if (s.complexity_evaluation === null || s.complexity_evaluation === undefined) { console.log('null'); }
    else { console.log(JSON.stringify(s.complexity_evaluation)); }
  " 2>/dev/null
}

# High level with an empty signals array (SC-8 boundary) — unreachable through
# recordComplexityEvaluation now that the level is derived, so it is injected.
record_high_empty_signals() {
    inject_ce_event "$1" "{ level: 'high', signals: [] }"
}
