#!/usr/bin/env bash
# Tests: hooks/workflow-mark.js, hooks/lib/workflow-state/state-io.js, skills/make-outline-plan/SKILL.md, hooks/lib/sentinel-patterns.js, settings.json
# Tags: workflow, outline, planning, settings, config, premise-gate, removal, scope:issue-specific
# Test suite for premise-verification gate REMOVAL (abort-only contract).
# Static doc/JSON checks + asserts that PREMISE_FAIL/PREMISE_ACK sentinel
# machinery is gone from settings.json, sentinel-patterns.js, and disk.
# Tests will FAIL until the source removal lands — that is expected.
# L3 gap (what this test does NOT catch):
# - That workflow-mark.js is actually registered and fires in a real Claude Code session
# - That PREMISE_FAIL/PREMISE_ACK sentinels emitted in a live session are silently ignored (no block, no error)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SETTINGS_JSON="$REPO_ROOT/settings.json"
OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
HOOK="$REPO_ROOT/hooks/workflow-mark.js"
SENTINEL_PATTERNS="$REPO_ROOT/hooks/lib/sentinel-patterns.js"
PREMISE_HANDLER="$REPO_ROOT/hooks/workflow-mark/premise-gate-handlers.js"
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

assert_file_not_contains() {
    local id="$1"
    local desc="$2"
    local file="$3"
    local needle="$4"
    if [ ! -f "$file" ]; then
        fail "${id}. ${desc} — file missing: $file"
        return
    fi
    if run_with_timeout grep -qF -- "$needle" "$file"; then
        fail "${id}. ${desc} — substring should be absent: '${needle}' in $file"
    else
        pass "${id}. ${desc}"
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
# Section A — settings.json static checks (allow-lists removed)
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

# PG-NO-ALLOW-PREMISE-FAIL: settings.json does NOT allow-list WORKFLOW_PREMISE_FAIL
# (substring is JSON-escaped — backslash-quote inside the .json source)
assert_file_not_contains "PG-NO-ALLOW-PREMISE-FAIL" \
    "settings.json does NOT allow-list WORKFLOW_PREMISE_FAIL pattern" \
    "$SETTINGS_JSON" \
    'WORKFLOW_PREMISE_FAIL'

# PG-NO-ALLOW-PREMISE-ACK: settings.json does NOT allow-list WORKFLOW_PREMISE_ACK
assert_file_not_contains "PG-NO-ALLOW-PREMISE-ACK" \
    "settings.json does NOT allow-list WORKFLOW_PREMISE_ACK pattern" \
    "$SETTINGS_JSON" \
    'WORKFLOW_PREMISE_ACK'

# ===========================================================================
# Section B — make-outline-plan documentation (abort-only contract)
# ===========================================================================
echo ""
echo "=== Section B — make-outline-plan SKILL.md ==="

# PG-STEP0-DOC: SKILL.md still contains MOP-0 label
assert_file_contains "PG-STEP0-DOC" \
    "make-outline-plan SKILL.md contains 'MOP-0' label" \
    "$OUTLINE_SKILL" \
    "MOP-0"

# PG-BOTH-MISSING: documents handling for missing artifact files
assert_file_contains "PG-BOTH-MISSING" \
    "make-outline-plan SKILL.md mentions 'artifact' (Step 0 missing-file handling)" \
    "$OUTLINE_SKILL" \
    "artifact"

# PG-STEP0-ABORT: SKILL.md MOP-0c must instruct re-run of clarify-intent
# (abort-only contract — no AskUserQuestion branching, no PREMISE_ACK path)
assert_file_contains "PG-STEP0-ABORT" \
    "make-outline-plan SKILL.md instructs clarify-intent re-run on contradiction" \
    "$OUTLINE_SKILL" \
    "clarify-intent"

# PG-NO-PREMISE-FAIL: SKILL.md no longer references WORKFLOW_PREMISE_FAIL literal
assert_file_not_contains "PG-NO-PREMISE-FAIL" \
    "make-outline-plan SKILL.md does NOT contain 'WORKFLOW_PREMISE_FAIL'" \
    "$OUTLINE_SKILL" \
    "WORKFLOW_PREMISE_FAIL"

# PG-NO-PREMISE-ACK: SKILL.md no longer references WORKFLOW_PREMISE_ACK literal
assert_file_not_contains "PG-NO-PREMISE-ACK" \
    "make-outline-plan SKILL.md does NOT contain 'WORKFLOW_PREMISE_ACK'" \
    "$OUTLINE_SKILL" \
    "WORKFLOW_PREMISE_ACK"

# ===========================================================================
# Section C — source-tree removal checks
# ===========================================================================
echo ""
echo "=== Section C — source-tree removal ==="

# PG-HANDLER-DELETED: premise-gate-handlers.js must not exist on disk
if [ ! -f "$PREMISE_HANDLER" ]; then
    pass "PG-HANDLER-DELETED. hooks/workflow-mark/premise-gate-handlers.js does not exist"
else
    fail "PG-HANDLER-DELETED. hooks/workflow-mark/premise-gate-handlers.js should not exist: $PREMISE_HANDLER"
fi

# PG-REGEX-REMOVED: sentinel-patterns.js must NOT export PREMISE_FAIL_RE_DQ or PREMISE_ACK_RE_DQ
regex_check=$(run_with_timeout node -e "
const sp = require(process.argv[1]);
if (sp.PREMISE_FAIL_RE_DQ !== undefined) { console.log('PREMISE_FAIL_RE_DQ still exported'); process.exit(1); }
if (sp.PREMISE_ACK_RE_DQ !== undefined) { console.log('PREMISE_ACK_RE_DQ still exported'); process.exit(1); }
console.log('OK');
" "$SENTINEL_PATTERNS" 2>&1) || regex_rc=$?
if [ "${regex_rc:-0}" -eq 0 ] && [ "$regex_check" = "OK" ]; then
    pass "PG-REGEX-REMOVED. sentinel-patterns.js does not export PREMISE_FAIL_RE_DQ / PREMISE_ACK_RE_DQ"
else
    fail "PG-REGEX-REMOVED. sentinel-patterns.js still exports premise regex(es): $regex_check"
fi
unset regex_rc

# PG-STATE-IO-REMOVED: state-io.js does not export premise helper functions
state_io_check=$(run_with_timeout node -e "
  const m = require('$REPO_ROOT/hooks/lib/workflow-state/state-io.js');
  const found = ['setPremiseContradiction','clearPremiseContradiction','getPremiseContradiction']
    .filter(n => typeof m[n] !== 'undefined');
  if (found.length > 0) { process.stdout.write('found: ' + found.join(', ')); process.exit(1); }
  process.stdout.write('OK');
" 2>&1) || state_io_rc=$?
if [ "${state_io_rc:-0}" -eq 0 ] && [ "$state_io_check" = "OK" ]; then
    pass "PG-STATE-IO-REMOVED. state-io.js does not export premise helper functions"
else
    fail "PG-STATE-IO-REMOVED. state-io.js still exports premise helpers — $state_io_check"
fi
unset state_io_rc

# PG-PREDICATE-REMOVED: isSentinel() and isStrictSentinel() must return false
# for both PREMISE_FAIL and PREMISE_ACK echo strings.
predicate_check=$(run_with_timeout node -e "
const sp = require(process.argv[1]);
const cases = [
  'echo \"<<WORKFLOW_PREMISE_FAIL: test>>\"',
  'echo \"<<WORKFLOW_PREMISE_ACK>>\"'
];
for (const c of cases) {
  if (sp.isSentinel(c)) { console.log('isSentinel still matches: ' + c); process.exit(1); }
  if (sp.isStrictSentinel(c)) { console.log('isStrictSentinel still matches: ' + c); process.exit(1); }
}
console.log('OK');
" "$SENTINEL_PATTERNS" 2>&1) || predicate_rc=$?
if [ "${predicate_rc:-0}" -eq 0 ] && [ "$predicate_check" = "OK" ]; then
    pass "PG-PREDICATE-REMOVED. isSentinel/isStrictSentinel return false for premise sentinels"
else
    fail "PG-PREDICATE-REMOVED. premise sentinel still recognised: $predicate_check"
fi
unset predicate_rc

# ===========================================================================
# Section D — workflow-mark.js backward-compat (no crash on normal sentinel)
# ===========================================================================
echo ""
echo "=== Section D — workflow-mark.js no-crash check ==="

# PG-NULL: state JSON without premise_contradiction field — after removal of
# the premise_contradiction state field, normal sentinels must still process
# cleanly without crashing the hook.
make_env_file "sess-pg-null"
cat > "$CLAUDE_WORKFLOW_DIR/sess-pg-null.json" <<'EOF'
{"version":1,"session_id":"sess-pg-null","steps":{"workflow_init":{"status":"complete"}}}
EOF
pg_null_json='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\""},"session_id":"sess-pg-null","agent_id":"","tool_response":{"exit_code":0}}'
pg_null_result=$(run_hook "$pg_null_json")
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

# PG-IGNORED: PREMISE_FAIL sentinel is no longer recognized — hook silently ignores
# it (allAreSentinels check fails → done() with no state change, valid JSON output).
make_env_file "sess-pg-ignored"
cat > "$CLAUDE_WORKFLOW_DIR/sess-pg-ignored.json" <<'EOF'
{"version":1,"session_id":"sess-pg-ignored","steps":{"workflow_init":{"status":"complete"}}}
EOF
pg_ignored_json='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_PREMISE_FAIL: test reason>>\""},"session_id":"sess-pg-ignored","agent_id":"","tool_response":{"exit_code":0}}'
pg_ignored_result=$(run_hook "$pg_ignored_json")
if [ -z "$pg_ignored_result" ]; then
    fail "PG-IGNORED. PREMISE_FAIL into hook → expected JSON output, got empty"
else
    pg_ignored_parsed=$(node -e "try{JSON.parse(process.argv[1]);process.stdout.write('ok')}catch(e){process.stdout.write('err:'+e.message)}" -- "$pg_ignored_result" 2>/dev/null || true)
    pg_ignored_decision=$(hook_decision "$pg_ignored_result")
    if [ "$pg_ignored_parsed" = "ok" ] && [ "$pg_ignored_decision" != "block" ]; then
        pass "PG-IGNORED. PREMISE_FAIL not a sentinel → hook ignores, returns valid JSON, no block"
    else
        fail "PG-IGNORED. PREMISE_FAIL → parse='${pg_ignored_parsed}' decision='${pg_ignored_decision}' raw=${pg_ignored_result}"
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
