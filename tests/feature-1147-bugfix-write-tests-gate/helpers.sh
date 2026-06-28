#!/bin/bash
# Shared helpers for feature-1147-bugfix-write-tests-gate/ sub-scripts.
# Sourced by test-ssot-module.sh and test-defenses.sh.
# Callers must set: AGENTS_DIR, WIN_AGENTS_DIR, TMPDIR_ROOT,
#   CLAUDE_WORKFLOW_DIR, CLAUDE_ENV_FILE, HOOK_MARK, HOOK_GATE, NOW_ISO.
# Callers must define: fail(), pass() (with their own ERRORS / PASS_COUNT counters).

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# write_state <sid> [is_bugfix: true|false|absent] [git_branch]
# Writes an all-pending-except-boilerplate state into CLAUDE_WORKFLOW_DIR.
write_state() {
    local sid="$1"
    local is_bugfix="${2:-false}"
    local git_branch="${3:-main}"
    local is_bugfix_field=""
    if [ "$is_bugfix" = "true" ]; then
        is_bugfix_field='"is_bugfix": true,'
    elif [ "$is_bugfix" = "false" ]; then
        is_bugfix_field='"is_bugfix": false,'
    fi
    cat > "$CLAUDE_WORKFLOW_DIR/${sid}.json" <<EOF
{
  "version": 1,
  "session_id": "${sid}",
  "created_at": "${NOW_ISO}",
  ${is_bugfix_field}
  "git_branch": "${git_branch}",
  "steps": {
    "workflow_init":         {"status":"complete","updated_at":null},
    "clarify_intent":        {"status":"complete","updated_at":null},
    "research":              {"status":"skipped","updated_at":null},
    "outline":               {"status":"skipped","updated_at":null},
    "detail":                {"status":"skipped","updated_at":null},
    "branching_complete":    {"status":"complete","updated_at":null},
    "write_tests":           {"status":"pending","updated_at":null},
    "review_tests":          {"status":"pending","updated_at":null},
    "run_tests":             {"status":"complete","updated_at":null},
    "review_security":       {"status":"skipped","updated_at":null},
    "docs":                  {"status":"complete","updated_at":null},
    "user_verification":     {"status":"pending","updated_at":null},
    "cleanup":               {"status":"skipped","updated_at":null},
    "pre_final_report_gate": {"status":"complete","updated_at":null}
  },
  "workflow_type": "wf-code"
}
EOF
}

# write_state_with_steps <sid> <is_bugfix> <git_branch> <write_tests_status> <review_tests_status> [user_verification_status=pending]
write_state_with_steps() {
    local sid="$1" is_bugfix="$2" git_branch="$3" wt_status="$4" rt_status="$5" uv_status="${6:-pending}"
    local is_bugfix_field='"is_bugfix": false,'
    [ "$is_bugfix" = "true" ] && is_bugfix_field='"is_bugfix": true,'
    cat > "$CLAUDE_WORKFLOW_DIR/${sid}.json" <<EOF
{
  "version": 1,
  "session_id": "${sid}",
  "created_at": "${NOW_ISO}",
  ${is_bugfix_field}
  "git_branch": "${git_branch}",
  "steps": {
    "workflow_init":         {"status":"complete","updated_at":null},
    "clarify_intent":        {"status":"complete","updated_at":null},
    "research":              {"status":"skipped","updated_at":null},
    "outline":               {"status":"skipped","updated_at":null},
    "detail":                {"status":"skipped","updated_at":null},
    "branching_complete":    {"status":"complete","updated_at":null},
    "write_tests":           {"status":"${wt_status}","updated_at":null},
    "review_tests":          {"status":"${rt_status}","updated_at":null},
    "run_tests":             {"status":"complete","updated_at":null},
    "review_security":       {"status":"skipped","updated_at":null},
    "docs":                  {"status":"complete","updated_at":null},
    "user_verification":     {"status":"${uv_status}","updated_at":null},
    "cleanup":               {"status":"skipped","updated_at":null},
    "pre_final_report_gate": {"status":"complete","updated_at":null}
  },
  "workflow_type": "wf-code"
}
EOF
}

write_env_file() {
    printf 'CLAUDE_SESSION_ID=%s\n' "$1" > "$CLAUDE_ENV_FILE"
}

read_step_status() {
    local sid="$1" step="$2"
    node -e "
        const fs=require('fs');
        try {
            const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
            process.stdout.write((s.steps[process.argv[2]]||{}).status||'MISSING');
        } catch(e){ process.stdout.write('ERR'); }
    " -- "$CLAUDE_WORKFLOW_DIR/${sid}.json" "$step" 2>/dev/null || true
}

run_hook() {
    local json="$1"
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_XXXXXX.json")"
    printf '%s' "$json" > "$input_file"
    run_with_timeout node "$HOOK_MARK" < "$input_file" 2>&1 || true
    rm -f "$input_file"
}

run_gate() {
    local json="$1"
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/gate_XXXXXX.json")"
    printf '%s' "$json" > "$input_file"
    run_with_timeout node "$HOOK_GATE" < "$input_file" 2>&1 || true
    rm -f "$input_file"
}
