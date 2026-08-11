#!/bin/bash
# K-series: renderSkeleton / renderFinalReport (post-#771)
# Tests: hooks/lib/final-report-schema.js
# Tags: scope:common
#
# Sourced helpers: feature-405-final-report/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Render the skeleton via Node and capture stdout.
render_skeleton() {
    local sid="$1"
    run_with_timeout 120 node -e "
        const s = require('${SCHEMA_JS}');
        if (typeof s.renderSkeleton !== 'function') {
          process.stderr.write('renderSkeleton not exported');
          process.exit(1);
        }
        process.stdout.write(s.renderSkeleton(process.argv[1]));
    " -- "$sid" 2>/dev/null
}

# Render the full Final Report via renderFinalReport(sessionId, inputs), where
# inputs is read from a JSON fixture file. Capture stdout.
render_final_report_from_file() {
    local sid="$1" inputs_file="$2"
    local inputs_node; inputs_node="$(node_path "$inputs_file")"
    run_with_timeout 120 node -e "
        const fs = require('fs');
        const s = require('${SCHEMA_JS}');
        const inputs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
        process.stdout.write(s.renderFinalReport(process.argv[1], inputs));
    " -- "$sid" "$inputs_node" 2>/dev/null
}

test_K1_skeleton_has_h2_and_nine_h3() {
    require_schema "K1_skeleton_has_h2_and_nine_h3" || return
    local sid="sess-123"
    local out; out="$(render_skeleton "$sid")"
    if [ -z "$out" ]; then
        fail "K1: renderSkeleton returned empty (function may not be exported yet)"
        return
    fi

    local ok=1
    echo "$out" | grep -qF "## Final Report — sess-123" || ok=0
    echo "$out" | grep -q "^### Closed Issues$"            || ok=0
    echo "$out" | grep -q "^### Merged PR$"                || ok=0
    echo "$out" | grep -q "^### Worktree$"                 || ok=0
    echo "$out" | grep -q "^### Backup$"                   || ok=0
    echo "$out" | grep -q "^### Closed Issue Outcomes$"    || ok=0
    echo "$out" | grep -q "^### Post-Merge Actions Required$" || ok=0
    echo "$out" | grep -q "^### Bugs Found$"               || ok=0
    echo "$out" | grep -q "^### Related Tasks$"            || ok=0
    echo "$out" | grep -q "^### Next Tasks$"                || ok=0
    echo "$out" | grep -q "^### Supervisor Alert$"         || ok=0
    echo "$out" | grep -q "^### Supervisor Audit$"         || ok=0
    echo "$out" | grep -q "^### Supervisor Findings$"      || ok=0

    if [ "$ok" = "1" ]; then
        pass "K1: renderSkeleton contains H2 and all 12 ### headings"
    else
        fail "K1: at least one heading missing from skeleton output
--- output ---
$out"
    fi
}

test_K2_skeleton_has_field_placeholders() {
    require_schema "K2_skeleton_has_field_placeholders" || return
    local sid="sess-k2"
    local out; out="$(render_skeleton "$sid")"
    if [ -z "$out" ]; then
        fail "K2: renderSkeleton returned empty"
        return
    fi

    local ok=1
    for tok in "<PR_NUMBER>" "<PR_TITLE>" "<PR_URL>" "<BRANCH>" \
               "<WORKTREE_PATH>" "<CREATED_DATE>" "<BACKUP_MANIFEST_PATH>" \
               "<BRANCH_DELETED>" "<PR_STATE>"; do
        if ! echo "$out" | grep -qF "$tok"; then
            ok=0
            echo "  K2 missing token: $tok"
        fi
    done

    if [ "$ok" = "1" ]; then
        pass "K2: skeleton has all field placeholders (PR_NUMBER/PR_TITLE/PR_URL/BRANCH/WORKTREE_PATH/CREATED_DATE/BACKUP_MANIFEST_PATH/BRANCH_DELETED/PR_STATE)"
    else
        fail "K2: missing one or more field placeholders
--- output ---
$out"
    fi
}

test_K3_skeleton_has_block_placeholders() {
    require_schema "K3_skeleton_has_block_placeholders" || return
    local sid="sess-k3"
    local out; out="$(render_skeleton "$sid")"
    if [ -z "$out" ]; then
        fail "K3: renderSkeleton returned empty"
        return
    fi

    local ok=1
    for tok in "<CLOSED_ISSUES_LIST>" "<CLOSED_ISSUE_OUTCOMES>" \
               "<BUGS_FOUND>" "<RELATED_TASKS>" "<NEXT_TASKS>" \
               "<SUPERVISOR_ALERT_SUMMARY>" "<SUPERVISOR_AUDIT_SUMMARY>" \
               "<SUPERVISOR_FINDINGS_DETAIL>"; do
        if ! echo "$out" | grep -qF "$tok"; then
            ok=0
            echo "  K3 missing token: $tok"
        fi
    done

    if [ "$ok" = "1" ]; then
        pass "K3: skeleton has block placeholders (CLOSED_ISSUES_LIST/CLOSED_ISSUE_OUTCOMES/BUGS_FOUND/RELATED_TASKS/NEXT_TASKS/SUPERVISOR_ALERT_SUMMARY/SUPERVISOR_AUDIT_SUMMARY/SUPERVISOR_FINDINGS_DETAIL)"
    else
        fail "K3: missing one or more block placeholders
--- output ---
$out"
    fi
}

test_K4_skeleton_post_merge_categories() {
    require_schema "K4_skeleton_post_merge_categories" || return
    local sid="sess-k4"
    local out; out="$(render_skeleton "$sid")"
    if [ -z "$out" ]; then
        fail "K4: renderSkeleton returned empty"
        return
    fi

    local ok=1
    echo "$out" | grep -qF -- '- Claude Code restart: <CC_RESTART_REQUIRED_DECISION>'   || ok=0
    echo "$out" | grep -qF -- '- VS Code reload: <VSCODE_RELOAD_REQUIRED_DECISION>'     || ok=0
    echo "$out" | grep -qF -- '- Installer rerun: <INSTALLER_RERUN_REQUIRED_DECISION>'  || ok=0
    echo "$out" | grep -qF -- '- OS reboot: <OS_REBOOT_REQUIRED_DECISION>'              || ok=0

    if [ "$ok" = "1" ]; then
        pass "K4: skeleton Post-Merge has all 4 categories with _DECISION placeholders"
    else
        fail "K4: missing one or more Post-Merge category lines
--- output ---
$out"
    fi
}

test_K5_skill_md_outcome_absent_fallback() {
    require_session_close_skill "K5_skill_md_outcome_absent_fallback" || return
    if grep -qF "outcome data not found — investigate" "${AGENTS_DIR}/hooks/lib/final-report-schema.js"; then
        pass "K5: final-report-schema.js contains outcome-absent fallback text"
    else
        fail "K5: final-report-schema.js missing 'outcome data not found — investigate' fallback"
    fi
}

test_K6_skill_md_notes_absent_fallback() {
    require_session_close_skill "K6_skill_md_notes_absent_fallback" || return
    # Look for the "- (none)" fallback being referenced for the findings blocks.
    if grep -qF -- "- (none)" "${AGENTS_DIR}/hooks/lib/final-report-schema.js"; then
        pass "K6: final-report-schema.js references '- (none)' notes-absent fallback"
    else
        fail "K6: final-report-schema.js missing '- (none)' notes-absent fallback marker"
    fi
}

# K8: closedIssueOutcomeLines() (via renderFinalReport's <CLOSED_ISSUE_OUTCOMES>
# substitution) must render the issue number from the outcome-JSON schema the
# real writer (bin/issue-close-write-outcome.js:228) actually uses: the key
# `issueNumber`, not `number`. #1614: the source currently reads `it.number`,
# which is undefined for every entry — this test is expected to FAIL until
# that production bug is fixed.
#
# closesIssues is pinned to [] in the fixture so the issue number cannot leak
# in via the separate <CLOSED_ISSUES_LIST> section and produce a false pass.
test_K8_closed_issue_outcomes_uses_issueNumber_field() {
    require_schema "K8_closed_issue_outcomes_uses_issueNumber_field" || return
    local sid="sess-k8"
    local f="$TMPDIR_BASE/k8-inputs.json"
    cat > "$f" <<'EOF'
{
  "env": {},
  "outcome": {
    "issues": [
      { "issueNumber": 1614, "state": "closed", "historyEntry": true, "issueClosed": true, "sentinelsPosted": true, "wipCleared": true }
    ]
  },
  "closesIssues": [],
  "notesSections": { "bugs": "(none)", "related": "(none)", "next": "(none)" },
  "supervisorState": null
}
EOF
    local out; out="$(render_final_report_from_file "$sid" "$f")"
    if [ -z "$out" ]; then
        fail "K8: renderFinalReport returned empty"
        return
    fi

    local region
    region="$(printf '%s\n' "$out" | awk '/^### Closed Issue Outcomes$/{found=1;next} found{if(/^### /){exit}print}')"

    if echo "$region" | grep -qF "#1614:"; then
        pass "K8: Closed Issue Outcomes renders '#1614:' from outcome.issues[].issueNumber"
    else
        fail "K8: expected '#1614:' in Closed Issue Outcomes region — got '#undefined' instead (issue #1614: closedIssueOutcomeLines() reads it.number, but the writer's schema key is it.issueNumber)
--- region ---
$region"
    fi
}

# K9: supervisorFindingsDetail() (via renderFinalReport's
# <SUPERVISOR_FINDINGS_DETAIL> substitution) calls
# formatLayer2Findings(findings, { summaryOnly: true }) — the branch production
# code actually exercises. Assertion is scoped strictly to the
# "### Supervisor Findings" region so other report sections cannot produce a
# false pass.
test_K9_supervisor_findings_detail_summary_only() {
    require_schema "K9_supervisor_findings_detail_summary_only" || return
    local sid="sess-k9"
    local f="$TMPDIR_BASE/k9-inputs.json"
    cat > "$f" <<'EOF'
{
  "env": {},
  "outcome": { "issues": [] },
  "closesIssues": [],
  "notesSections": { "bugs": "(none)", "related": "(none)", "next": "(none)" },
  "supervisorState": {
    "alert": {
      "findings": [
        { "categories": ["code"], "severity": "warning", "detail": "d1", "reporter": "write-code" },
        { "categories": ["test"], "severity": "error", "detail": "d2", "reporter": "review-tests" }
      ]
    }
  }
}
EOF
    local out; out="$(render_final_report_from_file "$sid" "$f")"
    if [ -z "$out" ]; then
        fail "K9: renderFinalReport returned empty"
        return
    fi

    local region nonblank_count nonblank_line
    region="$(printf '%s\n' "$out" | awk '/^### Supervisor Findings$/{found=1;next} found{if(/^### /){exit}print}')"
    local expected="[EM Supervisor] 2 finding(s), highest severity: error."
    # summaryOnly's whole contract is that nothing else leaks into the Final
    # Report. Blank lines are formatting artifacts of the awk region
    # extraction (and of section spacing), not renderer content, so they are
    # excluded from the count; every non-blank line in the region must be
    # exactly the one-line summary and there must be exactly one such line.
    # A substring match here would let a regression that appends finding
    # details or a footer path after the summary line still pass.
    nonblank_count="$(printf '%s\n' "$region" | grep -c '.' || true)"
    nonblank_line="$(printf '%s\n' "$region" | grep '.' | head -1)"

    if [ "$nonblank_count" = "1" ] && [ "$nonblank_line" = "$expected" ]; then
        pass "K9: Supervisor Findings region is EXACTLY the summaryOnly 1-line format: '$expected'"
    else
        fail "K9: expected Supervisor Findings region to be exactly one line '$expected' (summaryOnly must not leak extra lines), got $nonblank_count non-blank line(s):
--- region ---
$region"
    fi
}

# ============ Run all ============

test_K1_skeleton_has_h2_and_nine_h3
test_K2_skeleton_has_field_placeholders
test_K3_skeleton_has_block_placeholders
test_K4_skeleton_post_merge_categories
test_K5_skill_md_outcome_absent_fallback
test_K6_skill_md_notes_absent_fallback
test_K8_closed_issue_outcomes_uses_issueNumber_field
test_K9_supervisor_findings_detail_summary_only

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
