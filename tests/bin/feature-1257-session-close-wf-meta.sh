#!/bin/bash
# tests/bin/feature-1257-session-close-wf-meta.sh
# Tests: bin/session-close-build-env.js, bin/issue-close-write-outcome.js, skills/session-close/SKILL.md
# Tags: session-close, wf-meta, env-json, outcome, scope:issue-specific, feature-2434, control-dir
# Issue #1257 — /session-close WF-META path (no PR/worktree): --wf-meta in build-env writes empty
# PR fields, in issue-close-write-outcome writes skipped_wf_meta; S1-S5 pin the SKILL.md path.
# #2434 (N-series): build-env derives its env file under <WORKFLOW_STATE_DIR>/<sid>.control/.
# L3 gap: a real /session-close on a WF-META session (SC-1 ordering, "(none)" PR fields, no gh
# call, finalize skipped) needs a claude -p E2E gated on RUN_TL3.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# #2434: the env file is a control file, so both state dirs are pinned to the fixture.
WF_DIR="${TMPDIR_BASE}/wf"
PLANS_DIR="${TMPDIR_BASE}/plans"
mkdir -p "$WF_DIR" "$PLANS_DIR" "${TMPDIR_BASE}/home" "${TMPDIR_BASE}/tx" "${TMPDIR_BASE}/cwd"
export HOME="${TMPDIR_BASE}/home"
export WORKFLOW_STATE_DIR="$WF_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"
export CLAUDE_TRANSCRIPT_BASE_DIR="${TMPDIR_BASE}/tx"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
SC_SID="f1257-sid"
SC_OTHER_SID="f1257-other"
SC_DERIVED_ENV="${WF_DIR}/${SC_SID}.control/final-report-env.json"

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
    # #2434: the legacy argument must name the derived control path (legacy shim).
    local outfile="$SC_DERIVED_ENV"
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
    # #2434: the legacy argument must name the derived control path (legacy shim).
    local outfile="$SC_DERIVED_ENV"
    rm -f "$outfile"
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
    # #2434: the legacy argument must name the derived control path (legacy shim).
    local outfile="$SC_DERIVED_ENV"
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
    # #1307: anchor on the real invocation ("issue-close-finalize --from-session"), not the
    # bare "/issue-close-finalize" — the bare form also matches SKILL.md prose (e.g. "never
    # invokes /issue-close-finalize"), which could resolve to a line before the outcome call.
    local outcome_wf_meta_line finalize_line
    outcome_wf_meta_line="$(grep -n "issue-close-write-outcome.js --wf-meta" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
    finalize_line="$(grep -n "issue-close-finalize --from-session" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)"
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

# ============ N-series (#2434): --session derives the env file under <wf>/<sid>.control/ ============

# sc_build_env <args...> — run build-env from a neutral cwd; sets SC_RC and SC_OUT.
sc_build_env() {
    SC_OUT="$(cd "${TMPDIR_BASE}/cwd" && run_with_timeout 30 node "$BUILD_ENV_JS" "$@" 2>/dev/null)"
    SC_RC=$?
}
sc_reset() { rm -rf "$WF_DIR" "$PLANS_DIR" "${TMPDIR_BASE}/cwd" "${TMPDIR_BASE}/outside"; mkdir -p "$WF_DIR" "$PLANS_DIR" "${TMPDIR_BASE}/cwd"; }
sc_plans_has_control() { ls -A "$PLANS_DIR" 2>/dev/null | grep -q "final-report-env"; }
sc_cwd_is_empty() { [ -z "$(ls -A "${TMPDIR_BASE}/cwd" 2>/dev/null)" ]; }
sc_pr_fields_empty() {
    run_with_timeout 30 node -e "
        const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        for (const k of ['BRANCH','PR_NUMBER','PR_TITLE','PR_URL','PR_STATE']) {
            if (d[k] !== '') { process.stdout.write('field '+k+'='+JSON.stringify(d[k])); process.exit(1); }
        }
        process.stdout.write('ok');
    " "$1" 2>/dev/null
}

test_N1_build_env_wf_meta_session_derives_control_path() {
    sc_reset
    sc_build_env --wf-meta --session "$SC_SID"
    if [ "$SC_RC" != "0" ]; then fail "N1_wf_meta_session: expected exit 0, got $SC_RC"; return; fi
    if [ ! -f "$SC_DERIVED_ENV" ]; then fail "N1_wf_meta_session: env file not at derived path $SC_DERIVED_ENV"; return; fi
    local fields; fields="$(sc_pr_fields_empty "$SC_DERIVED_ENV")"
    if [ "$fields" != "ok" ]; then fail "N1_wf_meta_session: PR fields not empty: $fields"; return; fi
    if ! printf '%s\n' "$SC_OUT" | grep -q "^ENV_FILE=.*${SC_SID}\.control.final-report-env\.json"; then
        fail "N1_wf_meta_session: stdout ENV_FILE= does not name the derived path (got: $SC_OUT)"; return
    fi
    if sc_plans_has_control; then fail "N1_wf_meta_session: a final-report-env file appeared in PLANS_DIR"; return; fi
    if ! sc_cwd_is_empty; then fail "N1_wf_meta_session: stray file written into the cwd: $(ls -A "${TMPDIR_BASE}/cwd")"; return; fi
    pass "N1_wf_meta_session: --wf-meta --session writes <wf>/<sid>.control/final-report-env.json only"
}

test_N2_build_env_legacy_derived_path_accepted() {
    sc_reset
    sc_build_env --wf-meta "$SC_DERIVED_ENV"
    if [ "$SC_RC" = "0" ] && [ -f "$SC_DERIVED_ENV" ] && ! sc_plans_has_control; then
        pass "N2_legacy_derived_path: the derived control path is accepted as a legacy argument"
    else
        fail "N2_legacy_derived_path: rc=$SC_RC derived_exists=$([ -f "$SC_DERIVED_ENV" ] && echo y || echo n)"
    fi
}

test_N3_build_env_legacy_plans_basename_redirected() {
    sc_reset
    local legacy="${PLANS_DIR}/${SC_SID}-final-report-env.json"
    sc_build_env --wf-meta "$legacy"
    if [ "$SC_RC" != "0" ]; then fail "N3_legacy_plans_basename: expected exit 0, got $SC_RC"; return; fi
    if [ -e "$legacy" ]; then fail "N3_legacy_plans_basename: the control file was written into PLANS_DIR ($legacy)"; return; fi
    if [ ! -f "$SC_DERIVED_ENV" ]; then fail "N3_legacy_plans_basename: result did not land at the derived path"; return; fi
    pass "N3_legacy_plans_basename: <plans>/<sid>-final-report-env.json is redirected to the derived path"
}

# name | legacy argument (relative names are made absolute below) — every row must be refused.
test_N4_build_env_rejects_foreign_paths() {
    local name arg
    while IFS='|' read -r name arg; do
        name="$(printf '%s' "$name" | tr -d ' ')"; arg="$(printf '%s' "$arg" | tr -d ' ')"
        [ -z "$name" ] && continue
        arg="${arg//__PLANS__/$PLANS_DIR}"; arg="${arg//__WF__/$WF_DIR}"; arg="${arg//__OUT__/${TMPDIR_BASE}/outside}"
        sc_reset
        sc_build_env --wf-meta "$arg"
        if [ "$SC_RC" = "0" ]; then fail "N4_reject[$name]: expected non-zero exit for $arg"; continue; fi
        if [ -e "$arg" ]; then fail "N4_reject[$name]: the rejected path was written anyway"; continue; fi
        if [ -f "$SC_DERIVED_ENV" ]; then fail "N4_reject[$name]: a derived file was written for a rejected argument"; continue; fi
        pass "N4_reject[$name]: refused with rc=$SC_RC and nothing written"
    done <<'TABLE'
plans-other-name   | __PLANS__/other.json
plans-wrong-name   | __PLANS__/f1257-sid-final-report.json
outside-dir        | __OUT__/final-report-env.json
wf-top-level       | __WF__/final-report-env.json
TABLE
}

test_N5_build_env_session_with_other_sid_path_rejected() {
    local row arg
    for row in control plans; do
        sc_reset
        if [ "$row" = "control" ]; then arg="${WF_DIR}/${SC_OTHER_SID}.control/final-report-env.json"
        else arg="${PLANS_DIR}/${SC_OTHER_SID}-final-report-env.json"; fi
        sc_build_env --wf-meta --session "$SC_SID" "$arg"
        if [ "$SC_RC" = "0" ]; then fail "N5_other_sid[$row]: --session $SC_SID with $SC_OTHER_SID's path must be refused"; continue; fi
        if [ -e "$arg" ] || [ -f "$SC_DERIVED_ENV" ] || [ -e "${WF_DIR}/${SC_OTHER_SID}.control/final-report-env.json" ]; then
            fail "N5_other_sid[$row]: something was written despite the refusal"; continue
        fi
        if ! sc_cwd_is_empty; then fail "N5_other_sid[$row]: stray file in cwd"; continue; fi
        pass "N5_other_sid[$row]: another session's path is refused and nothing written"
    done
}

test_N6_build_env_invalid_or_missing_sid_rejected() {
    local label
    for label in traversal space empty missing; do
        sc_reset
        case "$label" in
            traversal) sc_build_env --wf-meta --session "../x" ;;
            space)     sc_build_env --wf-meta --session "bad id" ;;
            empty)     sc_build_env --wf-meta --session "" ;;
            missing)   sc_build_env --wf-meta --session ;;
        esac
        if [ "$SC_RC" = "0" ]; then fail "N6_bad_sid[$label]: expected non-zero exit"; continue; fi
        if [ -n "$(ls -A "$WF_DIR" 2>/dev/null)" ] || [ -e "${TMPDIR_BASE}/x.control" ] || ! sc_cwd_is_empty || sc_plans_has_control; then
            fail "N6_bad_sid[$label]: a file was written despite the refusal"; continue
        fi
        pass "N6_bad_sid[$label]: refused with rc=$SC_RC and nothing written"
    done
}

test_N7_build_env_normal_mode_session_no_stray_file() {
    sc_reset
    sc_build_env --session "$SC_SID"
    if [ "$SC_RC" != "0" ] && [ "$SC_RC" != "1" ]; then fail "N7_normal_session: unexpected exit $SC_RC"; return; fi
    if ! sc_cwd_is_empty; then fail "N7_normal_session: '--session' was treated as an output path ($(ls -A "${TMPDIR_BASE}/cwd"))"; return; fi
    if sc_plans_has_control; then fail "N7_normal_session: a control file appeared in PLANS_DIR"; return; fi
    if [ "$SC_RC" = "0" ] && [ ! -f "$SC_DERIVED_ENV" ]; then fail "N7_normal_session: exit 0 without the derived env file"; return; fi
    pass "N7_normal_session: --session in normal mode writes only the derived path (rc=$SC_RC)"
}

test_S6_skill_md_build_env_calls_pass_session_only() {
    if [ ! -f "$SKILL_MD" ]; then skip "S6_skill_md_build_env_session (SKILL.md missing)"; return; fi
    local lines bad
    lines="$(grep -F "session-close-build-env.js" "$SKILL_MD")"
    if [ -z "$lines" ]; then fail "S6_skill_md_build_env_session: no build-env invocation in SKILL.md"; return; fi
    bad="$(printf '%s\n' "$lines" | grep -vF -- "--session" || true)"
    if [ -n "$bad" ]; then fail "S6_skill_md_build_env_session: invocation without --session: $bad"; return; fi
    if printf '%s\n' "$lines" | grep -qF "final-report-env.json"; then
        fail "S6_skill_md_build_env_session: an invocation still passes the control-file path"; return
    fi
    pass "S6_skill_md_build_env_session: every build-env invocation passes --session and no control path"
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
test_N1_build_env_wf_meta_session_derives_control_path
test_N2_build_env_legacy_derived_path_accepted
test_N3_build_env_legacy_plans_basename_redirected
test_N4_build_env_rejects_foreign_paths
test_N5_build_env_session_with_other_sid_path_rejected
test_N6_build_env_invalid_or_missing_sid_rejected
test_N7_build_env_normal_mode_session_no_stray_file
test_S6_skill_md_build_env_calls_pass_session_only

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
