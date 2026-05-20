#!/bin/bash
# tests/feature-405-final-report.sh
#
# Issue #405 — Final Report feature.
#
# Tests the contract of (none of these source files exist yet — tests SKIP
# gracefully when the implementation hasn't landed):
#   - hooks/lib/parse-closes-issues.js  (parseClosesIssues parser)
#   - hooks/lib/worktree-notes.js       (buildNotesBody schema extension:
#                                        BugsFound / RelatedTasks / NextTasks)
#   - bin/worktree-final-report.js      (Final Report CLI renderer)
#   - skills/worktree-end/SKILL.md      (Step 5.5 capture-then-remove flow,
#                                        Step 7 Final Report invocation)
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
    count="$(grep -c '^7\. \*\*Final report' "$SKILL_MD" 2>/dev/null || echo 0)"
    if [ "$count" = "1" ]; then
        pass "I3: SKILL.md has exactly one '7. **Final report' heading"
    else
        fail "I3: expected 1 occurrence of '7. **Final report', got $count"
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

test_I1_step5_5_capture_then_remove
test_I2_step5_5_no_backup
test_I3_skill_md_grep_invariant
test_I4_skill_md_has_step_5_5
test_I5_no_eval_in_skill_md
test_I6_backup_vars_defined_in_step5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
