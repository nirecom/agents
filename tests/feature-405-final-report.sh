#!/bin/bash
# tests/feature-405-final-report.sh
# Tests: hooks/lib/parse-closes-issues.js, hooks/lib/worktree-notes.js, bin/worktree-final-report.js, skills/worktree-end/SKILL.md
# Tags: 405, final-report, worktree-end, parse-closes-issues
#
# Issue #405 — Final Report feature.
#
# Test-first: most cases either SKIP (source missing) or FAIL until the
# implementation lands. Once implemented per the contract, all should PASS.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PARSE_JS="${_AGENTS_DIR_NODE}/hooks/lib/parse-closes-issues.js"
NOTES_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes.js"
REPORT_JS="${_AGENTS_DIR_NODE}/bin/worktree-final-report.js"
SKILL_MD="${AGENTS_DIR}/skills/worktree-end/SKILL.md"

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
# Usage: parse_eval <intent.md path (host)>
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

require_report_bin() {
    if [ ! -f "$REPORT_JS" ]; then
        skip "$1 (bin/worktree-final-report.js not implemented yet)"
        return 1
    fi
    return 0
}

SCHEMA_JS="${_AGENTS_DIR_NODE}/hooks/lib/final-report-schema.js"

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

# Run the Final Report CLI. Caller sets env vars and passes paths.
# Usage: run_report <intent path> <notes path> <session id>
run_report() {
    local intent="$1" notes="$2" sid="$3"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "$notes" "$sid" 2>/dev/null
}

run_report_exitcode() {
    local intent="$1" notes="$2" sid="$3"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "$notes" "$sid" >/dev/null 2>&1
    echo "$?"
}

run_report_stderr() {
    local intent="$1" notes="$2" sid="$3"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "$notes" "$sid" 2>&1 >/dev/null
}

# Run renderer with --env-file; discards stderr.
# Usage: run_report_with_envfile <intent> <notes> <sid> <envfile>
# Note: a literal `--` separator is inserted before --env-file so Node's
# own --env-file option (built-in since Node 20) does NOT intercept it.
# The script's argv handling must accept the flag from either position.
run_report_with_envfile() {
    local intent="$1" notes="$2" sid="$3" envfile="$4"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "$notes" "$sid" -- --env-file "$envfile" 2>/dev/null
}

# Run renderer with --env-file; merges stderr into stdout.
# Usage: run_report_with_envfile_capture_all <intent> <notes> <sid> <envfile>
run_report_with_envfile_capture_all() {
    local intent="$1" notes="$2" sid="$3" envfile="$4"
    run_with_timeout 120 node "$REPORT_JS" "$intent" "$notes" "$sid" -- --env-file "$envfile" 2>&1
}

# Run renderer with a JSON envfile constructed from a string literal.
# Usage: run_report_with_categories <intent_node> <notes_node> <sid> <json_string>
# json_string: a JSON object string, e.g.
#   '{"CC_RESTART_REQUIRED":"required","CC_RESTART_REASON":"CLAUDE.md modified in PR"}'
run_report_with_categories() {
    local intent="$1" notes="$2" sid="$3" json="$4"
    local envfile="$TMPDIR_BASE/${sid}-cat-env.json"
    printf '%s\n' "$json" > "$envfile"
    local envfile_node; envfile_node="$(node_path "$envfile")"
    run_report_with_envfile "$intent" "$notes" "$sid" "$envfile_node"
}

SENTINEL='<<WORKFLOW_MARK_STEP_final_report_complete>>'

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
    # Also check exit code is 0
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

# Get buildNotesBody output with minimal args.
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
    # Exact suffix expected after the "Gitignored ... \n- (none)" block.
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

# ============ R-series: bin/worktree-final-report.js ============

# Standard fixture: writes intent.md + notes.md into TMPDIR and echoes their paths.
# Usage: build_report_fixture <name> <closes_issues lines> <notes findings block>
make_intent_with_closes() {
    local f="$1"; shift
    local block="$1"
    {
      echo '# Intent'
      echo ''
      echo '## closes_issues'
      printf '%s\n' "$block"
    } > "$f"
}

make_notes_full() {
    local f="$1"
    {
      echo '# Worktree Notes'
      echo 'Branch: feature/x'
      echo ''
      echo '## Gitignored files copied from main'
      echo '- (none)'
      echo ''
      echo '## BugsFound'
      echo '- bug A'
      echo '- bug B'
      echo ''
      echo '## RelatedTasks'
      echo '- related X'
      echo ''
      echo '## NextTasks'
      echo '- next Y'
    } > "$f"
}

test_R1_happy_path() {
    require_report_bin "R1_happy_path" || return
    local intent="$TMPDIR_BASE/r1-intent.md"
    local notes="$TMPDIR_BASE/r1-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"

    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(MSYS_NO_PATHCONV=1 PR_NUMBER=42 PR_TITLE='Add final report' PR_URL='https://github.com/x/y/pull/42' \
           PR_STATE=MERGED BRANCH='feature/405-final-report' \
           WORKTREE_PATH='/tmp/wt' CREATED_DATE='2024-01-15' \
           BACKUP_MANIFEST_PATH='/tmp/backup.json' BRANCH_DELETED='feature/x' \
           run_report "$intent_node" "$notes_node" "sess-abc")"

    if echo "$out" | grep -q "^## Final Report — sess-abc" \
       && echo "$out" | grep -q "^### Closed Issues" \
       && echo "$out" | grep -qF -- "- #405" \
       && echo "$out" | grep -q "^### Merged PR" \
       && echo "$out" | grep -qF "PR #42: Add final report" \
       && echo "$out" | grep -qF "https://github.com/x/y/pull/42" \
       && echo "$out" | grep -q "^### Worktree" \
       && echo "$out" | grep -qF "Branch: feature/405-final-report" \
       && echo "$out" | grep -qF "Path: /tmp/wt" \
       && echo "$out" | grep -q "^### Backup" \
       && echo "$out" | grep -qF "Manifest: /tmp/backup.json" \
       && echo "$out" | grep -q "^### Bugs Found" \
       && echo "$out" | grep -qF -- "- bug A" \
       && echo "$out" | grep -qF -- "- bug B" \
       && echo "$out" | grep -q "^### Related Tasks" \
       && echo "$out" | grep -qF -- "- related X" \
       && echo "$out" | grep -q "^### Next Tasks" \
       && echo "$out" | grep -qF -- "- next Y"; then
        pass "R1: happy path — all sections rendered with substituted values"
    else
        fail "R1: missing expected sections / values
--- output ---
$out"
    fi
}

test_R2_empty_closed_issues() {
    require_report_bin "R2_empty_closed_issues" || return
    local intent="$TMPDIR_BASE/r2-intent.md"
    local notes="$TMPDIR_BASE/r2-notes.md"
    make_intent_with_closes "$intent" "(empty)"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out; out="$(run_report "$intent_node" "$notes_node" "sess-r2")"
    # Find the line right after "### Closed Issues" and verify it's "(none)"
    local closed_block
    closed_block="$(echo "$out" | awk '/^### Closed Issues$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$closed_block" | grep -qF "(none)"; then
        pass "R2: closes_issues '(empty)' → Closed Issues block contains '(none)'"
    else
        fail "R2: Closed Issues block missing '(none)'
--- closed block ---
$closed_block"
    fi
}

test_R3_none_default_missing_section() {
    require_report_bin "R3_none_default_missing_section" || return
    local intent="$TMPDIR_BASE/r3-intent.md"
    local notes="$TMPDIR_BASE/r3-notes.md"
    make_intent_with_closes "$intent" "- 405"
    # Notes file missing NextTasks section
    {
      echo '# Worktree Notes'
      echo ''
      echo '## BugsFound'
      echo '- (none)'
      echo ''
      echo '## RelatedTasks'
      echo '- (none)'
    } > "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out; out="$(run_report "$intent_node" "$notes_node" "sess-r3")"
    local next_block
    next_block="$(echo "$out" | awk '/^### Next Tasks$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$next_block" | grep -qF "(none)"; then
        pass "R3: notes missing ## NextTasks → '### Next Tasks' renders '(none)'"
    else
        fail "R3: Next Tasks did not default to '(none)'
--- next block ---
$next_block"
    fi
}

test_R4_missing_notes_file() {
    require_report_bin "R4_missing_notes_file" || return
    local intent="$TMPDIR_BASE/r4-intent.md"
    local notes="$TMPDIR_BASE/r4-NONEXISTENT.md"
    make_intent_with_closes "$intent" "- 405"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local code; code="$(run_report_exitcode "$intent_node" "$notes_node" "sess-r4")"
    local out;  out="$(run_report "$intent_node" "$notes_node" "sess-r4")"

    if [ "$code" = "0" ] \
       && echo "$out" | awk '/^### Bugs Found$/{f=1;next} /^### /{f=0} f' | grep -qF "(none)" \
       && echo "$out" | awk '/^### Related Tasks$/{f=1;next} /^### /{f=0} f' | grep -qF "(none)" \
       && echo "$out" | awk '/^### Next Tasks$/{f=1;next} /^### /{f=0} f' | grep -qF "(none)"; then
        pass "R4: missing notes file → exit 0, all findings sections '(none)'"
    else
        fail "R4: code=$code, output:
$out"
    fi
}

test_R5_missing_intent_file() {
    require_report_bin "R5_missing_intent_file" || return
    local intent="$TMPDIR_BASE/r5-NONEXISTENT-intent.md"
    local notes="$TMPDIR_BASE/r5-notes.md"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local code; code="$(run_report_exitcode "$intent_node" "$notes_node" "sess-r5")"
    local out;  out="$(run_report "$intent_node" "$notes_node" "sess-r5")"
    local closed_block
    closed_block="$(echo "$out" | awk '/^### Closed Issues$/{flag=1;next} /^### /{flag=0} flag')"

    if [ "$code" = "0" ] && echo "$closed_block" | grep -qF "(none)"; then
        pass "R5: missing intent file → exit 0, Closed Issues '(none)'"
    else
        fail "R5: code=$code, closed_block=$closed_block"
    fi
}

test_R6_uses_shared_parser() {
    require_report_bin "R6_uses_shared_parser" || return
    if grep -qF "parseClosesIssues" "$REPORT_JS"; then
        # No standalone duplicate regex — check that there's no second-impl
        # `closes_issues` token paired with a regex literal pattern.
        if grep -E "closes_issues" "$REPORT_JS" | grep -qE "/.*\^.*-.*\\\\d.*/"; then
            fail "R6: bin/worktree-final-report.js appears to contain its own closes_issues regex (SSOT violation)"
        else
            pass "R6: bin/worktree-final-report.js uses shared parseClosesIssues (no duplicate regex)"
        fi
    else
        fail "R6: bin/worktree-final-report.js does not reference parseClosesIssues"
    fi
}

test_R7_pr_state_passthrough() {
    require_report_bin "R7_pr_state_passthrough" || return
    local intent="$TMPDIR_BASE/r7-intent.md"
    local notes="$TMPDIR_BASE/r7-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(PR_STATE=MERGED PR_NUMBER=99 PR_TITLE='t' PR_URL='https://x/y/pull/99' \
           run_report "$intent_node" "$notes_node" "sess-r7")"
    if echo "$out" | grep -qF "State: MERGED"; then
        pass "R7: PR_STATE=MERGED → stdout contains 'State: MERGED'"
    else
        fail "R7: 'State: MERGED' not found in output
$out"
    fi
}

test_R8_pr_title_injection_safe() {
    require_report_bin "R8_pr_title_injection_safe" || return
    local intent="$TMPDIR_BASE/r8-intent.md"
    local notes="$TMPDIR_BASE/r8-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local marker="$TMPDIR_BASE/r8-injection-canary.txt"
    rm -f "$marker"
    local evil_title='evil"$(touch '"$marker"')'

    local code; code="$(PR_TITLE="$evil_title" PR_NUMBER=1 PR_URL='https://x/y/pull/1' PR_STATE=MERGED \
                       run_report_exitcode "$intent_node" "$notes_node" "sess-r8")"
    local out;  out="$(PR_TITLE="$evil_title" PR_NUMBER=1 PR_URL='https://x/y/pull/1' PR_STATE=MERGED \
                       run_report "$intent_node" "$notes_node" "sess-r8")"

    if [ "$code" = "0" ] && [ ! -f "$marker" ] \
       && echo "$out" | grep -qF "$evil_title"; then
        pass "R8: PR_TITLE with shell metacharacters → exit 0, no injection, literal title preserved"
    else
        fail "R8: code=$code; marker exists? $(test -f "$marker" && echo yes || echo no); output substring match? $(echo "$out" | grep -qF "$evil_title" && echo yes || echo no)"
    fi
}

# ============ R9-R14: ### Post-Merge Actions Required (always-on, multi-category) ============

test_R9_post_merge_section_always_present() {
    require_report_bin "R9_post_merge_section_always_present" || return
    local intent="$TMPDIR_BASE/r9-intent.md"
    local notes="$TMPDIR_BASE/r9-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(unset AGENTS_CONFIG_DIR; PR_NUMBER=1 \
           run_report "$intent_node" "$notes_node" "sess-r9")"

    if echo "$out" | grep -q '^### Post-Merge Actions Required$'; then
        pass "R9: ### Post-Merge Actions Required present even when AGENTS_CONFIG_DIR is unset"
    else
        fail "R9: ### Post-Merge Actions Required missing from output
$out"
    fi
}

test_R10_cc_restart_yes() {
    require_report_bin "R10_cc_restart_yes" || return
    local intent="$TMPDIR_BASE/r10-intent.md"
    local notes="$TMPDIR_BASE/r10-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r10" \
           '{"CC_RESTART_REQUIRED":"required","CC_RESTART_REASON":"CLAUDE.md modified in PR"}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$block" | grep -qF -- '- Claude Code restart: required (CLAUDE.md modified in PR)'; then
        pass "R10: CC_RESTART_REQUIRED=required → '- Claude Code restart: required (CLAUDE.md modified in PR)'"
    else
        fail "R10: expected cc_restart required line in Post-Merge block
$block"
    fi
}

test_R10b_cc_restart_rules_reason() {
    require_report_bin "R10b_cc_restart_rules_reason" || return
    local intent="$TMPDIR_BASE/r10b-intent.md"
    local notes="$TMPDIR_BASE/r10b-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r10b" \
           '{"CC_RESTART_REQUIRED":"required","CC_RESTART_REASON":"rules/ modified in PR (cascaded into CLAUDE.md)"}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$block" | grep -qF -- '- Claude Code restart: required (rules/ modified in PR (cascaded into CLAUDE.md))'; then
        pass "R10b: rules/ reason → '- Claude Code restart: required (rules/ modified in PR (cascaded into CLAUDE.md))'"
    else
        fail "R10b: expected rules/ reason line in Post-Merge block
$block"
    fi
}

test_R11_cc_restart_no() {
    require_report_bin "R11_cc_restart_no" || return
    local intent="$TMPDIR_BASE/r11-intent.md"
    local notes="$TMPDIR_BASE/r11-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r11" \
           '{"CC_RESTART_REQUIRED":"not_required"}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$block" | grep -qF -- '- Claude Code restart: not_required'; then
        pass "R11: CC_RESTART_REQUIRED=not_required → '- Claude Code restart: not_required'"
    else
        fail "R11: expected cc_restart not_required line in Post-Merge block
$block"
    fi
}

test_R12_all_categories_default_not_required() {
    require_report_bin "R12_all_categories_default_not_required" || return
    local intent="$TMPDIR_BASE/r12-intent.md"
    local notes="$TMPDIR_BASE/r12-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r12" '{}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    local nr_count
    nr_count="$(echo "$block" | grep -cE 'not_required')"
    if [ "$nr_count" = "4" ]; then
        pass "R12: empty envFile → all 4 category lines render as not_required"
    else
        fail "R12: expected 4 not_required lines, got $nr_count
$block"
    fi
}

test_R13_legacy_alias_yes() {
    require_report_bin "R13_legacy_alias_yes" || return
    local intent="$TMPDIR_BASE/r13-intent.md"
    local notes="$TMPDIR_BASE/r13-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r13" \
           '{"CLAUDE_CODE_RESTART_REQUIRED":"yes"}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$block" | grep -qE '^- Claude Code restart: required'; then
        pass "R13: legacy CLAUDE_CODE_RESTART_REQUIRED=yes alias → cc_restart renders as required"
    else
        fail "R13: expected cc_restart line to render as required via legacy alias
$block"
    fi
}

test_R14_post_merge_section_position() {
    require_report_bin "R14_post_merge_section_position" || return
    local intent="$TMPDIR_BASE/r14-intent.md"
    local notes="$TMPDIR_BASE/r14-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(unset AGENTS_CONFIG_DIR; PR_NUMBER=1 \
           run_report "$intent_node" "$notes_node" "sess-r14")"

    local backup_line post_merge_line bugs_line
    backup_line="$(echo "$out" | grep -n '^### Backup$' | cut -d: -f1)"
    post_merge_line="$(echo "$out" | grep -n '^### Post-Merge Actions Required$' | cut -d: -f1)"
    bugs_line="$(echo "$out" | grep -n '^### Bugs Found$' | cut -d: -f1)"

    if [ -n "$post_merge_line" ] && [ -n "$backup_line" ] && [ -n "$bugs_line" ] \
       && [ "$backup_line" -lt "$post_merge_line" ] && [ "$post_merge_line" -lt "$bugs_line" ]; then
        pass "R14: ### Post-Merge Actions Required is between ### Backup (line $backup_line) and ### Bugs Found (line $bugs_line)"
    else
        fail "R14: section position wrong — Backup:$backup_line Post-Merge:$post_merge_line BugsFound:$bugs_line
$out"
    fi
}

# ============ R19-R24: additional Post-Merge category coverage ============

test_R19_post_merge_always_present() {
    require_report_bin "R19_post_merge_always_present" || return
    local intent="$TMPDIR_BASE/r19-intent.md"
    local notes="$TMPDIR_BASE/r19-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(unset AGENTS_CONFIG_DIR; PR_NUMBER=1 \
           run_report "$intent_node" "$notes_node" "sess-r19")"

    if echo "$out" | grep -q '^### Post-Merge Actions Required$'; then
        pass "R19: plain run_report (no env) → ### Post-Merge Actions Required present"
    else
        fail "R19: section missing
$out"
    fi
}

test_R20_all_four_categories_present() {
    require_report_bin "R20_all_four_categories_present" || return
    local intent="$TMPDIR_BASE/r20-intent.md"
    local notes="$TMPDIR_BASE/r20-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r20" '{}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    local bullets
    bullets="$(echo "$block" | grep -cE '^- ')"
    if [ "$bullets" = "4" ]; then
        pass "R20: Post-Merge block has exactly 4 '^- ' lines (all four categories rendered)"
    else
        fail "R20: expected 4 bullet lines, got $bullets
$block"
    fi
}

test_R21_vscode_reload_required() {
    require_report_bin "R21_vscode_reload_required" || return
    local intent="$TMPDIR_BASE/r21-intent.md"
    local notes="$TMPDIR_BASE/r21-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r21" \
           '{"VSCODE_RELOAD_REQUIRED":"required","VSCODE_RELOAD_REASON":"keybindings.json modified"}')"

    if echo "$out" | grep -qF -- '- VS Code reload: required (keybindings.json modified)'; then
        pass "R21: VSCODE_RELOAD_REQUIRED=required + reason → expected line rendered"
    else
        fail "R21: expected '- VS Code reload: required (keybindings.json modified)' in output
$out"
    fi
}

test_R22_installer_rerun_required() {
    require_report_bin "R22_installer_rerun_required" || return
    local intent="$TMPDIR_BASE/r22-intent.md"
    local notes="$TMPDIR_BASE/r22-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r22" \
           '{"INSTALLER_RERUN_REQUIRED":"required","INSTALLER_RERUN_REASON":"install.ps1 modified in PR"}')"

    if echo "$out" | grep -qF -- '- Installer rerun: required (install.ps1 modified in PR)'; then
        pass "R22: INSTALLER_RERUN_REQUIRED=required + reason → expected line rendered"
    else
        fail "R22: expected '- Installer rerun: required (install.ps1 modified in PR)' in output
$out"
    fi
}

test_R23_os_reboot_required() {
    require_report_bin "R23_os_reboot_required" || return
    local intent="$TMPDIR_BASE/r23-intent.md"
    local notes="$TMPDIR_BASE/r23-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r23" \
           '{"OS_REBOOT_REQUIRED":"required","OS_REBOOT_REASON":"manual env override"}')"

    if echo "$out" | grep -qF -- '- OS reboot: required (manual env override)'; then
        pass "R23: OS_REBOOT_REQUIRED=required + reason → expected line rendered"
    else
        fail "R23: expected '- OS reboot: required (manual env override)' in output
$out"
    fi
}

test_R24_legacy_cc_restart_no() {
    require_report_bin "R24_legacy_cc_restart_no" || return
    local intent="$TMPDIR_BASE/r24-intent.md"
    local notes="$TMPDIR_BASE/r24-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(run_report_with_categories "$intent_node" "$notes_node" "sess-r24" \
           '{"CLAUDE_CODE_RESTART_REQUIRED":"no"}')"

    local block
    block="$(echo "$out" | awk '/^### Post-Merge Actions Required$/{flag=1;next} /^### /{flag=0} flag')"
    if echo "$block" | grep -qF -- '- Claude Code restart: not_required'; then
        pass "R24: legacy CLAUDE_CODE_RESTART_REQUIRED=no → cc_restart renders as not_required"
    else
        fail "R24: expected '- Claude Code restart: not_required' in Post-Merge block
$block"
    fi
}

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
    # Create a mock gh script in $1 directory that outputs $2 (one path per line).
    # Returns the POSIX-form path suitable for PATH prepend (handles Windows drive-letter paths).
    local mock_dir="$1" body="$2"
    mkdir -p "$mock_dir"
    printf '#!/bin/bash\n%s\n' "$body" > "$mock_dir/gh"
    chmod +x "$mock_dir/gh"
    # Return POSIX path for PATH prepend via stdout
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
    # Mock gh: returns a rules/ file path — simulates a PR that only modified rules/
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
    # Mock gh: returns both CLAUDE.md and a rules/ file — CLAUDE.md arm takes priority
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

# ============ I-series: integration invariants ============

test_I1_step5_5_capture_then_remove() {
    require_report_bin "I1_step5_5_capture_then_remove" || return
    # Simulate Step 5.5: capture notes from worktree into a backup dir,
    # then Step 6c removes the worktree, then Step 7 runs the CLI against
    # the backed-up notes path.
    local wt="$TMPDIR_BASE/i1-wt"
    mkdir -p "$wt"
    make_notes_full "$wt/WORKTREE_NOTES.md"

    local backup_dir="$TMPDIR_BASE/i1-backup"
    mkdir -p "$backup_dir"
    cp "$wt/WORKTREE_NOTES.md" "$backup_dir/WORKTREE_NOTES.md"

    # Simulate Step 6c worktree removal
    rm -rf "$wt"

    local intent="$TMPDIR_BASE/i1-intent.md"
    make_intent_with_closes "$intent" "- 405"

    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$backup_dir/WORKTREE_NOTES.md")"

    local out; out="$(run_report "$intent_node" "$notes_node" "sess-i1")"

    if echo "$out" | grep -qF -- "- bug A" \
       && echo "$out" | grep -qF -- "- related X" \
       && echo "$out" | grep -qF -- "- next Y"; then
        pass "I1: Step 5.5 capture-then-remove preserves findings into Final Report"
    else
        fail "I1: findings not preserved after simulated remove
$out"
    fi
}

test_I2_step5_5_no_backup() {
    require_report_bin "I2_step5_5_no_backup" || return
    local intent="$TMPDIR_BASE/i2-intent.md"
    make_intent_with_closes "$intent" "- 405"
    local intent_node; intent_node="$(node_path "$intent")"

    # Empty notes path → CLI receives "" as 2nd arg. Use a non-existent path
    # under TMPDIR to simulate "no backup taken".
    local missing="$TMPDIR_BASE/i2-NEVER-EXISTED.md"
    local missing_node; missing_node="$(node_path "$missing")"

    local code; code="$(run_report_exitcode "$intent_node" "$missing_node" "sess-i2")"
    local out;  out="$(run_report "$intent_node" "$missing_node" "sess-i2")"
    local err;  err="$(run_report_stderr "$intent_node" "$missing_node" "sess-i2")"

    if [ "$code" = "0" ] \
       && echo "$out" | awk '/^### Bugs Found$/{f=1;next} /^### /{f=0} f' | grep -qF "(none)" \
       && [ -n "$err" ]; then
        pass "I2: no backup → exit 0, findings '(none)', stderr warning"
    else
        # Don't strictly require stderr warning if CLI is silent — accept exit 0 + (none)
        if [ "$code" = "0" ] \
           && echo "$out" | awk '/^### Bugs Found$/{f=1;next} /^### /{f=0} f' | grep -qF "(none)"; then
            pass "I2: no backup → exit 0, findings '(none)' (stderr warning optional)"
        else
            fail "I2: code=$code, stderr=$err
$out"
        fi
    fi
}

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
    # Inspect range [ln55, ln6) for any \beval\b occurrences
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
    # End-of-region is the line at "5.5." or, failing that, "6. "
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

# ============ R15-R18, R17b, I7-I11: --env-file / sentinel / SKILL.md ============

test_R15_sentinel_in_stdout() {
    require_report_bin "R15_sentinel_in_stdout" || return
    local intent="$TMPDIR_BASE/r15-intent.md"
    local notes="$TMPDIR_BASE/r15-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out; out="$(run_report "$intent_node" "$notes_node" "sess-r15")"
    if echo "$out" | grep -qF "$SENTINEL"; then
        pass "R15: stdout contains sentinel $SENTINEL"
    else
        fail "R15: sentinel missing from stdout
--- output ---
$out"
    fi
}

test_R16_envfile_values_adopted() {
    require_report_bin "R16_envfile_values_adopted" || return
    local intent="$TMPDIR_BASE/r16-intent.md"
    local notes="$TMPDIR_BASE/r16-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local envfile="$TMPDIR_BASE/r16-env.json"
    cat > "$envfile" <<'EOF'
{
  "PR_NUMBER": "777",
  "PR_TITLE": "From JSON",
  "BRANCH": "feature/json",
  "WORKTREE_PATH": "/tmp/json-wt"
}
EOF
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"
    local envfile_node; envfile_node="$(node_path "$envfile")"

    local out
    out="$(run_report_with_envfile "$intent_node" "$notes_node" "sess-r16" "$envfile_node")"
    if echo "$out" | grep -qF "PR #777" \
       && echo "$out" | grep -qF "feature/json" \
       && echo "$out" | grep -qF "/tmp/json-wt" \
       && echo "$out" | grep -qF "$SENTINEL"; then
        pass "R16: --env-file values adopted (PR #777, feature/json, /tmp/json-wt) + sentinel"
    else
        fail "R16: missing one of PR #777 / feature/json / /tmp/json-wt / sentinel
--- output ---
$out"
    fi
}

test_R17_envfile_missing_hard_fail() {
    require_report_bin "R17_envfile_missing_hard_fail" || return
    local intent="$TMPDIR_BASE/r17-intent.md"
    local notes="$TMPDIR_BASE/r17-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"
    local bogus="/nonexistent/path/env.json"

    local combined
    combined="$(run_report_with_envfile_capture_all "$intent_node" "$notes_node" "sess-r17" "$bogus")"
    run_with_timeout 120 node "$REPORT_JS" "$intent_node" "$notes_node" "sess-r17" -- --env-file "$bogus" >/dev/null 2>&1
    local code=$?

    local ok=1
    [ "$code" = "0" ] && ok=0
    echo "$combined" | grep -qF "$SENTINEL" && ok=0
    if ! echo "$combined" | grep -qF "FATAL"; then ok=0; fi
    if ! echo "$combined" | grep -qF -- "--env-file"; then ok=0; fi

    if [ "$ok" = "1" ]; then
        pass "R17: missing --env-file → non-zero exit, no sentinel, FATAL + --env-file in output"
    else
        fail "R17: code=$code; output:
$combined"
    fi
}

test_R17b_envfile_relative_hard_fail() {
    require_report_bin "R17b_envfile_relative_hard_fail" || return
    local intent="$TMPDIR_BASE/r17b-intent.md"
    local notes="$TMPDIR_BASE/r17b-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local bad
    local all_ok=1
    for bad in "./relative.json" "../traversal.json"; do
        local combined
        combined="$(run_report_with_envfile_capture_all "$intent_node" "$notes_node" "sess-r17b" "$bad")"
        run_with_timeout 120 node "$REPORT_JS" "$intent_node" "$notes_node" "sess-r17b" -- --env-file "$bad" >/dev/null 2>&1
        local code=$?
        local has_sent=0
        echo "$combined" | grep -qF "$SENTINEL" && has_sent=1
        if [ "$code" = "0" ] && [ "$has_sent" = "1" ]; then
            all_ok=0
            echo "  R17b debug: path '$bad' yielded exit 0 AND sentinel — neither failure path triggered"
        fi
    done

    if [ "$all_ok" = "1" ]; then
        pass "R17b: relative/traversal --env-file paths → exit non-zero OR sentinel absent"
    else
        fail "R17b: at least one relative/traversal path succeeded with sentinel"
    fi
}

test_R18_env_only_backward_compat() {
    require_report_bin "R18_env_only_backward_compat" || return
    local intent="$TMPDIR_BASE/r18-intent.md"
    local notes="$TMPDIR_BASE/r18-notes.md"
    make_intent_with_closes "$intent" "- 405"
    make_notes_full "$notes"
    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"

    local out
    out="$(PR_NUMBER=888 PR_TITLE='Env Only' BRANCH='feature/env-only' \
           run_report "$intent_node" "$notes_node" "sess-r18")"

    if echo "$out" | grep -qF "PR #888" \
       && echo "$out" | grep -qF "feature/env-only" \
       && echo "$out" | grep -qF "$SENTINEL"; then
        pass "R18: env-only backward compat (PR #888, feature/env-only, sentinel)"
    else
        fail "R18: missing expected env-only values or sentinel
--- output ---
$out"
    fi
}

test_I7_fat_call_env_reset_simulation() {
    require_report_bin "I7_fat_call_env_reset_simulation" || return
    # Skip if renderer doesn't yet support --env-file at all.
    if ! grep -qF -- "--env-file" "$REPORT_JS"; then
        skip "I7_fat_call_env_reset_simulation (renderer does not yet support --env-file)"
        return
    fi

    local intent="$TMPDIR_BASE/i7-intent.md"
    make_intent_with_closes "$intent" "(empty)"
    local envfile="$TMPDIR_BASE/i7-env.json"
    cat > "$envfile" <<'EOF'
{
  "PR_NUMBER": "42",
  "PR_TITLE": "Integ T",
  "PR_URL": "https://github.com/example/repo/pull/42",
  "PR_STATE": "MERGED",
  "BRANCH": "feature/i7",
  "WORKTREE_PATH": "/tmp/i7-wt",
  "CREATED_DATE": "2026-01-01",
  "BACKUP_MANIFEST_PATH": "",
  "NOTES_BACKUP_PATH": "",
  "CLAUDE_CODE_RESTART_REQUIRED": "no"
}
EOF
    local intent_node; intent_node="$(node_path "$intent")"
    local envfile_node; envfile_node="$(node_path "$envfile")"

    # Simulate env reset: unset all relevant vars, then invoke renderer.
    local out
    out="$(
        unset PR_NUMBER PR_TITLE PR_URL PR_STATE BRANCH WORKTREE_PATH \
              CREATED_DATE BACKUP_MANIFEST_PATH NOTES_BACKUP_PATH \
              CLAUDE_CODE_RESTART_REQUIRED BRANCH_DELETED
        run_with_timeout 120 node "$REPORT_JS" "$intent_node" "" "test-sid" -- --env-file "$envfile_node" 2>&1
    )"
    (
        unset PR_NUMBER PR_TITLE PR_URL PR_STATE BRANCH WORKTREE_PATH \
              CREATED_DATE BACKUP_MANIFEST_PATH NOTES_BACKUP_PATH \
              CLAUDE_CODE_RESTART_REQUIRED BRANCH_DELETED
        run_with_timeout 120 node "$REPORT_JS" "$intent_node" "" "test-sid" -- --env-file "$envfile_node" >/dev/null 2>&1
    )
    local code=$?

    local ok=1
    [ "$code" = "0" ] || ok=0
    echo "$out" | grep -qF "PR #42" || ok=0
    echo "$out" | grep -qF "feature/i7" || ok=0
    echo "$out" | grep -qF "/tmp/i7-wt" || ok=0
    echo "$out" | grep -qF "$SENTINEL" || ok=0
    if echo "$out" | grep -qF "BRANCH_DELETED: yes"; then ok=0; fi

    if [ "$ok" = "1" ]; then
        pass "I7: fat-call env reset simulation — values from JSON adopted, sentinel emitted"
    else
        fail "I7: code=$code; output:
$out"
    fi
}

# Extract Step N region from SKILL.md (heading line excluded; until next '### ').
extract_step_region() {
    local pattern="$1"
    awk -v pat="$pattern" '$0 ~ pat {f=1; next} /^### /{if(f)exit} f{print}' "$SKILL_MD"
}

test_I8_skill_md_step7_sentinel() {
    require_skill_md "I8_skill_md_step7_sentinel" || return
    local region; region="$(extract_step_region '^### .*[Ss]tep 7')"
    if [ -z "$region" ]; then
        skip "I8_skill_md_step7_sentinel (Step 7 region not found in SKILL.md)"
        return
    fi
    if echo "$region" | grep -qF "$SENTINEL"; then
        pass "I8: SKILL.md Step 7 contains sentinel literal"
    else
        fail "I8: SKILL.md Step 7 region missing sentinel
$region"
    fi
}

test_I9_skill_md_step7_envfile() {
    require_skill_md "I9_skill_md_step7_envfile" || return
    local region; region="$(extract_step_region '^### .*[Ss]tep 7')"
    if [ -z "$region" ]; then
        skip "I9_skill_md_step7_envfile (Step 7 region not found in SKILL.md)"
        return
    fi
    if ! echo "$region" | grep -qF "worktree-final-report"; then
        skip "I9_skill_md_step7_envfile (no worktree-final-report invocation in Step 7)"
        return
    fi
    if echo "$region" | grep -qF -- "--env-file"; then
        pass "I9: SKILL.md Step 7 invocation includes --env-file"
    else
        fail "I9: SKILL.md Step 7 has renderer call but no --env-file"
    fi
}

test_I10_skill_md_step7_no_notes_backup_var() {
    require_skill_md "I10_skill_md_step7_no_notes_backup_var" || return
    local region; region="$(extract_step_region '^### .*[Ss]tep 7')"
    if [ -z "$region" ]; then
        skip "I10_skill_md_step7_no_notes_backup_var (Step 7 region not found)"
        return
    fi
    if echo "$region" | grep -qE '\$\{?NOTES_BACKUP_PATH\}?'; then
        fail "I10: SKILL.md Step 7 region uses \$NOTES_BACKUP_PATH (should use \$NOTES_PATH from JSON)"
    else
        pass "I10: SKILL.md Step 7 region does not reference \$NOTES_BACKUP_PATH shell var"
    fi
}

test_I11_skill_md_step5_5_node_json_write() {
    require_skill_md "I11_skill_md_step5_5_node_json_write" || return
    local region; region="$(extract_step_region '^### .*[Ss]tep 5\.5')"
    if [ -z "$region" ]; then
        skip "I11_skill_md_step5_5_node_json_write (Step 5.5 region not found)"
        return
    fi
    local has_capture=0 has_json=0
    if echo "$region" | grep -qF "capture-env.sh"; then has_capture=1; fi
    if echo "$region" | grep -qF "final-report-env.json"; then has_json=1; fi
    if [ "$has_capture" = "1" ] && [ "$has_json" = "1" ]; then
        pass "I11: SKILL.md Step 5.5 invokes capture-env.sh and references final-report-env.json"
    else
        fail "I11: Step 5.5 missing capture-env.sh(=$has_capture) or final-report-env.json(=$has_json)"
    fi
}

# ============ R_parity: schema ↔ renderer parity (Phase B TDD) ============

test_R_parity_1_renderer_emits_all_schema_headings() {
    require_report_bin "R_parity_1_renderer_emits_all_schema_headings" || return
    require_schema "R_parity_1_renderer_emits_all_schema_headings" || return

    local sid="parity-test-sid"
    local intent="$TMPDIR_BASE/rp1-intent.md"
    local notes="$TMPDIR_BASE/rp1-notes.md"
    local envfile="$TMPDIR_BASE/rp1-env.json"
    make_intent_with_closes "$intent" "(empty)"
    make_notes_full "$notes"
    cat > "$envfile" <<'ENVEOF'
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
ENVEOF

    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"
    local envfile_node; envfile_node="$(node_path "$envfile")"
    local schema_node; schema_node="$SCHEMA_JS"

    local renderer_out
    renderer_out="$(run_report_with_envfile "$intent_node" "$notes_node" "$sid" "$envfile_node")"

    # Get headings from schema
    local headings_json
    headings_json="$(node -e "
        const s = require('$schema_node');
        process.stdout.write(JSON.stringify(s.getSectionHeadings('$sid')));
    " 2>/dev/null)"

    if [ -z "$headings_json" ] || [ "$headings_json" = "null" ]; then
        fail "R_parity_1: could not get headings from schema"
        return
    fi

    # Check each heading is present in renderer stdout
    local result
    result="$(printf '%s' "$renderer_out" | node -e "
        let out='';process.stdin.on('data',c=>out+=c);process.stdin.on('end',()=>{
          const headings = $headings_json;
          const missing = headings.filter(h => !out.includes(h));
          if (missing.length === 0) {
            process.stdout.write('PASS');
          } else {
            process.stdout.write('FAIL:' + JSON.stringify(missing));
          }
        });" 2>/dev/null)"

    if [ "$result" = "PASS" ]; then
        pass "R_parity_1: renderer stdout contains all schema headings"
    else
        fail "R_parity_1: renderer stdout missing headings: $result"
    fi
}

test_R_parity_2_schema_order_matches_render_order() {
    require_report_bin "R_parity_2_schema_order_matches_render_order" || return
    require_schema "R_parity_2_schema_order_matches_render_order" || return

    local sid="parity-test-sid"
    local intent="$TMPDIR_BASE/rp2-intent.md"
    local notes="$TMPDIR_BASE/rp2-notes.md"
    local envfile="$TMPDIR_BASE/rp2-env.json"
    make_intent_with_closes "$intent" "(empty)"
    make_notes_full "$notes"
    cat > "$envfile" <<'ENVEOF'
{
  "CC_RESTART_REQUIRED": "not_required",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "OS_REBOOT_REQUIRED": "not_required"
}
ENVEOF

    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"
    local envfile_node; envfile_node="$(node_path "$envfile")"
    local schema_node; schema_node="$SCHEMA_JS"

    local renderer_out
    renderer_out="$(run_report_with_envfile "$intent_node" "$notes_node" "$sid" "$envfile_node")"

    local headings_json
    headings_json="$(node -e "
        const s = require('$schema_node');
        process.stdout.write(JSON.stringify(s.getSectionHeadings('$sid')));
    " 2>/dev/null)"

    # Check that headings appear in order
    local result
    result="$(printf '%s' "$renderer_out" | node -e "
        let out='';process.stdin.on('data',c=>out+=c);process.stdin.on('end',()=>{
          const headings = $headings_json;
          let lastIdx = -1;
          const outOfOrder = [];
          for (const h of headings) {
            const idx = out.indexOf(h);
            if (idx === -1) { outOfOrder.push('missing:' + h); continue; }
            if (idx <= lastIdx) { outOfOrder.push('order:' + h + '@' + idx + '<=' + lastIdx); }
            lastIdx = idx;
          }
          if (outOfOrder.length === 0) {
            process.stdout.write('PASS');
          } else {
            process.stdout.write('FAIL:' + JSON.stringify(outOfOrder));
          }
        });" 2>/dev/null)"

    if [ "$result" = "PASS" ]; then
        pass "R_parity_2: renderer heading order matches schema array order"
    else
        fail "R_parity_2: heading order mismatch: $result"
    fi
}

test_R_parity_3_byte_exact_canonical_form() {
    require_report_bin "R_parity_3_byte_exact_canonical_form" || return
    require_schema "R_parity_3_byte_exact_canonical_form" || return

    local sid="parity-test-sid"
    local intent="$TMPDIR_BASE/rp3-intent.md"
    local notes="$TMPDIR_BASE/rp3-notes.md"
    local envfile="$TMPDIR_BASE/rp3-env.json"
    make_intent_with_closes "$intent" "(empty)"
    # Minimal notes: all sections present but all (none)
    cat > "$notes" <<'NOTESEOF'
# Worktree Notes
Branch: feature/parity-test

## Gitignored files copied from main
- (none)

## BugsFound
- (none)

## RelatedTasks
- (none)

## NextTasks
- (none)
NOTESEOF
    cat > "$envfile" <<'ENVEOF'
{
  "PR_NUMBER": "(none)",
  "PR_TITLE": "(none)",
  "PR_URL": "(none)",
  "PR_STATE": "(none)",
  "BRANCH": "(none)",
  "WORKTREE_PATH": "(none)",
  "CREATED_DATE": "(none)",
  "BACKUP_MANIFEST_PATH": "(none)",
  "CC_RESTART_REQUIRED": "not_required",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "not_required",
  "OS_REBOOT_REASON": ""
}
ENVEOF

    local intent_node; intent_node="$(node_path "$intent")"
    local notes_node;  notes_node="$(node_path "$notes")"
    local envfile_node; envfile_node="$(node_path "$envfile")"
    local schema_node; schema_node="$SCHEMA_JS"
    local SENTINEL_VAL='<<WORKFLOW_MARK_STEP_final_report_complete>>'

    # Get renderer stdout, strip sentinel line, strip trailing newline
    local renderer_out
    renderer_out="$(run_report_with_envfile "$intent_node" "$notes_node" "$sid" "$envfile_node")"
    local renderer_body
    renderer_body="$(printf '%s' "$renderer_out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          // strip sentinel line and trailing newline
          const lines = s.split('\n');
          const filtered = lines.filter(l => !l.includes('$SENTINEL_VAL'));
          // remove trailing empty lines
          while (filtered.length > 0 && filtered[filtered.length-1] === '') filtered.pop();
          process.stdout.write(filtered.join('\n'));
        });" 2>/dev/null)"

    # Get renderCanonicalReport output from schema
    # We need to construct a ctx that matches the "(none)" env-file values
    local envfile_contents
    envfile_contents="$(cat "$envfile")"
    local schema_body
    schema_body="$(node -e "
        const schema = require('$schema_node');
        const envBag = $envfile_contents;
        function safeEnv(key) {
          const v = envBag[key];
          return (v === undefined || v === null || v === '') ? '(none)' : v;
        }
        function categoryValue(newKey, legacyKey, legacyYes) {
          const v = safeEnv(newKey);
          if (v !== '(none)') return v === 'required' ? 'required' : v;
          const lv = safeEnv(legacyKey);
          if (lv === legacyYes) return 'required';
          return 'not_required';
        }
        const ctx = {
          safeEnv,
          closedIssuesLine: '- (none)',
          closedIssueOutcomeLines: ['- (none)'],
          buildPostMergeLines: () => {
            const cats = schema.CATEGORIES || [
              { label: 'Claude Code restart', newKey: 'CC_RESTART_REQUIRED', reasonKey: 'CC_RESTART_REASON', legacyKey: 'CLAUDE_CODE_RESTART_REQUIRED', legacyYes: 'yes' },
              { label: 'VS Code reload', newKey: 'VSCODE_RELOAD_REQUIRED', reasonKey: 'VSCODE_RELOAD_REASON', legacyKey: null, legacyYes: null },
              { label: 'Installer rerun', newKey: 'INSTALLER_RERUN_REQUIRED', reasonKey: 'INSTALLER_RERUN_REASON', legacyKey: null, legacyYes: null },
              { label: 'OS reboot', newKey: 'OS_REBOOT_REQUIRED', reasonKey: 'OS_REBOOT_REASON', legacyKey: null, legacyYes: null },
            ];
            return cats.map(cat => {
              const status = categoryValue(cat.newKey, cat.legacyKey, cat.legacyYes);
              const reason = cat.reasonKey ? safeEnv(cat.reasonKey) : '(none)';
              const suffix = (reason !== '(none)' && reason !== '') ? ' (' + reason + ')' : '';
              return '- ' + cat.label + ': ' + status + suffix;
            });
          },
          bugsLines: ['- (none)'],
          relatedLines: ['- (none)'],
          nextLines: ['- (none)'],
          worktreeLines: ['- Branch: (none)'],
          backupLines: ['- Manifest: (none)'],
        };
        const body = schema.renderCanonicalReport(envBag, '$sid', ctx);
        process.stdout.write(body);
    " 2>/dev/null)"

    if [ -z "$schema_body" ]; then
        fail "R_parity_3: schema.renderCanonicalReport returned empty output (schema may not be implemented yet)"
        return
    fi

    if [ "$renderer_body" = "$schema_body" ]; then
        pass "R_parity_3: renderer body (sentinel stripped) == schema.renderCanonicalReport (byte-exact)"
    else
        fail "R_parity_3: byte mismatch between renderer and schema
--- renderer body (first 500 chars) ---
$(printf '%s' "$renderer_body" | head -c 500)
--- schema body (first 500 chars) ---
$(printf '%s' "$schema_body" | head -c 500)"
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

test_R1_happy_path
test_R2_empty_closed_issues
test_R3_none_default_missing_section
test_R4_missing_notes_file
test_R5_missing_intent_file
test_R6_uses_shared_parser
test_R7_pr_state_passthrough
test_R8_pr_title_injection_safe

test_R9_post_merge_section_always_present
test_R10_cc_restart_yes
test_R10b_cc_restart_rules_reason
test_R11_cc_restart_no
test_R12_all_categories_default_not_required
test_R13_legacy_alias_yes
test_R14_post_merge_section_position

test_R19_post_merge_always_present
test_R20_all_four_categories_present
test_R21_vscode_reload_required
test_R22_installer_rerun_required
test_R23_os_reboot_required
test_R24_legacy_cc_restart_no

test_I12_detect_restart_failsafe
test_I13_detect_restart_rules_reason
test_I13b_detect_restart_rules_and_claude_priority

test_I1_step5_5_capture_then_remove
test_I2_step5_5_no_backup
test_I3_skill_md_grep_invariant
test_I4_skill_md_has_step_5_5
test_I5_no_eval_in_skill_md
test_I6_backup_vars_defined_in_step5

test_R15_sentinel_in_stdout
test_R16_envfile_values_adopted
test_R17_envfile_missing_hard_fail
test_R17b_envfile_relative_hard_fail
test_R18_env_only_backward_compat

test_I7_fat_call_env_reset_simulation
test_I8_skill_md_step7_sentinel
test_I9_skill_md_step7_envfile
test_I10_skill_md_step7_no_notes_backup_var
test_I11_skill_md_step5_5_node_json_write
test_R_parity_1_renderer_emits_all_schema_headings
test_R_parity_2_schema_order_matches_render_order
test_R_parity_3_byte_exact_canonical_form

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
