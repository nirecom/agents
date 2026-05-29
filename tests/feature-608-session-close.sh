#!/bin/bash
# tests/feature-608-session-close.sh
#
# Issue #608 — /session-close orchestration skill + closed_issue_outcomes section.
#
# Tests:
#   - bin/worktree-final-report.js  --outcome-file flag + closedIssueOutcomeLines ctx
#   - hooks/lib/final-report-schema.js: "### Closed Issue Outcomes" section
#   - skills/session-close/SKILL.md exists
#   - skills/worktree-end/SKILL.md no longer has Step 7
#   - skills/issue-close-finalize/SKILL.md has Step L
#   - CLAUDE.md routes to /session-close
#
# Tests for features not yet implemented are expected to fail until code
# changes land; structural tests SKIP+PASS when the source file does not
# exist at all.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

REPORT_JS="${_AGENTS_DIR_NODE}/bin/worktree-final-report.js"
SCHEMA_JS="${_AGENTS_DIR_NODE}/hooks/lib/final-report-schema.js"

PASS=0
FAIL=0
SKIP=0
unset AGENTS_CONFIG_DIR

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f608-'+process.pid).replace(/\\\\/g,'/');
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

require_report_bin() {
    if [ ! -f "$REPORT_JS" ]; then
        skip "$1 (bin/worktree-final-report.js missing)"
        return 1
    fi
    return 0
}

require_schema() {
    if [ ! -f "$SCHEMA_JS" ]; then
        skip "$1 (hooks/lib/final-report-schema.js missing)"
        return 1
    fi
    return 0
}

# Write full env file (sufficient for happy paths)
write_full_env() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "PR_NUMBER": "42",
  "PR_TITLE": "Fix #608",
  "PR_URL": "https://github.com/x/y/pull/42",
  "PR_STATE": "MERGED",
  "BRANCH": "fix/fix-608",
  "WORKTREE_PATH": "/tmp/wt",
  "CREATED_DATE": "2026-05-29",
  "BACKUP_MANIFEST_PATH": "/tmp/backup.json",
  "BRANCH_DELETED": "fix/fix-608",
  "CC_RESTART_REQUIRED": "not_required",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "OS_REBOOT_REQUIRED": "not_required"
}
EOF
}

# Write a minimal env file with empty PR fields (off-path scenario)
write_minimal_env() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "PR_NUMBER": "42",
  "PR_TITLE": "Fix #608",
  "PR_URL": "https://github.com/x/y/pull/42",
  "PR_STATE": "MERGED",
  "BRANCH": "",
  "WORKTREE_PATH": "",
  "CREATED_DATE": "",
  "BACKUP_MANIFEST_PATH": "",
  "BRANCH_DELETED": ""
}
EOF
}

# Write env file with all PR fields empty
write_no_pr_env() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "PR_NUMBER": "",
  "PR_TITLE": "",
  "PR_URL": "",
  "PR_STATE": "",
  "BRANCH": "",
  "WORKTREE_PATH": "",
  "CREATED_DATE": "",
  "BACKUP_MANIFEST_PATH": "",
  "BRANCH_DELETED": ""
}
EOF
}

write_intent_with_issue() {
    local path="$1" num="$2"
    printf '# Intent\n\n## Issues\n- %s\n' "$num" > "$path"
}

write_intent_no_issues() {
    local path="$1"
    printf '# Intent\n\nSomething else.\n' > "$path"
}

# Run renderer: positional args, --outcome-file flag, no notes file (empty positional)
# Args: intent_path env_file outcome_file sid -> prints stdout
run_report_with_outcome() {
    local intent="$1" envfile="$2" outcome="$3" sid="$4"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "" "$sid" -- \
        --env-file "$envfile" --outcome-file "$outcome" 2>/dev/null
}

run_report_with_outcome_capture_all() {
    local intent="$1" envfile="$2" outcome="$3" sid="$4"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "" "$sid" -- \
        --env-file "$envfile" --outcome-file "$outcome" 2>&1
}

run_report_no_outcome() {
    local intent="$1" envfile="$2" sid="$3"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "" "$sid" -- \
        --env-file "$envfile" 2>/dev/null
}

run_report_exit() {
    local intent="$1" envfile="$2" outcome="$3" sid="$4"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "" "$sid" -- \
        --env-file "$envfile" --outcome-file "$outcome" >/dev/null 2>&1
    echo "$?"
}

SENTINEL='<<WORKFLOW_MARK_STEP_final_report_complete>>'

# ============ T-series: Renderer outcome-file integration ============

test_T1_worktree_succeeded() {
    require_report_bin "T1_worktree_succeeded" || return
    local intent="$TMPDIR_BASE/t1-intent.md"
    local envfile="$TMPDIR_BASE/t1-env.json"
    local outcome="$TMPDIR_BASE/t1-outcome.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    cat > "$outcome" <<'EOF'
{"issues":[{"issueNumber":608,"state":"succeeded","historyEntry":"appended","issueClosed":"closed","sentinelsPosted":"posted","wipCleared":"cleared"}]}
EOF
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t1")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t1")"
    local expected_line='- #608: succeeded (history: appended, closed: closed, sentinels: posted, wip: cleared)'

    if [ "$code" = "0" ] \
       && echo "$out" | grep -q "^### Closed Issue Outcomes$" \
       && echo "$out" | grep -qF -- "$expected_line" \
       && echo "$out" | grep -qF "$SENTINEL"; then
        pass "T1_worktree_succeeded: Closed Issue Outcomes rendered with expected per-issue line"
    else
        fail "T1_worktree_succeeded: code=$code, missing section/line/sentinel
--- output ---
$out"
    fi
}

test_T2_off_path() {
    require_report_bin "T2_off_path" || return
    local intent="$TMPDIR_BASE/t2-intent.md"
    local envfile="$TMPDIR_BASE/t2-env.json"
    local outcome="$TMPDIR_BASE/t2-outcome.json"
    write_intent_with_issue "$intent" 608
    write_minimal_env "$envfile"
    cat > "$outcome" <<'EOF'
{"issues":[{"issueNumber":608,"state":"succeeded","historyEntry":"appended","issueClosed":"closed","sentinelsPosted":"posted","wipCleared":"cleared"}]}
EOF
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t2")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t2")"
    local expected_line='- #608: succeeded (history: appended, closed: closed, sentinels: posted, wip: cleared)'

    if [ "$code" = "0" ] \
       && echo "$out" | grep -q "^### Closed Issue Outcomes$" \
       && echo "$out" | grep -qF -- "$expected_line" \
       && echo "$out" | grep -qF -- "- Branch: (none)"; then
        pass "T2_off_path: Outcomes line present with minimal env"
    else
        fail "T2_off_path: code=$code
$out"
    fi
}

test_T2b_off_path_no_pr() {
    require_report_bin "T2b_off_path_no_pr" || return
    local intent="$TMPDIR_BASE/t2b-intent.md"
    local envfile="$TMPDIR_BASE/t2b-env.json"
    local outcome="$TMPDIR_BASE/t2b-outcome.json"
    write_intent_no_issues "$intent"
    write_no_pr_env "$envfile"
    printf '{"issues":[]}\n' > "$outcome"
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t2b")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t2b")"

    if [ "$code" = "0" ] \
       && echo "$out" | grep -q "^### Merged PR$" \
       && echo "$out" | grep -qF -- "(none)"; then
        pass "T2b_off_path_no_pr: empty PR fields render as (none), exit 0"
    else
        fail "T2b_off_path_no_pr: code=$code
$out"
    fi
}

test_T2c_off_path_non_github() {
    require_report_bin "T2c_off_path_non_github" || return
    local intent="$TMPDIR_BASE/t2c-intent.md"
    local envfile="$TMPDIR_BASE/t2c-env.json"
    local outcome="$TMPDIR_BASE/t2c-outcome.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    cat > "$outcome" <<'EOF'
{"issues":[{"issueNumber":608,"state":"skipped-non-github","historyEntry":"skipped","issueClosed":"skipped","sentinelsPosted":"skipped","wipCleared":"skipped"}]}
EOF
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t2c")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t2c")"
    local expected_line='- #608: skipped-non-github (history: skipped, closed: skipped, sentinels: skipped, wip: skipped)'

    if [ "$code" = "0" ] \
       && echo "$out" | grep -q "^### Closed Issue Outcomes$" \
       && echo "$out" | grep -qF -- "$expected_line"; then
        pass "T2c_off_path_non_github: skipped-non-github line rendered"
    else
        fail "T2c_off_path_non_github: code=$code
$out"
    fi
}

test_T3_closes_issues_empty() {
    require_report_bin "T3_closes_issues_empty" || return
    local intent="$TMPDIR_BASE/t3-intent.md"
    local envfile="$TMPDIR_BASE/t3-env.json"
    local outcome="$TMPDIR_BASE/t3-outcome.json"
    write_intent_no_issues "$intent"
    write_full_env "$envfile"
    printf '{"issues":[]}\n' > "$outcome"
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t3")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t3")"

    local closed_block outcomes_block
    closed_block="$(echo "$out" | awk '/^### Closed Issues$/{flag=1;next} /^### /{flag=0} flag')"
    outcomes_block="$(echo "$out" | awk '/^### Closed Issue Outcomes$/{flag=1;next} /^### /{flag=0} flag')"

    if [ "$code" = "0" ] \
       && echo "$closed_block" | grep -qF -- "- (none)" \
       && echo "$outcomes_block" | grep -qF -- "- (none)" \
       && echo "$out" | grep -qF "$SENTINEL"; then
        pass "T3_closes_issues_empty: both Closed Issues and Closed Issue Outcomes render '- (none)'"
    else
        fail "T3_closes_issues_empty: code=$code
--- closed_block ---
$closed_block
--- outcomes_block ---
$outcomes_block"
    fi
}

test_T4_fail_open() {
    require_report_bin "T4_fail_open" || return
    local intent="$TMPDIR_BASE/t4-intent.md"
    local envfile="$TMPDIR_BASE/t4-env.json"
    local outcome="$TMPDIR_BASE/t4-outcome.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    cat > "$outcome" <<'EOF'
{"issues":[{"issueNumber":608,"state":"partial-failure","historyEntry":"failed","issueClosed":"closed","sentinelsPosted":"posted","wipCleared":"cleared"}]}
EOF
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t4")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t4")"
    local expected_line='- #608: partial-failure (history: failed, closed: closed, sentinels: posted, wip: cleared)'

    if [ "$code" = "0" ] && echo "$out" | grep -qF -- "$expected_line"; then
        pass "T4_fail_open: partial-failure line rendered, exit 0"
    else
        fail "T4_fail_open: code=$code
$out"
    fi
}

test_T5_non_github() {
    require_report_bin "T5_non_github" || return
    local intent="$TMPDIR_BASE/t5-intent.md"
    local envfile="$TMPDIR_BASE/t5-env.json"
    local outcome="$TMPDIR_BASE/t5-outcome.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    cat > "$outcome" <<'EOF'
{"issues":[{"issueNumber":608,"state":"skipped-non-github","historyEntry":"skipped","issueClosed":"skipped","sentinelsPosted":"skipped","wipCleared":"skipped"}]}
EOF
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t5")"
    local expected_line='- #608: skipped-non-github (history: skipped, closed: skipped, sentinels: skipped, wip: skipped)'

    if echo "$out" | grep -qF -- "$expected_line"; then
        pass "T5_non_github: skipped-non-github line rendered"
    else
        fail "T5_non_github: expected line missing
$out"
    fi
}

# ============ T6-T7: Schema unit tests ============

test_T6_schema_section_present() {
    require_schema "T6_schema_section_present" || return
    run_with_timeout 120 node -e "
        const s=require('${SCHEMA_JS}');
        const h=s.getSectionHeadings('SID');
        process.exit(h.includes('### Closed Issue Outcomes') ? 0 : 1);
    " >/dev/null 2>&1
    local code=$?
    if [ "$code" = "0" ]; then
        pass "T6_schema_section_present: getSectionHeadings includes '### Closed Issue Outcomes'"
    else
        fail "T6_schema_section_present: heading not present in schema"
    fi
}

test_T7_schema_probes_aggregated() {
    require_schema "T7_schema_probes_aggregated" || return
    run_with_timeout 120 node -e "
        const s=require('${SCHEMA_JS}');
        const p=s.getProbes();
        process.exit(Array.isArray(p) && p.some(x => typeof x === 'string' && x.startsWith('- ')) ? 0 : 1);
    " >/dev/null 2>&1
    local code=$?
    if [ "$code" = "0" ]; then
        pass "T7_schema_probes_aggregated: getProbes returns array containing bullet probes"
    else
        fail "T7_schema_probes_aggregated: probes do not look aggregated"
    fi
}

# ============ T8-T10: outcome-file fallback behavior ============

test_T8_outcome_file_missing_falls_back() {
    require_report_bin "T8_outcome_file_missing_falls_back" || return
    local intent="$TMPDIR_BASE/t8-intent.md"
    local envfile="$TMPDIR_BASE/t8-env.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    # Outcome file path that does not exist — use absolute non-existent path
    local outcome_n
    if command -v cygpath >/dev/null 2>&1; then
        outcome_n="$(cygpath -m "$TMPDIR_BASE")/nonexistent/outcome.json"
    else
        outcome_n="$TMPDIR_BASE/nonexistent/outcome.json"
    fi

    local out; out="$(run_report_with_outcome "$intent_n" "$envfile_n" "$outcome_n" "sess-t8")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t8")"

    if [ "$code" = "0" ] && echo "$out" | grep -qF -- "- (outcome data not found — investigate)"; then
        pass "T8_outcome_file_missing_falls_back: missing outcome → fallback line, exit 0"
    else
        fail "T8_outcome_file_missing_falls_back: code=$code
$out"
    fi
}

test_T9_outcome_file_malformed() {
    require_report_bin "T9_outcome_file_malformed" || return
    local intent="$TMPDIR_BASE/t9-intent.md"
    local envfile="$TMPDIR_BASE/t9-env.json"
    local outcome="$TMPDIR_BASE/t9-outcome.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    printf '{bad json}' > "$outcome"
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"
    local outcome_n; outcome_n="$(node_path "$outcome")"

    local merged; merged="$(run_report_with_outcome_capture_all "$intent_n" "$envfile_n" "$outcome_n" "sess-t9")"
    local code; code="$(run_report_exit "$intent_n" "$envfile_n" "$outcome_n" "sess-t9")"

    if [ "$code" = "0" ] \
       && echo "$merged" | grep -qF -- "- (outcome data not found — investigate)" \
       && echo "$merged" | grep -q "WARN"; then
        pass "T9_outcome_file_malformed: malformed JSON → fallback line + WARN on stderr, exit 0"
    else
        fail "T9_outcome_file_malformed: code=$code
$merged"
    fi
}

test_T10_no_outcome_file_arg() {
    require_report_bin "T10_no_outcome_file_arg" || return
    local intent="$TMPDIR_BASE/t10-intent.md"
    local envfile="$TMPDIR_BASE/t10-env.json"
    write_intent_with_issue "$intent" 608
    write_full_env "$envfile"
    local intent_n; intent_n="$(node_path "$intent")"
    local envfile_n; envfile_n="$(node_path "$envfile")"

    local out; out="$(run_report_no_outcome "$intent_n" "$envfile_n" "sess-t10")"
    run_with_timeout 120 node "$REPORT_JS" "$intent_n" "" "sess-t10" -- --env-file "$envfile_n" >/dev/null 2>&1
    local code=$?

    if [ "$code" = "0" ] && echo "$out" | grep -qF -- "- (outcome data not found — investigate)"; then
        pass "T10_no_outcome_file_arg: --outcome-file omitted → fallback line, exit 0"
    else
        fail "T10_no_outcome_file_arg: code=$code
$out"
    fi
}

# ============ S-series: Static structural tests ============

test_S1_session_close_skill_exists() {
    local f="${AGENTS_DIR}/skills/session-close/SKILL.md"
    if [ -f "$f" ]; then
        pass "S1_session_close_skill_exists: skills/session-close/SKILL.md present"
    else
        skip "S1_session_close_skill_exists (source not yet implemented)"
    fi
}

test_S2_worktree_end_no_step7() {
    local f="${AGENTS_DIR}/skills/worktree-end/SKILL.md"
    if [ ! -f "$f" ]; then
        skip "S2_worktree_end_no_step7 (skills/worktree-end/SKILL.md missing — source not yet implemented)"
        return
    fi
    local n; n="$(grep "### Step 7" "$f" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" = "0" ]; then
        pass "S2_worktree_end_no_step7: no '### Step 7' headings in worktree-end SKILL.md"
    else
        fail "S2_worktree_end_no_step7: expected 0 '### Step 7' headings, found $n"
    fi
}

test_S3_claude_md_routes_session_close() {
    local f="${AGENTS_DIR}/CLAUDE.md"
    if [ ! -f "$f" ]; then
        skip "S3_claude_md_routes_session_close (CLAUDE.md missing)"
        return
    fi
    if grep -q "/session-close" "$f"; then
        pass "S3_claude_md_routes_session_close: CLAUDE.md references /session-close"
    else
        fail "S3_claude_md_routes_session_close: /session-close not found in CLAUDE.md"
    fi
}

test_S4_issue_close_finalize_has_step_l() {
    local f="${AGENTS_DIR}/skills/issue-close-finalize/SKILL.md"
    if [ ! -f "$f" ]; then
        skip "S4_issue_close_finalize_has_step_l (skills/issue-close-finalize/SKILL.md missing)"
        return
    fi
    if grep -q "## Step L" "$f"; then
        pass "S4_issue_close_finalize_has_step_l: '## Step L' present"
    else
        fail "S4_issue_close_finalize_has_step_l: '## Step L' not found"
    fi
}

test_S5_worktree_end_no_final_report_emit() {
    local f="${AGENTS_DIR}/skills/worktree-end/SKILL.md"
    if [ ! -f "$f" ]; then
        skip "S5_worktree_end_no_final_report_emit (skills/worktree-end/SKILL.md missing)"
        return
    fi
    local n; n="$(grep "worktree-final-report.js" "$f" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" = "0" ]; then
        pass "S5_worktree_end_no_final_report_emit: worktree-end no longer references worktree-final-report.js"
    else
        fail "S5_worktree_end_no_final_report_emit: expected 0 references, found $n"
    fi
}

# ============ Run all ============

test_T1_worktree_succeeded
test_T2_off_path
test_T2b_off_path_no_pr
test_T2c_off_path_non_github
test_T3_closes_issues_empty
test_T4_fail_open
test_T5_non_github
test_T6_schema_section_present
test_T7_schema_probes_aggregated
test_T8_outcome_file_missing_falls_back
test_T9_outcome_file_malformed
test_T10_no_outcome_file_arg

test_S1_session_close_skill_exists
test_S2_worktree_end_no_step7
test_S3_claude_md_routes_session_close
test_S4_issue_close_finalize_has_step_l
test_S5_worktree_end_no_final_report_emit

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
