# tests/feature-complexity-evaluation-resolver/lib.sh
# Shared setup + helpers for feature-complexity-evaluation-resolver.sh.
# Sourced (not executed). Defines paths, API/CLI presence probes, the tmp
# workflow dir, counters, assertion helpers, and node/CLI invocation wrappers.
#
# Split from the entrypoint per rules/coding/file-split.md Pattern A (>500 lines):
# the entrypoint keeps the test cases; mechanics live here.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js"
RESOLVER_N="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"
STATEIO="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
STATEIO_N="$(cygpath -m "$STATEIO" 2>/dev/null || echo "$STATEIO")"

RECORD_CLI="$AGENTS_DIR/bin/workflow/record-complexity-evaluation"
READ_CLI="$AGENTS_DIR/bin/workflow/read-complexity-evaluation"
RECORD_CLI_N="$(cygpath -m "$RECORD_CLI" 2>/dev/null || echo "$RECORD_CLI")"
READ_CLI_N="$(cygpath -m "$READ_CLI" 2>/dev/null || echo "$READ_CLI")"

# --- API presence probe (no global skip) -------------------------------------
# recordComplexityEvaluation is the anchor symbol added by write-code. Its
# absence means the #1350 implementation has not landed → SKIP individual cases.
API_READY="$(node -e "
  try {
    const r = require('$RESOLVER_N');
    const io = require('$STATEIO_N');
    const ok = typeof r.readComplexityEvaluation === 'function'
      && typeof r.hasComplexityEvaluation === 'function'
      && typeof io.recordComplexityEvaluation === 'function';
    console.log(ok ? 'true' : 'false');
  } catch (e) { console.log('false'); }
" 2>/dev/null || echo "false")"

CLI_READY="false"
if [ -f "$RECORD_CLI" ] && [ -f "$READ_CLI" ]; then
  CLI_READY="true"
fi

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
node_record() {
  local sid="$1" verdict="$2" signals_json="$3"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N" run_with_timeout node -e "
    const io = require('$STATEIO_N');
    io.recordComplexityEvaluation('$sid', '$verdict', $signals_json);
  " 2>&1
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
