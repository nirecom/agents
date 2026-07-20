#!/bin/bash
# tests/feature-1257-session-close-wf-meta.sh
# Tests: bin/session-close-build-env.js, bin/issue-close-write-outcome.js, skills/session-close/SKILL.md
# Tags: session-close, wf-meta, env-json, outcome, scope:issue-specific
#
# Issue #1257 — /session-close WF-META path: planning sessions with no PR/worktree.
# --wf-meta flag in session-close-build-env.js writes env JSON with all PR fields empty.
# --wf-meta flag in issue-close-write-outcome.js writes skipped_wf_meta entries.
# SKILL.md documents the WF-META detection path.
#
# T-series (T1-T6): exercise --wf-meta flags → expected FAIL until implementation.
# T7: regression guard for normal mode (no --wf-meta) → expected PASS.
# S-series (S1-S5): static SKILL.md structure assertions → expected FAIL until implementation.
#
# L3 gap:
#   A real /session-close invocation against a WF-META session would additionally verify:
#   - SC-1 detects WF-META before ENFORCE_WORKTREE check (live orchestration path)
#   - The Final Report renders correctly with all PR fields as "(none)"
#   - No gh CLI call is made (no PR attempted)
#   - The session-close-worker skips /issue-close-finalize entirely
#   These require a full claude -p E2E session and are gated on RUN_TL3.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

BUILD_ENV_JS="${_AGENTS_DIR_NODE}/bin/session-close-build-env.js"
WRITE_OUTCOME_JS="${_AGENTS_DIR_NODE}/bin/issue-close-write-outcome.js"
SKILL_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f1257-'+process.pid).replace(/\\\\/g,'/');
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

# ============ T1: --wf-meta <outfile> → exit 0, valid JSON, PR fields empty, stdout ENV_FILE= ============

test_T1_build_env_wf_meta_exit0_and_json() {
    local outfile="${TMPDIR_BASE}/t1-env.json"
    local node_outfile
    if command -v cygpath >/dev/null 2>&1; then
        node_outfile="$(cygpath -m "$outfile")"
    else
        node_outfile="$outfile"
    fi
    local stdout_out
    stdout_out="$(run_with_timeout 30 node "$BUILD_ENV_JS" --wf-meta "$node_outfile" 2>/dev/null)"
    local exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "T1_build_env_wf_meta: expected exit 0, got $exit_code"
        return
    fi
    if [ ! -f "$outfile" ]; then
        fail "T1_build_env_wf_meta: output file not created at $outfile"
        return
    fi
    # Check ENV_FILE= prefix on stdout
    if ! echo "$stdout_out" | grep -q "^ENV_FILE="; then
        fail "T1_build_env_wf_meta: stdout does not contain ENV_FILE= line (got: $stdout_out)"
        return
    fi
    # Validate JSON
    local valid
    valid="$(run_with_timeout 30 node -e "
        try {
            const d = require('fs').readFileSync($(node -e "process.stdout.write(JSON.stringify(require('path').resolve('$outfile')))"), 'utf8');
            JSON.parse(d);
            process.stdout.write('ok');
        } catch(e) { process.stdout.write('invalid: '+e.message); }
    " 2>/dev/null)"
    if [ "$valid" = "ok" ]; then
        pass "T1_build_env_wf_meta: exit 0, valid JSON, ENV_FILE= on stdout"
    else
        fail "T1_build_env_wf_meta: JSON invalid or file not readable: $valid"
    fi
}

# ============ T2: --wf-meta (no outfile) → exit 1 + stderr usage message ============

test_T2_build_env_wf_meta_no_outfile_exit1() {
    local stderr_out
    stderr_out="$(run_with_timeout 30 node "$BUILD_ENV_JS" --wf-meta 2>&1 >/dev/null)"
    local exit_code=$?
    if [ "$exit_code" != "1" ]; then
        fail "T2_build_env_wf_meta_no_outfile: expected exit 1, got $exit_code"
        return
    fi
    if ! echo "$stderr_out" | grep -qi "usage"; then
        fail "T2_build_env_wf_meta_no_outfile: expected usage message on stderr (got: $stderr_out)"
        return
    fi
    pass "T2_build_env_wf_meta_no_outfile: exit 1 + usage on stderr"
}

# ============ T3: --wf-meta '[1257]' <outfile> → exit 0, state skipped_wf_meta, subfields "skipped" ============

test_T3_write_outcome_wf_meta_single() {
    local outfile="${TMPDIR_BASE}/t3-outcome.json"
    local node_outfile
    if command -v cygpath >/dev/null 2>&1; then
        node_outfile="$(cygpath -m "$outfile")"
    else
        node_outfile="$outfile"
    fi
    run_with_timeout 30 node "$WRITE_OUTCOME_JS" --wf-meta '[1257]' "$node_outfile" >/dev/null 2>&1
    local exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "T3_write_outcome_wf_meta_single: expected exit 0, got $exit_code"
        return
    fi
    if [ ! -f "$outfile" ]; then
        fail "T3_write_outcome_wf_meta_single: output file not created"
        return
    fi
    local result
    result="$(run_with_timeout 30 node -e "
        const d = JSON.parse(require('fs').readFileSync($(node -e "process.stdout.write(JSON.stringify(require('path').resolve('$outfile')))"), 'utf8'));
        const issues = d.issues || [];
        const e = issues.find(x => x.issueNumber === 1257);
        if (!e) { process.stdout.write('no entry for 1257'); process.exit(1); }
        if (e.state !== 'skipped_wf_meta') { process.stdout.write('wrong state: '+e.state); process.exit(1); }
        const fields = ['historyEntry','issueClosed','sentinelsPosted','wipCleared'];
        for (const f of fields) {
            if (e[f] !== 'skipped') { process.stdout.write('field '+f+' is '+e[f]+', expected skipped'); process.exit(1); }
        }
        process.stdout.write('ok');
    " 2>/dev/null)"
    if [ "$result" = "ok" ]; then
        pass "T3_write_outcome_wf_meta_single: issue 1257 state=skipped_wf_meta, all subfields=skipped"
    else
        fail "T3_write_outcome_wf_meta_single: $result"
    fi
}

# ============ T4: --wf-meta '[1257,1258]' <outfile> → 2 entries both skipped_wf_meta ============

test_T4_write_outcome_wf_meta_multi() {
    local outfile="${TMPDIR_BASE}/t4-outcome.json"
    local node_outfile
    if command -v cygpath >/dev/null 2>&1; then
        node_outfile="$(cygpath -m "$outfile")"
    else
        node_outfile="$outfile"
    fi
    run_with_timeout 30 node "$WRITE_OUTCOME_JS" --wf-meta '[1257,1258]' "$node_outfile" >/dev/null 2>&1
    local exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "T4_write_outcome_wf_meta_multi: expected exit 0, got $exit_code"
        return
    fi
    if [ ! -f "$outfile" ]; then
        fail "T4_write_outcome_wf_meta_multi: output file not created"
        return
    fi
    local result
    result="$(run_with_timeout 30 node -e "
        const d = JSON.parse(require('fs').readFileSync($(node -e "process.stdout.write(JSON.stringify(require('path').resolve('$outfile')))"), 'utf8'));
        const issues = d.issues || [];
        if (issues.length !== 2) { process.stdout.write('expected 2 entries, got '+issues.length); process.exit(1); }
        for (const e of issues) {
            if (e.state !== 'skipped_wf_meta') { process.stdout.write('issue '+e.issueNumber+' has wrong state: '+e.state); process.exit(1); }
        }
        const nums = issues.map(x => x.issueNumber).sort((a,b)=>a-b);
        if (nums[0] !== 1257 || nums[1] !== 1258) { process.stdout.write('wrong issue numbers: '+JSON.stringify(nums)); process.exit(1); }
        process.stdout.write('ok');
    " 2>/dev/null)"
    if [ "$result" = "ok" ]; then
        pass "T4_write_outcome_wf_meta_multi: 2 entries (1257, 1258) both state=skipped_wf_meta"
    else
        fail "T4_write_outcome_wf_meta_multi: $result"
    fi
}

# ============ T5: --wf-meta '[]' <outfile> → {"issues":[]} no error ============

test_T5_write_outcome_wf_meta_empty() {
    local outfile="${TMPDIR_BASE}/t5-outcome.json"
    local node_outfile
    if command -v cygpath >/dev/null 2>&1; then
        node_outfile="$(cygpath -m "$outfile")"
    else
        node_outfile="$outfile"
    fi
    run_with_timeout 30 node "$WRITE_OUTCOME_JS" --wf-meta '[]' "$node_outfile" >/dev/null 2>&1
    local exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "T5_write_outcome_wf_meta_empty: expected exit 0, got $exit_code"
        return
    fi
    if [ ! -f "$outfile" ]; then
        fail "T5_write_outcome_wf_meta_empty: output file not created"
        return
    fi
    local result
    result="$(run_with_timeout 30 node -e "
        const d = JSON.parse(require('fs').readFileSync($(node -e "process.stdout.write(JSON.stringify(require('path').resolve('$outfile')))"), 'utf8'));
        const issues = d.issues || [];
        if (issues.length !== 0) { process.stdout.write('expected 0 entries, got '+issues.length); process.exit(1); }
        process.stdout.write('ok');
    " 2>/dev/null)"
    if [ "$result" = "ok" ]; then
        pass "T5_write_outcome_wf_meta_empty: empty array → {\"issues\":[]} written"
    else
        fail "T5_write_outcome_wf_meta_empty: $result"
    fi
}

# ============ T6: env JSON from --wf-meta has BRANCH/PR_NUMBER/PR_TITLE/PR_URL/PR_STATE all empty string ============

test_T6_build_env_wf_meta_pr_fields_empty() {
    local outfile="${TMPDIR_BASE}/t6-env.json"
    local node_outfile
    if command -v cygpath >/dev/null 2>&1; then
        node_outfile="$(cygpath -m "$outfile")"
    else
        node_outfile="$outfile"
    fi
    run_with_timeout 30 node "$BUILD_ENV_JS" --wf-meta "$node_outfile" >/dev/null 2>&1
    local exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "T6_build_env_wf_meta_pr_fields_empty: build-env --wf-meta exited $exit_code (not yet implemented?)"
        return
    fi
    if [ ! -f "$outfile" ]; then
        fail "T6_build_env_wf_meta_pr_fields_empty: output file not created"
        return
    fi
    local result
    result="$(run_with_timeout 30 node -e "
        const d = JSON.parse(require('fs').readFileSync($(node -e "process.stdout.write(JSON.stringify(require('path').resolve('$outfile')))"), 'utf8'));
        const required = ['BRANCH','PR_NUMBER','PR_TITLE','PR_URL','PR_STATE'];
        for (const k of required) {
            if (!(k in d)) { process.stdout.write('missing field: '+k); process.exit(1); }
            if (d[k] !== '') { process.stdout.write('field '+k+' is not empty string: '+JSON.stringify(d[k])); process.exit(1); }
        }
        process.stdout.write('ok');
    " 2>/dev/null)"
    if [ "$result" = "ok" ]; then
        pass "T6_build_env_wf_meta_pr_fields_empty: BRANCH/PR_NUMBER/PR_TITLE/PR_URL/PR_STATE all empty string"
    else
        fail "T6_build_env_wf_meta_pr_fields_empty: $result"
    fi
}

# ============ T7: regression guard — normal mode (no --wf-meta) still dispatches correctly ============
# Source not yet modified, so T7 tests existing behavior which should PASS.
# In the test environment, `gh pr list` may fail (no PR or not in git repo).
# We verify: argv[2] is treated as outfile (not --wf-meta), exit is 0 or 1,
# and the script doesn't crash with an unhandled exception trace.

test_T7_build_env_normal_mode_regression() {
    local outfile="${TMPDIR_BASE}/t7-env.json"
    local node_outfile
    if command -v cygpath >/dev/null 2>&1; then
        node_outfile="$(cygpath -m "$outfile")"
    else
        node_outfile="$outfile"
    fi

    local stdout_out stderr_out
    # Capture stderr separately; redirect stdout for later inspection
    stderr_out="$(run_with_timeout 30 node "$BUILD_ENV_JS" "$node_outfile" 2>&1 >/dev/null)"
    local exit_code=$?

    if [ "$exit_code" = "0" ]; then
        # gh succeeded; run again to capture stdout
        stdout_out="$(run_with_timeout 30 node "$BUILD_ENV_JS" "$node_outfile" 2>/dev/null)"
        if echo "$stdout_out" | grep -q "^ENV_FILE="; then
            pass "T7_build_env_normal_mode_regression: exit 0, ENV_FILE= on stdout (normal mode intact)"
        else
            fail "T7_build_env_normal_mode_regression: exit 0 but no ENV_FILE= in stdout"
        fi
    elif [ "$exit_code" = "1" ]; then
        # gh failed (no PR or not in git repo) — expected in test env
        # A crash would show "TypeError" or "ReferenceError" or node stack frames
        if echo "$stderr_out" | grep -qE "(TypeError|ReferenceError|at Object\.|Cannot find module|UnhandledPromiseRejection)"; then
            fail "T7_build_env_normal_mode_regression: exit 1 but looks like crash: $stderr_out"
        else
            pass "T7_build_env_normal_mode_regression: exit 1 with expected error (gh not available or no PR) — normal mode dispatch intact"
        fi
    else
        fail "T7_build_env_normal_mode_regression: unexpected exit code $exit_code (expected 0 or 1)"
    fi
}

# ============ S-series: Static SKILL.md structural tests ============

test_S1_wf_meta_detection_before_confirm_off() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S1_wf_meta_detection_before_confirm_off (SKILL.md missing)"
        return
    fi
    # WF-META detection line must appear before the ENFORCE_WORKTREE confirm-off call
    local wf_meta_line confirm_off_line
    wf_meta_line="$(grep -n "wf.meta\|WF.META\|WF_META\|wf_meta" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
    confirm_off_line="$(grep -n "confirm-off.*ENFORCE_WORKTREE\|ENFORCE_WORKTREE.*confirm-off" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -z "$wf_meta_line" ]; then
        fail "S1_wf_meta_detection_before_confirm_off: no WF-META detection found in SKILL.md"
        return
    fi
    if [ -z "$confirm_off_line" ]; then
        fail "S1_wf_meta_detection_before_confirm_off: no confirm-off ENFORCE_WORKTREE line found in SKILL.md"
        return
    fi
    if [ "$wf_meta_line" -lt "$confirm_off_line" ]; then
        pass "S1_wf_meta_detection_before_confirm_off: WF-META detection (line $wf_meta_line) before confirm-off (line $confirm_off_line)"
    else
        fail "S1_wf_meta_detection_before_confirm_off: WF-META detection (line $wf_meta_line) must come before confirm-off (line $confirm_off_line)"
    fi
}

test_S2_skill_md_contains_build_env_wf_meta_call() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S2_skill_md_contains_build_env_wf_meta_call (SKILL.md missing)"
        return
    fi
    if grep -qF "session-close-build-env.js --wf-meta" "$SKILL_MD"; then
        pass "S2_skill_md_contains_build_env_wf_meta_call: SKILL.md contains 'session-close-build-env.js --wf-meta'"
    else
        fail "S2_skill_md_contains_build_env_wf_meta_call: 'session-close-build-env.js --wf-meta' not found in SKILL.md"
    fi
}

test_S3_write_outcome_wf_meta_before_issue_close_finalize() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S3_write_outcome_wf_meta_before_issue_close_finalize (SKILL.md missing)"
        return
    fi
    # issue-close-write-outcome.js --wf-meta call must appear before /issue-close-finalize
    local outcome_wf_meta_line finalize_line
    outcome_wf_meta_line="$(grep -n "issue-close-write-outcome.js --wf-meta" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
    finalize_line="$(grep -n "/issue-close-finalize" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -z "$outcome_wf_meta_line" ]; then
        fail "S3_write_outcome_wf_meta_before_issue_close_finalize: 'issue-close-write-outcome.js --wf-meta' not found in SKILL.md"
        return
    fi
    if [ -z "$finalize_line" ]; then
        fail "S3_write_outcome_wf_meta_before_issue_close_finalize: '/issue-close-finalize' not found in SKILL.md"
        return
    fi
    if [ "$outcome_wf_meta_line" -lt "$finalize_line" ]; then
        pass "S3_write_outcome_wf_meta_before_issue_close_finalize: --wf-meta outcome (line $outcome_wf_meta_line) before /issue-close-finalize (line $finalize_line)"
    else
        fail "S3_write_outcome_wf_meta_before_issue_close_finalize: --wf-meta outcome (line $outcome_wf_meta_line) must precede /issue-close-finalize (line $finalize_line)"
    fi
}

test_S4_skill_md_has_skipped_wf_meta_and_kept_open() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S4_skill_md_has_skipped_wf_meta_and_kept_open (SKILL.md missing)"
        return
    fi
    local has_skipped has_kept
    grep -qF "skipped_wf_meta" "$SKILL_MD" && has_skipped=1 || has_skipped=0
    grep -qF "kept open (planning session)" "${AGENTS_DIR}/hooks/lib/final-report-schema.js" && has_kept=1 || has_kept=0
    if [ "$has_skipped" = "1" ] && [ "$has_kept" = "1" ]; then
        pass "S4_skill_md_has_skipped_wf_meta_and_kept_open: both 'skipped_wf_meta' and 'kept open (planning session)' found"
    elif [ "$has_skipped" = "0" ] && [ "$has_kept" = "0" ]; then
        fail "S4_skill_md_has_skipped_wf_meta_and_kept_open: neither 'skipped_wf_meta' nor 'kept open (planning session)' found"
    elif [ "$has_skipped" = "0" ]; then
        fail "S4_skill_md_has_skipped_wf_meta_and_kept_open: 'skipped_wf_meta' not found in SKILL.md"
    else
        fail "S4_skill_md_has_skipped_wf_meta_and_kept_open: 'kept open (planning session)' not found in SKILL.md"
    fi
}

test_S5_skill_md_rules_mention_wf_meta_and_finalize() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "S5_skill_md_rules_mention_wf_meta_and_finalize (SKILL.md missing)"
        return
    fi
    # Rules section must mention both WF-META and issue-close-finalize together
    local rules_section
    rules_section="$(awk '/^## Rules/,0' "$SKILL_MD" 2>/dev/null)"
    local has_wf_meta has_finalize
    echo "$rules_section" | grep -qiE "wf.meta|WF_META|wf_meta" && has_wf_meta=1 || has_wf_meta=0
    echo "$rules_section" | grep -qF "issue-close-finalize" && has_finalize=1 || has_finalize=0
    if [ "$has_wf_meta" = "1" ] && [ "$has_finalize" = "1" ]; then
        pass "S5_skill_md_rules_mention_wf_meta_and_finalize: Rules section references both WF-META and issue-close-finalize"
    elif [ "$has_wf_meta" = "0" ] && [ "$has_finalize" = "0" ]; then
        fail "S5_skill_md_rules_mention_wf_meta_and_finalize: Rules section lacks both WF-META and issue-close-finalize references"
    elif [ "$has_wf_meta" = "0" ]; then
        fail "S5_skill_md_rules_mention_wf_meta_and_finalize: Rules section lacks WF-META reference"
    else
        fail "S5_skill_md_rules_mention_wf_meta_and_finalize: Rules section lacks issue-close-finalize reference"
    fi
}

# ============ Run all tests ============

test_T1_build_env_wf_meta_exit0_and_json
test_T2_build_env_wf_meta_no_outfile_exit1
test_T3_write_outcome_wf_meta_single
test_T4_write_outcome_wf_meta_multi
test_T5_write_outcome_wf_meta_empty
test_T6_build_env_wf_meta_pr_fields_empty
test_T7_build_env_normal_mode_regression
test_S1_wf_meta_detection_before_confirm_off
test_S2_skill_md_contains_build_env_wf_meta_call
test_S3_write_outcome_wf_meta_before_issue_close_finalize
test_S4_skill_md_has_skipped_wf_meta_and_kept_open
test_S5_skill_md_rules_mention_wf_meta_and_finalize

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
