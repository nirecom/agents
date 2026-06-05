#!/bin/bash
# tests/feature-534-stop-final-report-guard.sh
# Tests: hooks/stop-final-report-guard.js, hooks/lib/final-report-schema.js, skills/session-close/SKILL.md
# Tags: settings, config, hook, tests
#
# Issue #534 / #626 / #771 — Stop hook: stop-final-report-guard.js
#
# Contract after #771 (renderer abolition):
# all 10 headings from getSectionHeadings(sid) required after last
# `## Final Report — <sid>` in transcript; residual <TOKEN> check;
# no env-file `reported` flag check.
#
# 1. env file absent → exit 0 (no-op)
# 2. env file malformed JSON → exit 0 (fail-open)
# 3. stop_hook_active:true → exit 0
# 4. last `## Final Report — <sid>` absent in transcript → exit 0
# 5. any of the 9 `###` headings missing AFTER that position → exit 2 + decision:block
# 6. residual `<[A-Z][A-Z_]+>` token in post-header region → exit 2 + decision:block
# 7. otherwise → exit 0
#
# G1, G4, G6, I1 unchanged from pre-#771 contract.
# G2, G7, G8 rewritten for new contract; G16–G20 added.
# Old `reported` flag tests (G3 G5 G10 G11 G12 G13 G14 G15 G16-old) deleted.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK_JS="${_AGENTS_DIR_NODE}/hooks/stop-final-report-guard.js"
SETTINGS_JSON="${AGENTS_DIR}/settings.json"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f534-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# Guard: skip all G-tests when the hook is not yet implemented.
require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        skip "$1 (hook not implemented yet)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Write a minimal env-file (all not_required) to $1.
write_default_env_file() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "CC_RESTART_REQUIRED": "not_required",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "not_required",
  "OS_REBOOT_REASON": ""
}
EOF
}

# Write a JSONL transcript whose last line is an assistant message containing $2.
# $1 = path to write, $2 = text for the last assistant message content.
write_transcript_with_assistant() {
    local path="$1"
    local text="$2"
    local escaped
    escaped="$(printf '%s' "$text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")"
    printf '{"type":"user","message":{"content":"hello"}}\n' > "$path"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$escaped" >> "$path"
}

# Build the full 10-heading canonical report text (1 ## + 9 ###) for given sid.
full_canonical_report_text() {
    local sid="$1"
    cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #(none): (none)
- URL: (none)
- State: (none)
### Worktree
- Branch: (none)
### Backup
- Manifest: (none)
### Closed Issue Outcomes
- (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
- VS Code reload: not_required
- Installer rerun: not_required
- OS reboot: not_required
### Bugs Found
- (none)
### Related Tasks
- (none)
### Next Tasks
- (none)
EOF
}

HOOK_EXIT=0
run_hook_exit() {
    local stdin_json="$1"
    local plans_dir="$2"
    WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" >/dev/null 2>&1
    echo "$?"
}

# ---------------------------------------------------------------------------
# G1: env-file absent → exit 0 (no-op)
# UNCHANGED
# ---------------------------------------------------------------------------
test_G1_envfile_absent() {
    require_hook "G1_envfile_absent" || return

    local plans_dir="$TMPDIR_BASE/g1-plans"
    mkdir -p "$plans_dir"
    local sid="g1-sid"
    # Do NOT create <plans_dir>/<sid>-final-report-env.json

    local transcript="$TMPDIR_BASE/g1-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Some random text."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G1: env-file absent → exit 0 (no-op)"
    else
        fail "G1: expected exit 0, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G2 (rewritten): env-file + all 10 headings present in transcript after
#                 last `## Final Report — <sid>` → exit 0
# ---------------------------------------------------------------------------
test_G2_all_headings_present_passes() {
    require_hook "G2_all_headings_present_passes" || return

    local plans_dir="$TMPDIR_BASE/g2-plans"
    mkdir -p "$plans_dir"
    local sid="g2-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Build a transcript containing the full 10-heading report in assistant text.
    local transcript="$TMPDIR_BASE/g2-transcript.jsonl"
    local report_text; report_text="$(full_canonical_report_text "$sid")"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G2: env-file + all 10 headings in transcript → exit 0"
    else
        fail "G2: expected exit 0 (all headings present), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G3 (replacement): env-file with empty object {} (no `reported` field needed
#                   under new contract, but also no report heading) →
#                   need to test: file exists + parses but transcript lacks header
#                   → exit 0 (header absent = guard not yet applicable per G20).
# This test guards the absent-header path with a minimal env-file.
# ---------------------------------------------------------------------------
test_G3_empty_env_object_no_header() {
    require_hook "G3_empty_env_object_no_header" || return

    local plans_dir="$TMPDIR_BASE/g3-plans"
    mkdir -p "$plans_dir"
    local sid="g3-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    printf '{}' > "$envfile"

    local transcript="$TMPDIR_BASE/g3-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "no header here"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G3: empty env-file {} + no header in transcript → exit 0 (guard not applicable)"
    else
        fail "G3: expected exit 0, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G4: stop_hook_active: true → exit 0 (guard)
# UNCHANGED
# ---------------------------------------------------------------------------
test_G4_stop_hook_active() {
    require_hook "G4_stop_hook_active" || return

    local plans_dir="$TMPDIR_BASE/g4-plans"
    mkdir -p "$plans_dir"
    local sid="g4-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g4-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "No block here."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"stop_hook_active":true,"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G4: stop_hook_active:true → exit 0 (guard)"
    else
        fail "G4: expected exit 0 for stop_hook_active:true, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G6: env-file present but malformed JSON → exit 0 (fail-open)
# UNCHANGED
# ---------------------------------------------------------------------------
test_G6_envfile_malformed_json() {
    require_hook "G6_envfile_malformed_json" || return

    local plans_dir="$TMPDIR_BASE/g6-plans"
    mkdir -p "$plans_dir"
    local sid="g6-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    printf 'THIS IS NOT JSON {{{' > "$envfile"

    local transcript="$TMPDIR_BASE/g6-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "No block here either."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G6: env-file malformed JSON → exit 0 (fail-open)"
    else
        fail "G6: expected exit 0 (fail-open) for malformed env-file, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G7 (rewritten): env-file + `## Final Report — <sid>` present + 8 of 9 `###`
#                 headings present (one missing) → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G7_header_present_subheading_missing() {
    require_hook "G7_header_present_subheading_missing" || return

    local plans_dir="$TMPDIR_BASE/g7-plans"
    mkdir -p "$plans_dir"
    local sid="g7-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Build report with `### Next Tasks` omitted.
    local transcript="$TMPDIR_BASE/g7-transcript.jsonl"
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #(none): (none)
### Worktree
- Branch: (none)
### Backup
- Manifest: (none)
### Closed Issue Outcomes
- (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
### Bugs Found
- (none)
### Related Tasks
- (none)
EOF
)"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G7: header + 8/9 ### headings (missing Next Tasks) → exit 2 + decision:block"
    else
        fail "G7: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G8 (rewritten): env-file with legacy CLAUDE_CODE_RESTART_REQUIRED:"yes" +
#                 header present + missing `###` heading → exit 2 + reason
#                 includes "Claude Code restart: required"
# ---------------------------------------------------------------------------
test_G8_legacy_key_yes() {
    require_hook "G8_legacy_key_yes" || return

    local plans_dir="$TMPDIR_BASE/g8-plans"
    mkdir -p "$plans_dir"
    local sid="g8-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    cat > "$envfile" <<'EOF'
{
  "CLAUDE_CODE_RESTART_REQUIRED": "yes",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "not_required",
  "OS_REBOOT_REASON": ""
}
EOF

    # Transcript has header but is missing the required `###` headings.
    local transcript="$TMPDIR_BASE/g8-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
Done."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            const ok = obj.decision==='block' &&
                       typeof obj.reason === 'string' &&
                       obj.reason.includes('Claude Code restart: required');
            process.exit(ok ? 0 : 1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G8: legacy CLAUDE_CODE_RESTART_REQUIRED=yes + missing headings → reason includes 'Claude Code restart: required'"
    else
        fail "G8: expected exit 2 + reason 'Claude Code restart: required', got code=$code out=$(printf '%s' "$out" | head -c 300)"
    fi
}

# ---------------------------------------------------------------------------
# G16 (new): env-file + `## Final Report — <sid>` only (no `###` headings) → exit 2
# ---------------------------------------------------------------------------
test_G16_only_header_no_subheadings() {
    require_hook "G16_only_header_no_subheadings" || return

    local plans_dir="$TMPDIR_BASE/g16-plans"
    mkdir -p "$plans_dir"
    local sid="g16-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g16-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
(body without any ### headings)"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G16: header only, no ### headings → exit 2 + decision:block"
    else
        fail "G16: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G17 (new): env-file + header + 8 of 9 `###` headings (missing `### Bugs Found`)
#            → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G17_nine_of_ten_headings() {
    require_hook "G17_nine_of_ten_headings" || return

    local plans_dir="$TMPDIR_BASE/g17-plans"
    mkdir -p "$plans_dir"
    local sid="g17-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g17-transcript.jsonl"
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #(none): (none)
### Worktree
- Branch: (none)
### Backup
- Manifest: (none)
### Closed Issue Outcomes
- (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
### Related Tasks
- (none)
### Next Tasks
- (none)
EOF
)"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G17: header + 8/9 ### (missing Bugs Found) → exit 2 + decision:block"
    else
        fail "G17: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G18 (new): env-file + all 10 headings in scrambled order → exit 0
# (order-agnostic — only presence matters)
# ---------------------------------------------------------------------------
test_G18_all_ten_reordered() {
    require_hook "G18_all_ten_reordered" || return

    local plans_dir="$TMPDIR_BASE/g18-plans"
    mkdir -p "$plans_dir"
    local sid="g18-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g18-transcript.jsonl"
    # `## Final Report` first, then ### headings in scrambled order.
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Next Tasks
- (none)
### Closed Issues
- (none)
### Bugs Found
- (none)
### Merged PR
- PR #(none): (none)
### Worktree
- Branch: (none)
### Related Tasks
- (none)
### Backup
- Manifest: (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
### Closed Issue Outcomes
- (none)
EOF
)"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G18: all 10 headings in scrambled order → exit 0 (order-agnostic)"
    else
        fail "G18: expected exit 0 (all headings present), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G19 (new): env-file + all 10 headings + residual `<PR_NUMBER>` token in
#            post-header region → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G19_residual_tokens() {
    require_hook "G19_residual_tokens" || return

    local plans_dir="$TMPDIR_BASE/g19-plans"
    mkdir -p "$plans_dir"
    local sid="g19-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g19-transcript.jsonl"
    # Replace `(none)` for PR number with literal `<PR_NUMBER>` token
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #<PR_NUMBER>: (none)
- URL: (none)
- State: (none)
### Worktree
- Branch: (none)
### Backup
- Manifest: (none)
### Closed Issue Outcomes
- (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
- VS Code reload: not_required
- Installer rerun: not_required
- OS reboot: not_required
### Bugs Found
- (none)
### Related Tasks
- (none)
### Next Tasks
- (none)
EOF
)"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G19: all 10 headings + residual <PR_NUMBER> token → exit 2 + decision:block"
    else
        fail "G19: expected exit 2 + decision:block (residual token), got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G20 (new): env-file present + `## Final Report — <sid>` absent from
#            transcript → exit 0 (guard not yet applicable; report not started)
# ---------------------------------------------------------------------------
test_G20_header_absent_no_block() {
    require_hook "G20_header_absent_no_block" || return

    local plans_dir="$TMPDIR_BASE/g20-plans"
    mkdir -p "$plans_dir"
    local sid="g20-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g20-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "I am still working on the task. No final report yet."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G20: env-file + no Final Report header in transcript → exit 0 (guard not applicable)"
    else
        fail "G20: expected exit 0 (header absent), got $code"
    fi
}

# ---------------------------------------------------------------------------
# I1: settings.json Stop hooks array contains stop-final-report-guard.js
# UNCHANGED
# ---------------------------------------------------------------------------
test_I1_settings_json_stop_hook() {
    if [ ! -f "$SETTINGS_JSON" ]; then
        skip "I1_settings_json_stop_hook (settings.json not found at $SETTINGS_JSON)"
        return
    fi
    if [ ! -f "$HOOK_JS" ]; then
        skip "I1_settings_json_stop_hook (hook not implemented yet)"
        return
    fi

    local settings_node; settings_node="$(node_path "$SETTINGS_JSON")"
    local found
    found="$(node -e "
        const path=require('path');
        const s = require(path.resolve(process.argv[1]));
        const hooks = (s.hooks && s.hooks.Stop) || [];
        let found = false;
        for (const group of hooks) {
            for (const h of (group.hooks || [])) {
                if (h.command && h.command.includes('stop-final-report-guard.js')) {
                    found = true;
                }
            }
        }
        process.stdout.write(found ? 'yes' : 'no');
    " -- "$settings_node" 2>/dev/null)"

    if [ "$found" = "yes" ]; then
        pass "I1: settings.json Stop hooks array contains stop-final-report-guard.js"
    else
        fail "I1: settings.json Stop hooks does NOT contain stop-final-report-guard.js"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_G1_envfile_absent
test_G2_all_headings_present_passes
test_G3_empty_env_object_no_header
test_G4_stop_hook_active
test_G6_envfile_malformed_json
test_G7_header_present_subheading_missing
test_G8_legacy_key_yes
test_G16_only_header_no_subheadings
test_G17_nine_of_ten_headings
test_G18_all_ten_reordered
test_G19_residual_tokens
test_G20_header_absent_no_block
test_I1_settings_json_stop_hook

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
