#!/usr/bin/env bash
# Tests: hooks/lib/workflow-state.js, hooks/workflow-gate.js, hooks/workflow-mark.js, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: workflow, gate, hook, init, routing
# Pre-implementation tests for /workflow-init routing skill and workflow_init step.
# Tests M1-S9 (behavioral): FAIL until source code changes land (detail.md Steps 1-3).
# Tests C10-C12 (content checks): FAIL until new files are written (detail.md Steps 4-7).
set -euo pipefail

# Timeout guard
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
STATE_LIB="$AGENTS_DIR/hooks/lib/workflow-state.js"
WORKFLOW_INIT_MD="$AGENTS_DIR/skills/workflow-init/SKILL.md"
CLARIFY_INTENT_MD="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
AGENTS_CLAUDE_MD="$AGENTS_DIR/CLAUDE.md"
LABELS_YML="$AGENTS_DIR/.github/labels.yml"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Resolve the plans dir as Node sees it (Windows path munging safe)
PLANS_DIR_NATIVE=$(node -e "console.log(require('path').join(require('os').homedir(), '.workflow-plans').replace(/\\\\/g, '/'))")

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# Legacy state: no workflow_init key, clarify_intent absent
state_ci_absent() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO"
}

# Legacy state: no workflow_init key, clarify_intent = complete
state_ci_complete() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"complete","updated_at":"%s"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$NOW_ISO"
}

# Legacy state: no workflow_init key, clarify_intent = skipped
state_ci_skipped() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"skipped","updated_at":"%s"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$NOW_ISO"
}

# Legacy state: no workflow_init key, clarify_intent = pending (in-flight session at upgrade time)
state_ci_pending() {
    local sid="$1"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"pending","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO"
}

# New state with explicit workflow_init + clarify_intent statuses
state_wi_ci() {
    local sid="$1" wi_status="$2" ci_status="$3"
    printf '{"version":1,"session_id":"%s","created_at":"%s","cwd":"/tmp","git_branch":"main","steps":{"workflow_init":{"status":"%s","updated_at":null},"clarify_intent":{"status":"%s","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}' \
        "$sid" "$NOW_ISO" "$wi_status" "$ci_status"
}

# Read workflow_init.status via readState() (applies migration).
# Run node from AGENTS_DIR so relative require paths work on Windows (MSYS2 paths fail in native node require).
read_wi_status() {
    local sid="$1"
    (cd "$AGENTS_DIR" && node -e "
const { readState } = require('./hooks/lib/workflow-state.js');
const s = readState('$sid');
const wi = s && s.steps && s.steps.workflow_init;
process.stdout.write(wi ? wi.status : 'MISSING');
" 2>/dev/null) || echo "ERROR"
}

# ---------------------------------------------------------------------------
# Gate helpers (mirror feature-clarify-intent-gate.sh)
# ---------------------------------------------------------------------------
run_gate() {
    local input="$1"
    echo "$input" | run_with_timeout node "$GATE_HOOK" 2>/dev/null || true
}

assert_decision() {
    local test_name="$1" input="$2" expected="$3"
    local output actual
    output=$(run_gate "$input")
    actual=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).decision||'')}catch(e){process.stdout.write('')}})")
    if [ "$actual" = "$expected" ]; then
        pass "$test_name"
    else
        fail "$test_name (expected=$expected, got=$actual)"
    fi
}

assert_message_contains() {
    local test_name="$1" input="$2" pattern="$3"
    local output msg
    output=$(run_gate "$input")
    # Gate outputs {decision, reason} — extract reason field
    msg=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{const p=JSON.parse(d);process.stdout.write(p.reason||p.message||'')}catch(e){process.stdout.write('')}})")
    if printf '%s' "$msg" | grep -qF "$pattern"; then
        pass "$test_name"
    else
        fail "$test_name (pattern '$pattern' not found in block reason)"
    fi
}

assert_message_absent() {
    local test_name="$1" input="$2" pattern="$3"
    local output msg
    output=$(run_gate "$input")
    # Gate outputs {decision, reason} — extract reason field
    msg=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{const p=JSON.parse(d);process.stdout.write(p.reason||p.message||'')}catch(e){process.stdout.write('')}})")
    if printf '%s' "$msg" | grep -qF "$pattern"; then
        fail "$test_name (unexpected pattern '$pattern' found in reason)"
    else
        pass "$test_name"
    fi
}

assert_contains() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then fail "$desc (file not found: $file)"; return 1; fi
    if grep -qE "$pattern" "$file"; then pass "$desc"; else fail "$desc (pattern not found: $pattern in $file)"; fi
}

input_edit()  { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"x","new_string":"y"}}' "$sid" "$fp"; }
input_write() { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"hello"}}' "$sid" "$fp"; }

# Build a PostToolUse-style JSON for workflow-mark.js
build_mark_json() {
    local cmd="$1" sid="$2"
    local esc="${cmd//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' \
        "$esc" "$esc" "$sid"
}

# ============================================================
echo "=== M: Migration tests ==="
echo ""

# M1: ci absent → workflow_init backfilled as complete (no ci key = very old session)
SID="mig-ci-absent"
write_state "$SID" "$(state_ci_absent "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "complete" ] && pass "M1: ci_absent → workflow_init:complete" \
    || fail "M1: ci_absent → workflow_init:complete (got: $actual)"

# M2: ci complete → workflow_init backfilled as complete
SID="mig-ci-complete"
write_state "$SID" "$(state_ci_complete "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "complete" ] && pass "M2: ci_complete → workflow_init:complete" \
    || fail "M2: ci_complete → workflow_init:complete (got: $actual)"

# M3: ci skipped → workflow_init backfilled as complete
SID="mig-ci-skipped"
write_state "$SID" "$(state_ci_skipped "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "complete" ] && pass "M3: ci_skipped → workflow_init:complete" \
    || fail "M3: ci_skipped → workflow_init:complete (got: $actual)"

# M4: ci pending (in-flight session at upgrade time) → workflow_init backfilled as pending
SID="mig-ci-pending"
write_state "$SID" "$(state_ci_pending "$SID")"
actual=$(read_wi_status "$SID")
[ "$actual" = "pending" ] && pass "M4: ci_pending → workflow_init:pending" \
    || fail "M4: ci_pending → workflow_init:pending (got: $actual)"

# ============================================================
echo ""
echo "=== G: Early gate tests ==="
echo ""

# G5: Tier 1 — workflow_init:pending → Edit blocked; message references workflow-init
SID="gate-tier1"
write_state "$SID" "$(state_wi_ci "$SID" "pending" "pending")"
assert_decision   "G5a: workflow_init:pending → Edit blocked"             "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "block"
assert_message_contains "G5b: Tier 1 block message references workflow-init" "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "workflow-init"

# G6: Tier 2 — workflow_init:complete + clarify_intent:pending → Edit blocked; message references clarify-intent
#     AND does NOT reference workflow-init (Tier 1 already cleared)
SID="gate-tier2"
write_state "$SID" "$(state_wi_ci "$SID" "complete" "pending")"
assert_decision   "G6a: clarify_intent:pending → Edit still blocked"      "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "block"
assert_message_contains "G6b: Tier 2 block message references clarify-intent" "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "clarify-intent"
assert_message_absent   "G6c: Tier 2 block does NOT mention workflow_init gate" "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "workflow_init has not been completed"

# G7: Both complete → Edit approved (gate dormant)
SID="gate-dormant"
write_state "$SID" "$(state_wi_ci "$SID" "complete" "complete")"
assert_decision "G7: workflow_init:complete + clarify_intent:complete → Edit approved" \
    "$(input_edit "$SID" "/c/git/proj/src/foo.js")" "approve"

# G8: workflow_init:pending + Write to ~/.workflow-plans/ → approved (plans-path allowlist)
SID="gate-plans-allowlist"
write_state "$SID" "$(state_wi_ci "$SID" "pending" "pending")"
assert_decision "G8: workflow_init:pending + Write to plans dir → approved (allowlist)" \
    "$(input_write "$SID" "$PLANS_DIR_NATIVE/${SID}-intent.md")" "approve"

# ============================================================
echo ""
echo "=== S: Sentinel test ==="
echo ""

# S9: <<WORKFLOW_MARK_STEP_workflow_init_complete>> accepted by workflow-mark.js
#     (workflow_init must be in VALID_STEPS for the sentinel to record the step)
SID="mark-wi-complete"
write_state "$SID" "$(state_wi_ci "$SID" "pending" "pending")"
MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"' "$SID")
MARK_OUTPUT=$(echo "$MARK_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)

# Verify state was updated to complete
actual_after=$( (cd "$AGENTS_DIR" && node -e "
const { readState } = require('./hooks/lib/workflow-state.js');
const s = readState('$SID');
const wi = s && s.steps && s.steps.workflow_init;
process.stdout.write(wi ? wi.status : 'MISSING');
" 2>/dev/null) || echo "ERROR")

if [ "$actual_after" = "complete" ]; then
    pass "S9: MARK_STEP_workflow_init_complete accepted and recorded"
elif printf '%s' "$MARK_OUTPUT" | grep -q "NOT recorded"; then
    fail "S9: MARK_STEP_workflow_init_complete rejected by workflow-mark.js (output: $MARK_OUTPUT)"
else
    fail "S9: MARK_STEP_workflow_init_complete — state not updated (got: $actual_after)"
fi

# ============================================================
echo ""
echo "=== C: Content checks ==="
echo ""

echo "--- C10: skills/workflow-init/SKILL.md ---"
assert_contains "$WORKFLOW_INIT_MD" "Path A" \
    "C10a: SKILL.md contains Path A (intent:clarified)"
assert_contains "$WORKFLOW_INIT_MD" "Path B" \
    "C10b: SKILL.md contains Path B (issue, no label)"
assert_contains "$WORKFLOW_INIT_MD" "Path C" \
    "C10c: SKILL.md contains Path C (no issue)"
assert_contains "$WORKFLOW_INIT_MD" "WORKFLOW_MARK_STEP_workflow_init_complete" \
    "C10d: SKILL.md Path A emits WORKFLOW_MARK_STEP_workflow_init_complete"
assert_contains "$WORKFLOW_INIT_MD" "WORKFLOW_CLARIFY_INTENT_NOT_NEEDED" \
    "C10e: SKILL.md Path A emits WORKFLOW_CLARIFY_INTENT_NOT_NEEDED"
assert_contains "$WORKFLOW_INIT_MD" "intent:clarified" \
    "C10f: SKILL.md references intent:clarified label"

echo ""
echo "--- C11: skills/clarify-intent/SKILL.md Completion section ---"
assert_contains "$CLARIFY_INTENT_MD" "gh issue create" \
    "C11a: clarify-intent Completion contains 'gh issue create'"
assert_contains "$CLARIFY_INTENT_MD" "gh issue edit.*--add-label|--add-label" \
    "C11b: clarify-intent Completion contains 'gh issue edit --add-label'"
assert_contains "$CLARIFY_INTENT_MD" "intent:clarified" \
    "C11c: clarify-intent Completion references 'intent:clarified'"
assert_contains "$CLARIFY_INTENT_MD" "workflow_init" \
    "C11d: clarify-intent TodoWrite checklist marks workflow_init as completed"

echo ""
echo "--- C12: CLAUDE.md and .github/labels.yml ---"
assert_contains "$AGENTS_CLAUDE_MD" "/workflow-init" \
    "C12a: CLAUDE.md Step 1 references /workflow-init"
assert_contains "$LABELS_YML" "intent:clarified" \
    "C12b: .github/labels.yml contains intent:clarified"

echo ""
echo "--- C13: workflow-init step 3 OPEN branch wip-state hookpoint (#362) ---"

# C13a: SKILL.md step 3 OPEN branch references wip-state.sh check across all ISSUES (per-N loop).
assert_contains "$WORKFLOW_INIT_MD" "Aggregate WIP check|wip-state\.sh.*check|for each issue N in \`ISSUES\`" \
    "C13a: workflow-init Step 3a references wip-state.sh check across all ISSUES (per-N loop)"

# C13b: failure-handling policy — when wip-state check fails (rc != 0), treat as 'none' and proceed.
assert_contains "$WORKFLOW_INIT_MD" "advisory|proceeding as|wip-state check failed|rc=" \
    "C13b: wip-state check failure-handling policy documented (advisory; proceed as none)"

# C13c: AskUserQuestion text identifies the conflict scenario + Continue/Abort options.
# Public-repo policy: docs must be English (rules/language.md).
assert_contains "$WORKFLOW_INIT_MD" "in progress in another session|another session" \
    "C13c: AskUserQuestion text identifies the cross-session conflict scenario"
assert_contains "$WORKFLOW_INIT_MD" "Continue \(recommended\)|Continue.*recommended" \
    "C13c2: AskUserQuestion offers a 'Continue (recommended)' option"
assert_contains "$WORKFLOW_INIT_MD" "Abort" \
    "C13c3: AskUserQuestion offers an 'Abort' option"

# C13c4: AskUserQuestion enumerates the conflicted issue list (CONFLICTED variable).
assert_contains "$WORKFLOW_INIT_MD" "CONFLICTED|comma-separated" \
    "C13c4: workflow-init AskUserQuestion enumerates conflicted issue list (CONFLICTED variable)"

# C13d: resume-clarified gap — 'none' + 'intent:clarified' triggers per-N wip-state set.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "C13d: workflow-init resume-clarified branch (file not found)"
elif grep -q "none" "$WORKFLOW_INIT_MD" \
   && grep -q "intent:clarified" "$WORKFLOW_INIT_MD" \
   && grep -qE "for each N in \`ISSUES\`.*wip-state.*set|wip-state.*set.*<N>|ISSUES.*wip-state.*set" "$WORKFLOW_INIT_MD"; then
    pass "C13d: workflow-init resume-clarified branch — wip-state set loops across all ISSUES"
else
    fail "C13d: resume-clarified branch text missing (need none + intent:clarified + per-N set loop)"
fi

# C13e: abort path emits WORKFLOW_ABORTED_WIP_CONFLICT sentinel.
assert_contains "$WORKFLOW_INIT_MD" "WORKFLOW_ABORTED_WIP_CONFLICT" \
    "C13e: 'abort' branch emits <<WORKFLOW_ABORTED_WIP_CONFLICT>> sentinel"

# C13f: Aggregate WIP classification (same/none/other) documented across ISSUES.
if grep -qE "all.*same|all.*none|Any.*other|any.*other|all.*WIP" "$WORKFLOW_INIT_MD"; then
    pass "C13f: aggregate WIP classification (same/none/other) documented across ISSUES"
else
    fail "C13f: aggregate WIP classification not documented (need same/none/other cases)"
fi

# C13g: Continue branch loops wip-state set across all ISSUES (not just CONFLICTED).
assert_contains "$WORKFLOW_INIT_MD" "for each N in \`ISSUES\`.*wip-state.*set|ISSUES.*Continue.*set|Continue.*ISSUES.*wip-state" \
    "C13g: Continue branch loops wip-state set across all ISSUES (not just CONFLICTED)"

# ============================================================
echo ""
echo "=== Issue #444: workflow-init multi-N ==="
echo ""
# Tests W5-W10: pre-implementation assertions — FAIL until source code changes land.

# W5: SKILL.md Step 1 contains both `ISSUES=` and `Move the selected entry to index 0`.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W5: workflow-init multi-N reorder semantics (file not found)"
elif grep -qE "ISSUES=" "$WORKFLOW_INIT_MD" && grep -qF "Move the selected entry to index 0" "$WORKFLOW_INIT_MD"; then
    pass "W5: SKILL.md Step 1 contains ISSUES= and 'Move the selected entry to index 0' (reorder semantics)"
else
    fail "W5: SKILL.md Step 1 must contain both 'ISSUES=' and 'Move the selected entry to index 0'"
fi

# W6: The 2+ branch is followed by AskUserQuestion reference; `pick one` is absent.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W6a: 2+ branch references AskUserQuestion (file not found)"
else
    # Find a line containing `2+` and check whether AskUserQuestion appears within
    # the next 50 lines after it.
    PLUS_LN=$(grep -nE "2\+" "$WORKFLOW_INIT_MD" | head -1 | cut -d: -f1)
    if [ -n "$PLUS_LN" ]; then
        END_LN=$((PLUS_LN + 50))
        SLICE=$(awk -v s="$PLUS_LN" -v e="$END_LN" 'NR>=s && NR<=e' "$WORKFLOW_INIT_MD")
        if printf '%s' "$SLICE" | grep -qF "AskUserQuestion"; then
            pass "W6a: 2+ branch is followed by AskUserQuestion reference within 50 lines"
        else
            fail "W6a: 2+ branch (line $PLUS_LN) not followed by AskUserQuestion within 50 lines"
        fi
    else
        fail "W6a: no '2+' marker found in SKILL.md"
    fi
fi
assert_absent_local() {
    local file="$1" pattern="$2" desc="$3"
    if [ ! -f "$file" ]; then fail "$desc (file not found)"; return 1; fi
    if grep -qF "$pattern" "$file"; then fail "$desc (unexpected literal '$pattern' present)"; else pass "$desc"; fi
}
assert_absent_local "$WORKFLOW_INIT_MD" "pick one" \
    "W6b: 'pick one' (old narrowing behavior) is absent from SKILL.md"

# W7: Path A section documents multi-issue closes_issues (ISSUES[1+] present).
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W7: Path A multi-issue documentation (file not found)"
else
    PATH_A_W7=$(awk '/^#### Path A/{in_a=1;next} in_a{if(/^#### /){exit}print}' "$WORKFLOW_INIT_MD")
    if printf '%s' "$PATH_A_W7" | grep -qF 'ISSUES[1+]'; then
        pass "W7: Path A documents multi-issue closes_issues (ISSUES[1+] present)"
    else
        fail "W7: Path A missing multi-issue documentation (ISSUES[1+] not found)"
    fi
fi

# W8: SKILL.md Step 1 mentions ISSUES[0], closes_issues[0], and 'becomes closes_issues[0]'.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W8: index-zero mappings (file not found)"
elif grep -qE "ISSUES\[0\]" "$WORKFLOW_INIT_MD" \
  && grep -qE "closes_issues\[0\]" "$WORKFLOW_INIT_MD" \
  && grep -qF "becomes closes_issues[0]" "$WORKFLOW_INIT_MD"; then
    pass "W8: SKILL.md mentions ISSUES[0], closes_issues[0], and 'becomes closes_issues[0]'"
else
    fail "W8: SKILL.md must contain 'ISSUES[0]', 'closes_issues[0]', and 'becomes closes_issues[0]'"
fi

# W9: literal 'AskUserQuestion to pick one' must be absent (regression prevention).
assert_absent_local "$WORKFLOW_INIT_MD" "AskUserQuestion to pick one" \
    "W9: 'AskUserQuestion to pick one' old narrowing prompt is absent"

# W10: Path A section fail-closed regression prevention.
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "W10: Path A fail-closed regression prevention (file not found)"
else
    # Extract Path A section (from "### Path A" heading to next "### Path " heading or EOF).
    PATH_A_SLICE=$(awk '
        /^#### Path A/ { in_a = 1 }
        in_a {
            if (/^#### Path [BC]/) { exit }
            print
        }
    ' "$WORKFLOW_INIT_MD")
    if printf '%s' "$PATH_A_SLICE" | grep -qF "ABORT" \
       && printf '%s' "$PATH_A_SLICE" | grep -qF -- '--add-label "intent:clarified"' \
       && printf '%s' "$PATH_A_SLICE" | grep -qF "aborted-pathA-multiN-label-failure"; then
        pass "W10a: Path A section contains ABORT, --add-label \"intent:clarified\", and aborted-pathA-multiN-label-failure"
    else
        fail "W10a: Path A section missing one of: ABORT / --add-label \"intent:clarified\" / aborted-pathA-multiN-label-failure"
    fi
    # Fail-open pattern `continuing]` (the old `|| echo "[continuing]"`) must be absent from Path A.
    if printf '%s' "$PATH_A_SLICE" | grep -qF "continuing]"; then
        fail "W10b: Path A fail-open pattern 'continuing]' unexpectedly present"
    else
        pass "W10b: Path A fail-open pattern 'continuing]' is absent"
    fi
fi

# ============================================================
echo ""
echo "=== Summary ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$ERRORS test(s) failed."
fi
exit "$ERRORS"
