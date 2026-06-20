#!/bin/bash
# tests/feature-workflow-init-routing/_lib.sh
# Shared helpers for the feature-workflow-init-routing split test suite.
#
# Sourced by each split file (m-g-s-series.sh / c-series.sh / w-series.sh) so
# they can also run standalone.
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_WI_ROUTING_LIB_SOURCED:-}" ]; then
    return 0
fi
_WI_ROUTING_LIB_SOURCED=1

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
STATE_LIB="$AGENTS_DIR/hooks/lib/workflow-state.js"
WORKFLOW_INIT_MD="$AGENTS_DIR/skills/workflow-init/SKILL.md"
CLARIFY_INTENT_MD="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
AGENTS_CLAUDE_MD="$AGENTS_DIR/CLAUDE.md"
LABELS_YML="$AGENTS_DIR/.github/labels.yml"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Resolve the plans dir as Node sees it (Windows path munging safe)
PLANS_DIR_NATIVE=$(node -e "console.log(require('path').join(require('os').homedir(), '.workflow-plans').replace(/\\\\/g, '/'))")

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# Legacy state: no workflow_init key, clarify_intent absent
state_ci_absent() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO"
}

# Legacy state: no workflow_init key, clarify_intent = complete
state_ci_complete() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"complete","updated_at":"%s"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$NOW_ISO"
}

# Legacy state: no workflow_init key, clarify_intent = skipped
state_ci_skipped() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"skipped","updated_at":"%s"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$NOW_ISO"
}

# Legacy state: no workflow_init key, clarify_intent = pending (in-flight session at upgrade time)
state_ci_pending() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"pending","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO"
}

# New state with explicit workflow_init + clarify_intent statuses
state_wi_ci() {
    local sid="$1" wi_status="$2" ci_status="$3"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"workflow_init":{"status":"%s","updated_at":null},"clarify_intent":{"status":"%s","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$wi_status" "$ci_status"
}

# Read workflow_init.status via readState() (applies migration).
# Run node from AGENTS_DIR so relative require paths work on Windows.
read_wi_status() {
    local sid="$1"
    (cd "$AGENTS_DIR" && node -e "
const { readState } = require('./hooks/lib/workflow-state.js');
const s = readState('$sid');
const wi = s && s.steps && s.steps.workflow_init;
process.stdout.write(wi ? wi.status : 'MISSING');
" 2>/dev/null) || echo "ERROR"
}

# ---------------------------------------------------------------------------
# Gate helpers (mirror feature-clarify-intent-gate.sh)
# ---------------------------------------------------------------------------
run_gate() {
    local input="$1"
    echo "$input" | run_with_timeout node "$GATE_HOOK" 2>/dev/null || true
}

assert_decision() {
    local test_name="$1" input="$2" expected="$3"
    local output actual
    output=$(run_gate "$input")
    actual=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).decision||'')}catch(e){process.stdout.write('')}})")
    if [ "$actual" = "$expected" ]; then
        pass "$test_name"
    else
        fail "$test_name (expected=$expected, got=$actual)"
    fi
}

assert_message_contains() {
    local test_name="$1" input="$2" pattern="$3"
    local output msg
    output=$(run_gate "$input")
    msg=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{const p=JSON.parse(d);process.stdout.write(p.reason||p.message||'')}catch(e){process.stdout.write('')}})")
    if printf '%s' "$msg" | grep -qF "$pattern"; then
        pass "$test_name"
    else
        fail "$test_name (pattern '$pattern' not found in block reason)"
    fi
}

assert_message_absent() {
    local test_name="$1" input="$2" pattern="$3"
    local output msg
    output=$(run_gate "$input")
    msg=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{const p=JSON.parse(d);process.stdout.write(p.reason||p.message||'')}catch(e){process.stdout.write('')}})")
    if printf '%s' "$msg" | grep -qF "$pattern"; then
        fail "$test_name (unexpected pattern '$pattern' found in reason)"
    else
        pass "$test_name"
    fi
}

assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then fail "$desc (file not found: $file)"; return 1; fi
    if grep -qE "$pattern" "$file"; then pass "$desc"; else fail "$desc (pattern not found: $pattern in $file)"; fi
}

assert_absent_local() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then fail "$desc (file not found)"; return 1; fi
    if grep -qF "$pattern" "$file"; then fail "$desc (unexpected literal '$pattern' present)"; else pass "$desc"; fi
}

input_edit()  { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"x","new_string":"y"}}' "$sid" "$fp"; }
input_write() { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"hello"}}' "$sid" "$fp"; }

# Build a PostToolUse-style JSON for workflow-mark.js
build_mark_json() {
    local cmd="$1" sid="$2"
    local esc="${cmd//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' \
        "$esc" "$esc" "$sid"
}
