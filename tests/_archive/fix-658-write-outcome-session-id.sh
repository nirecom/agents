#!/bin/bash
# tests/fix-658-write-outcome-session-id.sh
# Tags: 658, write-outcome-session-id
#
# Issue #658 — add --session-id/--out-file CLI flags to issue-close-write-outcome.js
#
# Tests: fix/658/write/outcome/session/id
#   C1: --session-id/--out-file writes all 6 fields correctly to a new JSON file
#   C2: --session-id/--out-file upserts existing file (adds entry, preserves others, replaces same-issue)
#   C3: Normal mode regression: CLAUDE_SESSION_ID env var → writes to PLANS_DIR/<id>-issue-close-outcome.json
#   C4: Normal mode WARN: CLAUDE_SESSION_ID not set, CLAUDE_ENV_FILE not set → exit 0, stderr contains WARN
#   C5: WARN prefix: the WARN message uses [issue-close-write-outcome] not [issue-close-finalize]
#   C6: Missing --out-file after --session-id <id> → stderr error, exit 1
#   C7: Existing outcome file with other issues → new entry added, existing preserved; upsert replaces same issueNumber
#
# Cases C1, C2, C5, C6, C7 test behavior not yet implemented → will FAIL until source is changed.
# Cases C3, C4 test existing behavior → should PASS now.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

SCRIPT="${_AGENTS_DIR_NODE}/bin/issue-close-write-outcome.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f658-'+process.pid).replace(/\\\\/g,'/');
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

require_script() {
    local label="$1"
    if [ ! -f "$AGENTS_DIR/bin/issue-close-write-outcome.js" ]; then
        skip "$label (bin/issue-close-write-outcome.js missing)"
        return 1
    fi
    return 0
}

# ============ C1: --session-id/--out-file writes all 6 fields to new JSON ============

test_C1_session_id_outfile_new_file() {
    require_script "C1_session_id_outfile_new_file" || return
    local out_file; out_file="$(node_path "$TMPDIR_BASE/c1-outcome.json")"

    local stderr_out
    stderr_out="$(run_with_timeout 120 node "$SCRIPT" \
        --session-id "sess-c1" --out-file "$out_file" \
        658 "succeeded" "appended" "closed" "posted" "cleared" 2>&1 >/dev/null)"
    local code=$?

    if [ "$code" != "0" ]; then
        fail "C1_session_id_outfile_new_file: exit code $code (expected 0); stderr: $stderr_out"
        return
    fi

    local content
    content="$(run_with_timeout 10 node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('$out_file','utf8'));
const e=d.issues.find(x=>x.issueNumber===658);
if(!e){process.exit(1);}
const ok = e.state==='succeeded' && e.historyEntry==='appended' &&
           e.issueClosed==='closed' && e.sentinelsPosted==='posted' &&
           e.wipCleared==='cleared';
process.exit(ok ? 0 : 2);
" 2>&1)"
    local ncode=$?
    if [ "$ncode" = "0" ]; then
        pass "C1_session_id_outfile_new_file: all 6 fields written correctly to new JSON file"
    else
        fail "C1_session_id_outfile_new_file: field validation failed (node exit $ncode); $content"
    fi
}

# ============ C2: --session-id/--out-file upserts existing file ============

test_C2_session_id_outfile_upsert() {
    require_script "C2_session_id_outfile_upsert" || return
    local out_file_raw="$TMPDIR_BASE/c2-outcome.json"
    local out_file; out_file="$(node_path "$out_file_raw")"

    # Pre-populate with an existing entry for issue 100
    cat > "$out_file_raw" <<'EOF'
{"issues":[{"issueNumber":100,"state":"succeeded","historyEntry":"appended","issueClosed":"closed","sentinelsPosted":"posted","wipCleared":"cleared"}]}
EOF

    run_with_timeout 120 node "$SCRIPT" \
        --session-id "sess-c2" --out-file "$out_file" \
        658 "succeeded" "appended" "closed" "posted" "cleared" >/dev/null 2>&1
    local code=$?

    if [ "$code" != "0" ]; then
        fail "C2_session_id_outfile_upsert: exit code $code (expected 0)"
        return
    fi

    local ncode
    run_with_timeout 10 node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('$out_file','utf8'));
const has100 = d.issues.some(x=>x.issueNumber===100);
const has658 = d.issues.some(x=>x.issueNumber===658 && x.state==='succeeded');
process.exit((has100 && has658) ? 0 : 1);
" >/dev/null 2>&1
    ncode=$?
    if [ "$ncode" = "0" ]; then
        pass "C2_session_id_outfile_upsert: upserted entry for 658, preserved entry for 100"
    else
        fail "C2_session_id_outfile_upsert: upsert or preservation failed"
    fi
}

# ============ C3: Normal mode regression: CLAUDE_SESSION_ID set → writes to PLANS_DIR ============

test_C3_normal_mode_claude_session_id() {
    require_script "C3_normal_mode_claude_session_id" || return
    local plans_dir="$TMPDIR_BASE/plans-c3"
    mkdir -p "$plans_dir"
    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"

    WORKFLOW_PLANS_DIR="$plans_dir_node" CLAUDE_SESSION_ID="sess-c3" CLAUDE_ENV_FILE="" \
        run_with_timeout 120 node "$SCRIPT" \
        658 "succeeded" "appended" "closed" "posted" "cleared" >/dev/null 2>&1
    local code=$?

    if [ "$code" != "0" ]; then
        fail "C3_normal_mode_claude_session_id: exit code $code (expected 0)"
        return
    fi

    local expected_file="$plans_dir/sess-c3-issue-close-outcome.json"
    if [ ! -f "$expected_file" ]; then
        fail "C3_normal_mode_claude_session_id: expected file not found at $expected_file"
        return
    fi

    local ncode
    run_with_timeout 10 node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('$(node_path "$expected_file")','utf8'));
const e=d.issues.find(x=>x.issueNumber===658);
process.exit((e && e.state==='succeeded') ? 0 : 1);
" >/dev/null 2>&1
    ncode=$?
    if [ "$ncode" = "0" ]; then
        pass "C3_normal_mode_claude_session_id: wrote to PLANS_DIR/sess-c3-issue-close-outcome.json with correct fields"
    else
        fail "C3_normal_mode_claude_session_id: file exists but content is wrong"
    fi
}

# ============ C4: Normal mode WARN: no session ID → exit 0, stderr contains WARN ============

test_C4_normal_mode_warn_no_session_id() {
    require_script "C4_normal_mode_warn_no_session_id" || return

    local stderr_out
    stderr_out="$(CLAUDE_SESSION_ID="" CLAUDE_ENV_FILE="" WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-c4" \
        run_with_timeout 120 node "$SCRIPT" \
        658 "succeeded" "appended" "closed" "posted" "cleared" 2>&1 >/dev/null)"
    local code=$?

    if [ "$code" = "0" ] && echo "$stderr_out" | grep -q "WARN"; then
        pass "C4_normal_mode_warn_no_session_id: exit 0, stderr contains WARN"
    else
        fail "C4_normal_mode_warn_no_session_id: code=$code, stderr='$stderr_out' (expected exit 0 and WARN in stderr)"
    fi
}

# ============ C5: WARN prefix must be [issue-close-write-outcome] ============

test_C5_warn_prefix_correct() {
    require_script "C5_warn_prefix_correct" || return

    local stderr_out
    stderr_out="$(CLAUDE_SESSION_ID="" CLAUDE_ENV_FILE="" WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-c5" \
        run_with_timeout 120 node "$SCRIPT" \
        658 "succeeded" "appended" "closed" "posted" "cleared" 2>&1 >/dev/null)"
    local code=$?

    if echo "$stderr_out" | grep -q "\[issue-close-write-outcome\]"; then
        pass "C5_warn_prefix_correct: WARN message uses [issue-close-write-outcome] prefix"
    else
        fail "C5_warn_prefix_correct: WARN prefix wrong; stderr='$stderr_out' (expected [issue-close-write-outcome], not [issue-close-finalize])"
    fi
}

# ============ C6: Missing --out-file after --session-id → exit 1 ============

test_C6_missing_out_file() {
    require_script "C6_missing_out_file" || return

    local stderr_out
    stderr_out="$(run_with_timeout 120 node "$SCRIPT" \
        --session-id "sess-c6" \
        658 "succeeded" "appended" "closed" "posted" "cleared" 2>&1 >/dev/null)"
    local code=$?

    # The error message must explicitly mention --out-file (not just any exit 1)
    if [ "$code" = "1" ] && echo "$stderr_out" | grep -q "\-\-out-file"; then
        pass "C6_missing_out_file: exit 1 and stderr error message mentioning --out-file"
    else
        fail "C6_missing_out_file: code=$code, stderr='$stderr_out' (expected exit 1 and --out-file in stderr)"
    fi
}

# ============ C7: Existing file with other issues → new entry added, existing preserved; upsert replaces same issueNumber ============

test_C7_upsert_replaces_same_issue_preserves_others() {
    require_script "C7_upsert_replaces_same_issue_preserves_others" || return
    local out_file_raw="$TMPDIR_BASE/c7-outcome.json"
    local out_file; out_file="$(node_path "$out_file_raw")"

    # Pre-populate with two entries: issue 658 (old state) and issue 200
    cat > "$out_file_raw" <<'EOF'
{"issues":[
  {"issueNumber":658,"state":"failed","historyEntry":"failed","issueClosed":"failed","sentinelsPosted":"failed","wipCleared":"failed"},
  {"issueNumber":200,"state":"succeeded","historyEntry":"appended","issueClosed":"closed","sentinelsPosted":"posted","wipCleared":"cleared"}
]}
EOF

    run_with_timeout 120 node "$SCRIPT" \
        --session-id "sess-c7" --out-file "$out_file" \
        658 "succeeded" "appended" "closed" "posted" "cleared" >/dev/null 2>&1
    local code=$?

    if [ "$code" != "0" ]; then
        fail "C7_upsert_replaces_same_issue_preserves_others: exit code $code (expected 0)"
        return
    fi

    local ncode
    run_with_timeout 10 node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('$out_file','utf8'));
const e658=d.issues.find(x=>x.issueNumber===658);
const e200=d.issues.find(x=>x.issueNumber===200);
// 658 should be updated to succeeded, 200 should be preserved
const ok = e658 && e658.state==='succeeded' &&
           e200 && e200.state==='succeeded';
// Exactly 2 entries (no duplicates for 658)
const count658=d.issues.filter(x=>x.issueNumber===658).length;
process.exit((ok && count658===1) ? 0 : 1);
" >/dev/null 2>&1
    ncode=$?
    if [ "$ncode" = "0" ]; then
        pass "C7_upsert_replaces_same_issue_preserves_others: 658 upserted (state updated), 200 preserved, no duplicates"
    else
        fail "C7_upsert_replaces_same_issue_preserves_others: upsert/preserve check failed"
    fi
}

# ============ Run all ============

test_C1_session_id_outfile_new_file
test_C2_session_id_outfile_upsert
test_C3_normal_mode_claude_session_id
test_C4_normal_mode_warn_no_session_id
test_C5_warn_prefix_correct
test_C6_missing_out_file
test_C7_upsert_replaces_same_issue_preserves_others

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"

[ "$FAIL" -eq 0 ]
