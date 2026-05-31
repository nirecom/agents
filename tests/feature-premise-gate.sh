#!/usr/bin/env bash
# Tests: hooks/workflow-mark.js, hooks/workflow-mark.js., skills/make-outline-plan/SKILL.md
# Tags: workflow, outline, planning, settings, config
# Test suite for premise-verification gate feature (Issue #262).
# Static doc/JSON checks + narrow integration tests against hooks/workflow-mark.js.
# Tests will FAIL until the source updates are implemented — that is expected.
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SETTINGS_JSON="$REPO_ROOT/settings.json"
OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
HOOK="$REPO_ROOT/hooks/workflow-mark.js"
ERRORS=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS does not have timeout)
# ---------------------------------------------------------------------------
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temp dir / env file setup (mirrors feature-block-tests-direct.sh)
# ---------------------------------------------------------------------------
TMPDIR_ROOT="$(node -e "const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');const d=path.join(os.tmpdir(),'pgtest-'+crypto.randomBytes(6).toString('hex'));fs.mkdirSync(d,{recursive:true});process.stdout.write(d);")"
CLAUDE_WORKFLOW_DIR="$TMPDIR_ROOT/workflow"
CLAUDE_ENV_FILE="$TMPDIR_ROOT/claude_env"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

make_env_file() {
    local session_id="$1"
    printf 'CLAUDE_SESSION_ID=%s\n' "$session_id" > "$CLAUDE_ENV_FILE"
}

fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_file_contains() {
    local id="$1"
    local desc="$2"
    local file="$3"
    local needle="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — substring not found: '${needle}' in $file"
    fi
}

# ---------------------------------------------------------------------------
# Hook runner — exec workflow-mark.js with JSON on stdin, return its stdout.
# ---------------------------------------------------------------------------
run_hook() {
    local json="$1"
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    local result
    result=$(
        (
            export CLAUDE_ENV_FILE="$CLAUDE_ENV_FILE"
            export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
            run_with_timeout node "$HOOK" < "$input_file" 2>/dev/null
        )
    ) || true
    rm -f "$input_file"
    printf '%s' "$result"
}

# Extract decision from hook JSON output.
hook_decision() {
    local result="$1"
    node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true
}

# ===========================================================================
# Section A — settings.json static checks
# ===========================================================================
echo ""
echo "=== Section A — settings.json static checks ==="

# PG-JSON: settings.json is valid JSON
if [ ! -f "$SETTINGS_JSON" ]; then
    fail "PG-JSON. settings.json exists — file missing: $SETTINGS_JSON"
else
    if run_with_timeout node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$SETTINGS_JSON" >/dev/null 2>&1; then
        pass "PG-JSON. settings.json is valid JSON"
    else
        fail "PG-JSON. settings.json is valid JSON — parse failed"
    fi
fi

# PG-H1: settings.json allow-lists WORKFLOW_PREMISE_FAIL pattern
assert_file_contains "PG-H1" \
    "settings.json allows Bash(echo \"<<WORKFLOW_PREMISE_FAIL: *>>\")" \
    "$SETTINGS_JSON" \
    'Bash(echo "<<WORKFLOW_PREMISE_FAIL: *>>")'

# PG-H2: settings.json allow-lists WORKFLOW_PREMISE_ACK pattern
assert_file_contains "PG-H2" \
    "settings.json allows Bash(echo \"<<WORKFLOW_PREMISE_ACK>>\")" \
    "$SETTINGS_JSON" \
    'Bash(echo "<<WORKFLOW_PREMISE_ACK>>")'

# ===========================================================================
# Section B — make-outline-plan Step 0 documentation
# ===========================================================================
echo ""
echo "=== Section B — make-outline-plan Step 0 documentation ==="

# PG-STEP0-DOC: make-outline-plan SKILL.md contains "Step 0" section
assert_file_contains "PG-STEP0-DOC" \
    "make-outline-plan SKILL.md contains 'Step 0' section" \
    "$OUTLINE_SKILL" \
    "Step 0"

# PG-BOTH-MISSING: documents handling for missing artifact files
assert_file_contains "PG-BOTH-MISSING" \
    "make-outline-plan SKILL.md mentions 'artifact' (Step 0 missing-file handling)" \
    "$OUTLINE_SKILL" \
    "artifact"

# ===========================================================================
# Section C — workflow-mark.js narrow integration tests
# ===========================================================================
echo ""
echo "=== Section C — workflow-mark.js integration ==="

# PG-E1: WORKFLOW_PREMISE_FAIL without reason → should be rejected (block).
# Until the hook learns about WORKFLOW_PREMISE_FAIL, it will fail-open (no block).
make_env_file "sess-pg-e1"
cat > "$CLAUDE_WORKFLOW_DIR/sess-pg-e1.json" <<'EOF'
{"version":1,"session_id":"sess-pg-e1","steps":{}}
EOF
pg_e1_json='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_PREMISE_FAIL>>\""},"session_id":"sess-pg-e1","agent_id":""}'
pg_e1_result=$(run_hook "$pg_e1_json")
pg_e1_decision=$(hook_decision "$pg_e1_result")
if [ "$pg_e1_decision" = "block" ]; then
    pass "PG-E1. WORKFLOW_PREMISE_FAIL without reason → rejected (block)"
else
    fail "PG-E1. WORKFLOW_PREMISE_FAIL without reason → expected block, got: '${pg_e1_decision}' (raw: ${pg_e1_result})"
fi

# PG-E2: bare single-quoted sentinel → should be rejected (lookslike pattern).
make_env_file "sess-pg-e2"
cat > "$CLAUDE_WORKFLOW_DIR/sess-pg-e2.json" <<'EOF'
{"version":1,"session_id":"sess-pg-e2","steps":{}}
EOF
pg_e2_json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo '<<WORKFLOW_PREMISE_FAIL: something>>'\"},\"session_id\":\"sess-pg-e2\",\"agent_id\":\"\"}"
pg_e2_result=$(run_hook "$pg_e2_json")
pg_e2_decision=$(hook_decision "$pg_e2_result")
if [ "$pg_e2_decision" = "block" ]; then
    pass "PG-E2. single-quoted PREMISE_FAIL → rejected (block, lookslike)"
else
    fail "PG-E2. single-quoted PREMISE_FAIL → expected block, got: '${pg_e2_decision}' (raw: ${pg_e2_result})"
fi

# PG-NULL: backward compat — state JSON without premise_contradiction field
# should not cause a crash when a normal sentinel is processed.
make_env_file "sess-pg-null"
cat > "$CLAUDE_WORKFLOW_DIR/sess-pg-null.json" <<'EOF'
{"version":1,"session_id":"sess-pg-null","steps":{"workflow_init":{"status":"complete"}}}
EOF
pg_null_json='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\""},"session_id":"sess-pg-null","agent_id":"","tool_response":{"exit_code":0}}'
pg_null_result=$(run_hook "$pg_null_json")
# workflow-mark.js is PostToolUse — it emits JSON (possibly with additionalContext)
# and exits 0; it never returns decision=block for normal sentinels.
# "Fail-open / no crash" = output parses as JSON without a 'block' decision.
if [ -z "$pg_null_result" ]; then
    fail "PG-NULL. state without premise_contradiction → expected JSON output, got empty"
else
    pg_null_parsed=$(node -e "try{JSON.parse(process.argv[1]);process.stdout.write('ok')}catch(e){process.stdout.write('err:'+e.message)}" -- "$pg_null_result" 2>/dev/null || true)
    pg_null_decision=$(hook_decision "$pg_null_result")
    if [ "$pg_null_parsed" = "ok" ] && [ "$pg_null_decision" != "block" ]; then
        pass "PG-NULL. state without premise_contradiction → no crash, no block"
    else
        fail "PG-NULL. state without premise_contradiction — parse='${pg_null_parsed}' decision='${pg_null_decision}' raw=${pg_null_result}"
    fi
fi

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + ERRORS))
echo "Results: ${PASS_COUNT}/${TOTAL} passed, ${ERRORS} failed"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "${ERRORS} test(s) failed"
    exit 1
fi
