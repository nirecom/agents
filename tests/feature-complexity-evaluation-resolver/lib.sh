#!/usr/bin/env bash
# tests/feature-complexity-evaluation-resolver/lib.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/state-io.js, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation
# Tags: complexity, resolver, state-io, helpers, scope:issue-specific
# Shared setup + helpers for feature-complexity-evaluation-resolver.sh.
# Sourced (not executed). Defines paths, API/CLI presence probes, the tmp
# workflow dir, counters, assertion helpers, and node/CLI invocation wrappers.
#
# Split from the entrypoint per rules/coding/file-split.md Pattern A (>500 lines):
# the entrypoint keeps the test cases; mechanics live here.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/workflow-state/skip-signal-resolver.js"
RESOLVER_N="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"
STATEIO="$AGENTS_DIR/hooks/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"

RECORD_CLI="$AGENTS_DIR/bin/workflow/record-complexity-evaluation"
READ_CLI="$AGENTS_DIR/bin/workflow/read-complexity-evaluation"
RECORD_CLI_N="$(cygpath -m "$RECORD_CLI" 2>/dev/null || echo "$RECORD_CLI")"
READ_CLI_N="$(cygpath -m "$READ_CLI" 2>/dev/null || echo "$READ_CLI")"

# --- required-API/CLI assertions (NOT skip gates) ----------------------------
# Every member below is REQUIRED by #2099 (detail.md "Files to modify" 3/7/8/9/10
# and D4/D6). Their absence is a FAILURE. The previous API_READY / CLI_READY
# gates turned "not implemented yet" into "0 failed, N skipped" — a false green
# that hides the fail-before-fix state entirely (R3-C7). The cases below now run
# unconditionally and report their own real reason when they cannot pass.
API_READY_REPORT="$(node -e "
  const out = [];
  function probe(label, fn) {
    try { out.push(label + '=' + fn()); }
    catch (e) { out.push(label + '=' + String((e && e.code) || (e && e.name) || 'ERROR')); }
  }
  probe('read', function () {
    return typeof require('$RESOLVER_N').readComplexityEvaluation === 'function' ? 'callable' : 'missing';
  });
  probe('has', function () {
    return typeof require('$RESOLVER_N').hasComplexityEvaluation === 'function' ? 'callable' : 'missing';
  });
  probe('readStage', function () {
    return typeof require('$RESOLVER_N').readStageComplexityLevel === 'function' ? 'callable' : 'missing';
  });
  probe('rawEvent', function () {
    return typeof require('$STATEIO_N').readLastRawComplexityEvent === 'function' ? 'callable' : 'missing';
  });
  probe('recordArity', function () {
    const io = require('$STATEIO_N');
    return typeof io.recordComplexityEvaluation === 'function'
      ? String(io.recordComplexityEvaluation.length) : 'missing';
  });
  console.log(out.join(' '));
" 2>/dev/null || echo 'PROBE_CRASHED')"

CLI_PRESENT_REPORT="record=$([ -f "$RECORD_CLI" ] && echo yes || echo no)"
CLI_PRESENT_REPORT="$CLI_PRESENT_REPORT read=$([ -f "$READ_CLI" ] && echo yes || echo no)"
CLI_PRESENT_REPORT="$CLI_PRESENT_REPORT derive=$([ -f "$AGENTS_DIR/bin/workflow/derive-complexity-level" ] && echo yes || echo no)"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/wf"
mkdir -p "$WORKFLOW_DIR"
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP (pre-impl): $1"; SKIP=$((SKIP + 1)); }

# assert_eq <desc> <want> <got>  (inline, per issue rule; distinct want/got labels)
assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass "$desc"
  else
    fail "$desc -- want [$want], got [$got]"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$desc" ;;
    *) fail "$desc -- expected to contain [$needle], got [$haystack]" ;;
  esac
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$desc -- expected NOT to contain [$needle], got [$haystack]" ;;
    *) pass "$desc" ;;
  esac
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

# record via the state-io write API; returns nothing (fail-open silent).
# Signals-only since #2099: the level is derived, never supplied by the caller.
node_record() {
  local sid="$1" signals_json="$2"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    io.recordComplexityEvaluation('$sid', $signals_json);
  " 2>&1
}

# Seed a complexity_evaluation shape the write API can no longer produce, via
# the REAL event store. `complexity_evaluation` is a projection key (#1733), so
# the older `s.complexity_evaluation = ...; writeState()` seeder was stripped on
# persist and every case built on it asserted an ABSENT record, not a malformed
# one. `provenance` and contiguous 1-based `seq` are load-bearing:
# assertStreamIntegrity() rejects the file otherwise and readState() yields null.
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

# Raw complexity_evaluation event count (append-only audit history; C11).
ce_event_count() {
  local sid="$1"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    const s = io.readState('$sid');
    const ev = (s && s.events) || [];
    console.log(String(ev.filter(function (e) { return e && e.kind === 'complexity_evaluation'; }).length));
  " 2>/dev/null
}

# read via the resolver read API; prints JSON or the literal 'null'.
node_read_json() {
  local sid="$1"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.readComplexityEvaluation('$sid');
    console.log(v === null ? 'null' : JSON.stringify(v));
  " 2>/dev/null
}

# read a single field from the returned object.
node_read_field() {
  local sid="$1" field="$2"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    const v = r.readComplexityEvaluation('$sid');
    if (v === null) { console.log('__NULL__'); }
    else { console.log(JSON.stringify(v['$field'])); }
  " 2>/dev/null
}

node_has() {
  local sid="$1"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    console.log(r.hasComplexityEvaluation('$sid') ? 'true' : 'false');
  " 2>/dev/null
}

# Write a raw string as the state file for a sid (corruption / hand-craft cases).
write_raw_state() {
  local sid="$1" raw="$2"
  printf '%s' "$raw" > "$WORKFLOW_DIR/${sid}.json"
}

# --- the required-member assertions themselves -------------------------------
# Emitted here rather than beside the probes above because assert_eq is defined
# in between. Pre-implementation these two FAIL, which is the correct signal.
assert_eq "CE-REQ-1. every required resolver/state-io member exists and is callable" \
  'read=callable has=callable readStage=callable rawEvent=callable recordArity=2' \
  "$API_READY_REPORT"
assert_eq "CE-REQ-2. every required complexity CLI exists" \
  'record=yes read=yes derive=yes' "$CLI_PRESENT_REPORT"
