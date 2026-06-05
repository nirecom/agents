#!/bin/bash
# tests/feature-405-final-report.sh
# Tests: hooks/lib/parse-closes-issues.js, hooks/lib/worktree-notes.js, hooks/lib/final-report-schema.js, skills/worktree-end/SKILL.md, skills/session-close/SKILL.md
# Tags: worktree, end, cleanup, parse, closes-issues, schema
#
# Issue #405 / #771 — Final Report feature (post-renderer-abolition).
#
# After #771: bin/worktree-final-report.js is deleted. The Final Report is now
# emitted by Claude inline using `renderSkeleton(sessionId)` from
# hooks/lib/final-report-schema.js as a guide. Tests for the deleted renderer
# (R-series) have been removed; K-series (skeleton) tests added.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PARSE_JS="${_AGENTS_DIR_NODE}/hooks/lib/parse-closes-issues.js"
NOTES_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes.js"
SCHEMA_JS="${_AGENTS_DIR_NODE}/hooks/lib/final-report-schema.js"
SKILL_MD="${AGENTS_DIR}/skills/worktree-end/SKILL.md"
SESSION_CLOSE_SKILL_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"

PASS=0
FAIL=0
SKIP=0
# Guard: ensure AGENTS_CONFIG_DIR does not bleed into pre-agents-gate tests
unset AGENTS_CONFIG_DIR

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f405-'+process.pid).replace(/\\\\/g,'/');
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

# Run the parser; print JSON-stringified result to stdout.
parse_eval() {
    local intent_node; intent_node="$(node_path "$1")"
    run_with_timeout 120 node -e "
        const { parseClosesIssues } = require('${PARSE_JS}');
        const r = parseClosesIssues(process.argv[1]);
        process.stdout.write(JSON.stringify(r));
    " -- "$intent_node" 2>/dev/null
}

require_parser() {
    if [ ! -f "$PARSE_JS" ]; then
        skip "$1 (hooks/lib/parse-closes-issues.js not implemented yet)"
        return 1
    fi
    return 0
}

require_notes_lib() {
    if [ ! -f "$NOTES_JS" ]; then
        skip "$1 (hooks/lib/worktree-notes.js missing)"
        return 1
    fi
    return 0
}

require_schema() {
    if [ ! -f "$SCHEMA_JS" ]; then
        skip "$1 (hooks/lib/final-report-schema.js not implemented yet)"
        return 1
    fi
    return 0
}

require_skill_md() {
    if [ ! -f "$SKILL_MD" ]; then
        skip "$1 (skills/worktree-end/SKILL.md missing)"
        return 1
    fi
    return 0
}

require_session_close_skill() {
    if [ ! -f "$SESSION_CLOSE_SKILL_MD" ]; then
        skip "$1 (skills/session-close/SKILL.md missing)"
        return 1
    fi
    return 0
}

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

# ============ P-series: parse-closes-issues.js ============

test_P1_happy_single() {
    require_parser "P1_happy_single" || return
    local f="$TMPDIR_BASE/p1-intent.md"
    printf '## closes_issues\n- 405\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[405]" ]; then
        pass "P1: single issue '- 405' → [405]"
    else
        fail "P1: expected [405], got $out"
    fi
}

test_P2_happy_multi() {
    require_parser "P2_happy_multi" || return
    local f="$TMPDIR_BASE/p2-intent.md"
    printf '## closes_issues\n- 100\n- 200\n- 300\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[100,200,300]" ]; then
        pass "P2: multi '- 100/- 200/- 300' → [100,200,300]"
    else
        fail "P2: expected [100,200,300], got $out"
    fi
}

test_P3_empty_literal() {
    require_parser "P3_empty_literal" || return
    local f="$TMPDIR_BASE/p3-intent.md"
    printf '## closes_issues\n(empty)\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[]" ]; then
        pass "P3: literal '(empty)' → []"
    else
        fail "P3: expected [], got $out"
    fi
}

test_P4_missing_section() {
    require_parser "P4_missing_section" || return
    local f="$TMPDIR_BASE/p4-intent.md"
    printf '# Intent\nSomething else.\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[]" ]; then
        pass "P4: no ## closes_issues section → []"
    else
        fail "P4: expected [], got $out"
    fi
}

test_P5_missing_file() {
    require_parser "P5_missing_file" || return
    local f="$TMPDIR_BASE/p5-nonexistent.md"
    local out; out="$(parse_eval "$f")"
    local intent_node; intent_node="$(node_path "$f")"
    run_with_timeout 120 node -e "
        const { parseClosesIssues } = require('${PARSE_JS}');
        parseClosesIssues(process.argv[1]);
    " -- "$intent_node" >/dev/null 2>&1
    local code=$?
    if [ "$out" = "[]" ] && [ "$code" = "0" ]; then
        pass "P5: non-existent file → [] (exit 0)"
    else
        fail "P5: expected [] & exit 0, got out=$out code=$code"
    fi
}

test_P6_non_integer_skipped() {
    require_parser "P6_non_integer_skipped" || return
    local f="$TMPDIR_BASE/p6-intent.md"
    printf '## closes_issues\n- 405\n- foo\n- 410\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[405,410]" ]; then
        pass "P6: '- foo' skipped; integers preserved → [405,410]"
    else
        fail "P6: expected [405,410], got $out"
    fi
}

test_P7_trailing_section_stops_parse() {
    require_parser "P7_trailing_section_stops_parse" || return
    local f="$TMPDIR_BASE/p7-intent.md"
    printf '## closes_issues\n- 405\n## other section\n- 999\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[405]" ]; then
        pass "P7: trailing ## section stops parse → [405]"
    else
        fail "P7: expected [405], got $out"
    fi
}

test_P8_inline_comment_skipped() {
    require_parser "P8_inline_comment_skipped" || return
    local f="$TMPDIR_BASE/p8-intent.md"
    printf '## closes_issues\n- 405 # comment\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[]" ]; then
        pass "P8: '- 405 # comment' is skipped (strict regex) → []"
    else
        fail "P8: expected [] (strict regex skips inline-comment), got $out"
    fi
}

# ============ S-series: worktree-notes.js buildNotesBody schema extension ============

notes_body_eval() {
    run_with_timeout 120 node -e "
        const m = require('${NOTES_JS}');
        const body = m.buildNotesBody({
            branch: 'feature/x',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: []
        });
        process.stdout.write(body);
    " 2>/dev/null
}

test_S1_three_sections_present() {
    require_notes_lib "S1_three_sections_present" || return
    local body; body="$(notes_body_eval)"
    if echo "$body" | grep -q "^## BugsFound$" \
       && echo "$body" | grep -q "^## RelatedTasks$" \
       && echo "$body" | grep -q "^## NextTasks$"; then
        pass "S1: BugsFound / RelatedTasks / NextTasks sections present"
    else
        fail "S1: one or more new sections missing
$body"
    fi
}

test_S2_section_order() {
    require_notes_lib "S2_section_order" || return
    local body; body="$(notes_body_eval)"
    local ln_copied ln_bugs ln_related ln_next
    ln_copied="$(echo "$body" | grep -n "^## Gitignored files copied from main$" | head -1 | cut -d: -f1)"
    ln_bugs="$(echo "$body" | grep -n "^## BugsFound$" | head -1 | cut -d: -f1)"
    ln_related="$(echo "$body" | grep -n "^## RelatedTasks$" | head -1 | cut -d: -f1)"
    ln_next="$(echo "$body" | grep -n "^## NextTasks$" | head -1 | cut -d: -f1)"

    if [ -n "$ln_copied" ] && [ -n "$ln_bugs" ] && [ -n "$ln_related" ] && [ -n "$ln_next" ] \
       && [ "$ln_copied" -lt "$ln_bugs" ] \
       && [ "$ln_bugs" -lt "$ln_related" ] \
       && [ "$ln_related" -lt "$ln_next" ]; then
        pass "S2: section order Gitignored < BugsFound < RelatedTasks < NextTasks"
    else
        fail "S2: order wrong (copied=$ln_copied bugs=$ln_bugs related=$ln_related next=$ln_next)"
    fi
}

test_S3_byte_exact_new_sections() {
    require_notes_lib "S3_byte_exact_new_sections" || return
    local body; body="$(notes_body_eval)"
    local expected_tail
    expected_tail="$(printf '%s\n' \
        '' \
        '## BugsFound' \
        '- (none)' \
        '' \
        '## RelatedTasks' \
        '- (none)' \
        '' \
        '## NextTasks' \
        '- (none)')"
    if echo "$body" | grep -qF "$expected_tail"; then
        pass "S3: byte-exact 3-section block with '- (none)' bullets + blank line separators"
    else
        fail "S3: exact tail block not found
--- body ---
$body
--- expected tail ---
$expected_tail"
    fi
}

# ============ K-series: renderSkeleton (post-#771) ============

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
    echo "$out" | grep -q "^### Next Tasks$"               || ok=0

    if [ "$ok" = "1" ]; then
        pass "K1: renderSkeleton contains H2 and all 9 ### headings"
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
               "<BUGS_FOUND>" "<RELATED_TASKS>" "<NEXT_TASKS>"; do
        if ! echo "$out" | grep -qF "$tok"; then
            ok=0
            echo "  K3 missing token: $tok"
        fi
    done

    if [ "$ok" = "1" ]; then
        pass "K3: skeleton has block placeholders (CLOSED_ISSUES_LIST/CLOSED_ISSUE_OUTCOMES/BUGS_FOUND/RELATED_TASKS/NEXT_TASKS)"
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
    if grep -qF "outcome data not found — investigate" "$SESSION_CLOSE_SKILL_MD"; then
        pass "K5: session-close SKILL.md contains outcome-absent fallback text"
    else
        fail "K5: SKILL.md missing 'outcome data not found — investigate' fallback"
    fi
}

test_K6_skill_md_notes_absent_fallback() {
    require_session_close_skill "K6_skill_md_notes_absent_fallback" || return
    # Look for the "- (none)" fallback being referenced for the findings blocks.
    if grep -qF -- "- (none)" "$SESSION_CLOSE_SKILL_MD"; then
        pass "K6: session-close SKILL.md references '- (none)' notes-absent fallback"
    else
        fail "K6: SKILL.md missing '- (none)' notes-absent fallback marker"
    fi
}

# ============ I-series: integration invariants ============
# (R/T renderer tests removed in #771; I3–I6 kept since they test SKILL.md
# structural invariants that are still relevant.)

test_I3_skill_md_grep_invariant() {
    require_skill_md "I3_skill_md_grep_invariant" || return
    local count
    count="$(grep '^7\. \*\*Final report' "$SKILL_MD" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" = "0" ]; then
        pass "I3: SKILL.md Step 7 Final report heading correctly absent (moved to /session-close)"
    else
        fail "I3: expected 0 occurrences of '7. **Final report' (Step 7 removed in #608), got $count"
    fi
}

test_I4_skill_md_has_step_5_5() {
    require_skill_md "I4_skill_md_has_step_5_5" || return
    local ln5 ln55 ln6
    ln5="$(grep -n '^5\. ' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln55="$(grep -n '^5\.5\.' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln6="$(grep -n '^6\. ' "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -n "$ln5" ] && [ -n "$ln55" ] && [ -n "$ln6" ] \
       && [ "$ln5" -lt "$ln55" ] && [ "$ln55" -lt "$ln6" ]; then
        pass "I4: Step 5.5 sits between Step 5 (line $ln5) and Step 6 (line $ln6) at line $ln55"
    else
        fail "I4: ordering wrong (5=$ln5 5.5=$ln55 6=$ln6)"
    fi
}

test_I5_no_eval_in_skill_md() {
    require_skill_md "I5_no_eval_in_skill_md" || return
    local ln55 ln6
    ln55="$(grep -n '^5\.5\.' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln6="$(grep -n '^6\. '   "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -z "$ln55" ] || [ -z "$ln6" ]; then
        fail "I5: could not locate Step 5.5 or Step 6 in SKILL.md"
        return
    fi
    local region
    region="$(awk -v a="$ln55" -v b="$ln6" 'NR>=a && NR<b' "$SKILL_MD")"
    if echo "$region" | grep -qE '\beval\b'; then
        fail "I5: Step 5.5 region contains 'eval' (unsafe pattern)"
    else
        pass "I5: no 'eval' in Step 5.5 / Step 7 region"
    fi
}

test_I6_backup_vars_defined_in_step5() {
    require_skill_md "I6_backup_vars_defined_in_step5" || return
    local ln5 ln_end
    ln5="$(grep -n '^5\. ' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln_end="$(grep -n '^5\.5\.' "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -z "$ln_end" ]; then
        ln_end="$(grep -n '^6\. ' "$SKILL_MD" | head -1 | cut -d: -f1)"
    fi
    if [ -z "$ln5" ] || [ -z "$ln_end" ]; then
        fail "I6: could not locate Step 5 or end-of-Step-5 in SKILL.md"
        return
    fi
    local region
    region="$(awk -v a="$ln5" -v b="$ln_end" 'NR>=a && NR<b' "$SKILL_MD")"
    if echo "$region" | grep -qF "BACKUP_DIR=" \
       && echo "$region" | grep -qF "BACKUP_MANIFEST_PATH="; then
        pass "I6: Step 5 region defines BACKUP_DIR= and BACKUP_MANIFEST_PATH="
    else
        fail "I6: BACKUP_DIR= and/or BACKUP_MANIFEST_PATH= missing from Step 5 region"
    fi
}

# detect-restart.sh failsafe + rules-reason — still relevant; not touched by #771
test_I12_detect_restart_failsafe() {
    local detect_sh="$AGENTS_DIR/skills/worktree-end/scripts/detect-restart.sh"
    if [ ! -f "$detect_sh" ]; then
        skip "I12_detect_restart_failsafe (detect-restart.sh not found)"
        return
    fi
    local out
    out="$(run_with_timeout 30 bash -c 'unset AGENTS_CONFIG_DIR; PR_NUMBER="" bash "$1" ""' _ "$detect_sh" 2>/dev/null)"
    local lines; lines="$(printf '%s\n' "$out" | grep -cE '^(cc_restart|vscode_reload|installer_rerun|os_reboot)=not_required\|$')"
    if [ "$lines" = "4" ]; then
        pass "I12: detect-restart.sh fail-safe outputs all 4 categories as not_required|"
    else
        fail "I12: expected 4 not_required| lines, got $lines
$out"
    fi
}

_make_mock_gh() {
    local mock_dir="$1" body="$2"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\n%s\n' "$body" > "$mock_dir/gh"
    chmod +x "$mock_dir/gh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$mock_dir"
    else
        printf '%s' "$mock_dir"
    fi
}

test_I13_detect_restart_rules_reason() {
    local detect_sh="$AGENTS_DIR/skills/worktree-end/scripts/detect-restart.sh"
    if [ ! -f "$detect_sh" ]; then
        skip "I13_detect_restart_rules_reason (detect-restart.sh not found)"
        return
    fi
    local mock_dir="$TMPDIR_BASE/mock-gh-i13"
    local mock_posix; mock_posix="$(_make_mock_gh "$mock_dir" 'echo "rules/workflow-off.md"')"

    local out
    out="$(run_with_timeout 30 \
           env PATH="$mock_posix:$PATH" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
           bash "$detect_sh" "999" 2>/dev/null)"

    if printf '%s\n' "$out" | grep -qF 'cc_restart=required|rules/ modified in PR (cascaded into CLAUDE.md)'; then
        pass "I13: detect-restart.sh rules/ file → cc_restart=required|rules/ modified in PR (cascaded into CLAUDE.md)"
    else
        fail "I13: expected 'cc_restart=required|rules/ modified in PR (cascaded into CLAUDE.md)', got:
$out"
    fi
}

test_I13b_detect_restart_rules_and_claude_priority() {
    local detect_sh="$AGENTS_DIR/skills/worktree-end/scripts/detect-restart.sh"
    if [ ! -f "$detect_sh" ]; then
        skip "I13b_detect_restart_rules_and_claude_priority (detect-restart.sh not found)"
        return
    fi
    local mock_dir="$TMPDIR_BASE/mock-gh-i13b"
    local mock_posix; mock_posix="$(_make_mock_gh "$mock_dir" 'printf "CLAUDE.md\nrules/workflow-off.md\n"')"

    local out
    out="$(run_with_timeout 30 \
           env PATH="$mock_posix:$PATH" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
           bash "$detect_sh" "999" 2>/dev/null)"

    if printf '%s\n' "$out" | grep -qF 'cc_restart=required|CLAUDE.md modified in PR'; then
        pass "I13b: CLAUDE.md + rules/ → CLAUDE.md arm takes priority"
    else
        fail "I13b: expected 'cc_restart=required|CLAUDE.md modified in PR', got:
$out"
    fi
}

test_I11_skill_md_step5_5_node_json_write() {
    require_skill_md "I11_skill_md_step5_5_node_json_write" || return
    local ln55 ln6
    ln55="$(grep -n '^5\.5\.' "$SKILL_MD" | head -1 | cut -d: -f1)"
    ln6="$(grep -n '^6\. ' "$SKILL_MD" | head -1 | cut -d: -f1)"
    if [ -z "$ln55" ] || [ -z "$ln6" ]; then
        skip "I11_skill_md_step5_5_node_json_write (Step 5.5 region not found)"
        return
    fi
    local region
    region="$(awk -v a="$ln55" -v b="$ln6" 'NR>=a && NR<b' "$SKILL_MD")"
    local has_capture=0 has_json=0
    if echo "$region" | grep -qF "capture-env.sh"; then has_capture=1; fi
    if echo "$region" | grep -qF "final-report-env.json"; then has_json=1; fi
    if [ "$has_capture" = "1" ] && [ "$has_json" = "1" ]; then
        pass "I11: SKILL.md Step 5.5 invokes capture-env.sh and references final-report-env.json"
    else
        fail "I11: Step 5.5 missing capture-env.sh(=$has_capture) or final-report-env.json(=$has_json)"
    fi
}

# ============ Run all ============

test_P1_happy_single
test_P2_happy_multi
test_P3_empty_literal
test_P4_missing_section
test_P5_missing_file
test_P6_non_integer_skipped
test_P7_trailing_section_stops_parse
test_P8_inline_comment_skipped

test_S1_three_sections_present
test_S2_section_order
test_S3_byte_exact_new_sections

test_K1_skeleton_has_h2_and_nine_h3
test_K2_skeleton_has_field_placeholders
test_K3_skeleton_has_block_placeholders
test_K4_skeleton_post_merge_categories
test_K5_skill_md_outcome_absent_fallback
test_K6_skill_md_notes_absent_fallback

test_I3_skill_md_grep_invariant
test_I4_skill_md_has_step_5_5
test_I5_no_eval_in_skill_md
test_I6_backup_vars_defined_in_step5

test_I12_detect_restart_failsafe
test_I13_detect_restart_rules_reason
test_I13b_detect_restart_rules_and_claude_priority

test_I11_skill_md_step5_5_node_json_write

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
