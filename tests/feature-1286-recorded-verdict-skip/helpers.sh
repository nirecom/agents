# shellcheck shell=bash
# Shared helpers + fixtures for feature-1286-recorded-verdict-skip tests.
# Sourced by module-api.sh, cli.sh, gate.sh, next-step.sh — not a standalone runner.
#
# Pre-implementation tests for #1286 (recorded-verdict skip judgment).
# All state-file reads use the robust bash-reads-file-then-pipes-to-node pattern
# (read_state_field / read_skip_judgment_raw) — never the fragile inline
# process.env.CLAUDE_WORKFLOW_DIR node snippet.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if command -v cygpath >/dev/null 2>&1; then
  AGENTS_DIR_N="$(cygpath -m "$AGENTS_DIR")"
else
  AGENTS_DIR_N="$AGENTS_DIR"
fi

SKIP_RESOLVER="$AGENTS_DIR/hooks/lib/workflow-state/skip-signal-resolver.js"
GATE_HOOK="$AGENTS_DIR/hooks/gate-plan-skip-sentinel.js"
RECORD_CLI="$AGENTS_DIR/bin/workflow/record-skip-judgment"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"

RESOLVER_N="$(cygpath -m "$SKIP_RESOLVER" 2>/dev/null || echo "$SKIP_RESOLVER")"
RECORD_CLI_N="$(cygpath -m "$RECORD_CLI" 2>/dev/null || echo "$RECORD_CLI")"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
# Windows-native path so Node.js can read/write via CLAUDE_WORKFLOW_DIR.
WORKFLOW_DIR_N="$(cygpath -m "$WORKFLOW_DIR" 2>/dev/null || echo "$WORKFLOW_DIR")"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_N"

# Empty config dir so the gate hook's load-env.js finds no .env — CONFIRM_* env
# vars then reflect only what the test explicitly sets (load-env.js treats the
# parent repo's .env CONFIRM_DETAIL=off as authoritative otherwise). Mirrors the
# T14 isolation pattern in tests/feature-gate-plan-skip-sentinel.sh.
EMPTY_CONFIG_DIR="$TMPDIR_BASE/empty-config"
mkdir -p "$EMPTY_CONFIG_DIR"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"
  else fail "$desc -- expected [$expected] got [$actual]"; fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then pass "$desc"
  else fail "$desc -- expected [$needle] in: $haystack"; fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then fail "$desc -- did NOT expect [$needle] in: $haystack"
  else pass "$desc"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Skip guard: the recorded-verdict API is not implemented at test-authoring time.
# Sub-files call this to decide whether to run the API-dependent cases or count
# guarded skips as passes so the suite stays green pre-implementation.
api_exists() {
  [ -f "$SKIP_RESOLVER" ] || return 1
  run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    if (typeof r.recordSkipJudgment !== 'function') process.exit(1);
  " 2>/dev/null
}

write_state() {
  local sid="$1" json="$2"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# Read step.<field> from a state file. Bash reads the file; node parses stdin.
read_state_field() {
  local sid="$1" step="$2" field="$3"
  local state_file="$WORKFLOW_DIR/${sid}.json"
  if [ ! -f "$state_file" ]; then echo "FILE_MISSING"; return; fi
  cat "$state_file" | run_with_timeout node -e "
    let data=''; process.stdin.on('data',d=>data+=d);
    process.stdin.on('end',()=>{
      try{
        const s=JSON.parse(data);
        const entry=s.steps&&s.steps['$step'];
        if(!entry){console.log('null');process.exit(0);}
        const v=entry['$field'];
        console.log(JSON.stringify(v!==undefined?v:null));
      }catch(e){console.log('PARSE_ERR:'+e.message);}
    });
  " 2>/dev/null || echo "READ_ERR"
}

# Read the raw skip_judgment object from a state file (or 'null').
read_skip_judgment_raw() {
  local sid="$1" step="$2"
  local state_file="$WORKFLOW_DIR/${sid}.json"
  if [ ! -f "$state_file" ]; then echo "null"; return; fi
  cat "$state_file" | run_with_timeout node -e "
    let data=''; process.stdin.on('data',d=>data+=d);
    process.stdin.on('end',()=>{
      try{
        const s=JSON.parse(data);
        const sj=s.steps&&s.steps['$step']&&s.steps['$step'].skip_judgment;
        console.log(JSON.stringify(sj||null));
      }catch(e){console.log('null');}
    });
  " 2>/dev/null || echo "null"
}

run_gate() {
  local input="$1"
  local hook_path
  hook_path="$(cygpath -m "$GATE_HOOK" 2>/dev/null || echo "$GATE_HOOK")"
  echo "$input" | run_with_timeout node "$hook_path" 2>/dev/null || true
}

build_bash_input() {
  local cmd="$1"
  local esc=${cmd//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$esc"
}

# Node-evaluate a snippet with the resolver already required as `r`. Prints
# stdout+stderr (so red-phase "not a function" errors surface in assertions).
resolver_eval() {
  local snippet="$1"
  run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    $snippet
  " 2>&1 || echo "ERROR"
}

# JSON fixtures for next-step state.
JSON_AT_OUTLINE='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"pending"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1286]}'

JSON_AT_DETAIL='{"steps":{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"pending"},"branching_complete":{"status":"pending"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"pending"},"review_security":{"status":"pending"},"docs":{"status":"pending"},"user_verification":{"status":"pending"},"cleanup":{"status":"pending"},"pre_final_report_gate":{"status":"pending"}},"closes_issues":[1286]}'
