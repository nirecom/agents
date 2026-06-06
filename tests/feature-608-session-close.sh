#!/bin/bash
# tests/feature-608-session-close.sh
# Tests: hooks/lib/final-report-schema.js, skills/session-close/SKILL.md, skills/worktree-end/SKILL.md, skills/issue-close-finalize/SKILL.md
# Tags: issue-close, finalize, workflow, worktree, end, schema
#
# Issue #608 / #771 — /session-close orchestration + Final Report renderer abolition.
#
# After #771: bin/worktree-final-report.js is deleted. T-series renderer tests
# removed. S-series extended with renderSkeleton + bin-absence assertions.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

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

require_schema() {
    if [ ! -f "$SCHEMA_JS" ]; then
        skip "$1 (hooks/lib/final-report-schema.js missing)"
        return 1
    fi
    return 0
}

# ============ T6-T7: Schema unit tests (kept; the renderer is gone but schema remains) ============

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
    if grep -q "ICF-K" "$f"; then
        pass "S4_issue_close_finalize_has_step_l: ICF-K (formerly Step L) present"
    else
        fail "S4_issue_close_finalize_has_step_l: ICF-K not found"
    fi
}

# S5 renamed: assert no production-tree source file references the deleted
# renderer literal `worktree-final-report` (the renderer is abolished). Tests
# and docs/history are excluded from the scan.
test_S5_no_worktree_final_report_references() {
    local hits=""
    local search_roots=("$AGENTS_DIR/skills" "$AGENTS_DIR/hooks" "$AGENTS_DIR/bin")
    for root in "${search_roots[@]}"; do
        if [ -d "$root" ]; then
            # exclude the worktree-notes-triage.js (unrelated filename, but
            # would not match anyway because we grep the literal string
            # "worktree-final-report") — grep is precise here.
            local found
            found="$(grep -rlF "worktree-final-report" "$root" 2>/dev/null || true)"
            if [ -n "$found" ]; then
                hits="${hits}${found}
"
            fi
        fi
    done

    if [ -z "$hits" ]; then
        pass "S5_no_worktree_final_report_references: no production-tree file mentions 'worktree-final-report'"
    else
        fail "S5_no_worktree_final_report_references: found references in:
$hits"
    fi
}

test_S6_session_close_step4_uses_skeleton() {
    local f="${AGENTS_DIR}/skills/session-close/SKILL.md"
    if [ ! -f "$f" ]; then
        skip "S6_session_close_step4_uses_skeleton (skills/session-close/SKILL.md missing)"
        return
    fi
    if grep -qF "renderSkeleton" "$f"; then
        pass "S6_session_close_step4_uses_skeleton: SKILL.md references renderSkeleton"
    else
        fail "S6_session_close_step4_uses_skeleton: SKILL.md does not reference renderSkeleton"
    fi
}

test_S7_renderer_bin_absent() {
    local f="$AGENTS_DIR/bin/worktree-final-report.js"
    if [ ! -f "$f" ]; then
        pass "S7_renderer_bin_absent: bin/worktree-final-report.js is absent (renderer abolished)"
    else
        fail "S7_renderer_bin_absent: bin/worktree-final-report.js still exists (should be deleted in #771)"
    fi
}

test_S8_schema_exports_renderSkeleton() {
    require_schema "S8_schema_exports_renderSkeleton" || return
    local result
    result="$(run_with_timeout 120 node -e "
        const s = require('${SCHEMA_JS}');
        process.stdout.write(typeof s.renderSkeleton);
    " 2>/dev/null)"
    if [ "$result" = "function" ]; then
        pass "S8_schema_exports_renderSkeleton: typeof renderSkeleton === 'function'"
    else
        fail "S8_schema_exports_renderSkeleton: expected 'function', got '$result'"
    fi
}

# ============ Run all ============

test_T6_schema_section_present
test_T7_schema_probes_aggregated

test_S1_session_close_skill_exists
test_S2_worktree_end_no_step7
test_S3_claude_md_routes_session_close
test_S4_issue_close_finalize_has_step_l
test_S5_no_worktree_final_report_references
test_S6_session_close_step4_uses_skeleton
test_S7_renderer_bin_absent
test_S8_schema_exports_renderSkeleton

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
