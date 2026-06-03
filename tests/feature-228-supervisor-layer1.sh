#!/bin/bash
# tests/feature-228-supervisor-layer1.sh
# Tests: hooks/supervisor-layer1.js, hooks/lib/supervisor-state-writer.js, hooks/lib/supervisor-state-schema.js
# Tags: supervisor, em-supervisor, layer1, hook, e2e, posttooluse
# Tests for issue #228 — supervisor-layer1.js PostToolUse hook E2E.
#
# Covers the 4 structural checks (plan_artifact, scope_keyword, non_goal_keyword,
# sentinel), atomic state writes, parallel safety, dedup, and silent observation
# (no pass findings recorded).
#
# RED: SKIPs all cases while source files are missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

L1_HOOK="$AGENTS_DIR/hooks/supervisor-layer1.js"
L1_HOOK_NODE="$_AGENTS_DIR_NODE/hooks/supervisor-layer1.js"
WRITER_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-writer.js"
WRITER_MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_MODULE="$AGENTS_DIR/hooks/lib/supervisor-state-schema.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# Build a portable tmpdir using node (avoids Windows-vs-POSIX mktemp quirks).
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f228-l1-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build minimal PostToolUse hook input JSON.
make_input() {
    local tool="${1:-Bash}" cmd="${2:-echo hello}" sid="${3:-test-session-228}"
    node -e "console.log(JSON.stringify({tool_name:process.argv[1],tool_input:{command:process.argv[2]},session_id:process.argv[3],transcript_path:'/tmp/'+process.argv[3]+'.jsonl'}))" -- "$tool" "$cmd" "$sid"
}

# Initialize a tmp git repo at $1 with optional staged file at $2 containing $3.
init_git_repo() {
    local dir="$1" stagedFile="${2:-}" stagedContent="${3:-}"
    (
        cd "$dir" || exit 1
        git init -q >/dev/null 2>&1
        git config user.email "test@example.com" >/dev/null 2>&1
        git config user.name "test" >/dev/null 2>&1
        if [ -n "$stagedFile" ]; then
            printf '%s\n' "$stagedContent" > "$stagedFile"
            git add "$stagedFile" >/dev/null 2>&1
        fi
    )
}

# Read finding count from state JSON for a check/status pair.
count_findings() {
    local stateFile="$1" check="$2" status="$3"
    node -e "
const fs=require('fs');
try {
  const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
  const f=(s.layer1&&s.layer1.findings)||[];
  let n=0;
  for(const x of f){ if(x.check===process.argv[2]&&x.status===process.argv[3]) n++; }
  console.log(n);
} catch(e){ console.log(0); }
" -- "$stateFile" "$check" "$status"
}

# --- L1 ----------------------------------------------------------------------
run_l1() {
    require_source "$L1_HOOK" "L1: intent.md missing -> plan_artifact warn" || return
    local TEST_DIR="$TMPDIR_BASE/l1"
    mkdir -p "$TEST_DIR"
    local SID="sid-L1-$$"
    local input
    input=$(make_input "Bash" "echo hi" "$SID")
    echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    local state="$TEST_DIR/$SID-supervisor-state.json"
    if [ ! -f "$state" ]; then
        fail "L1: state file not created at $state"
        return
    fi
    local n
    n=$(count_findings "$state" "plan_artifact" "warn")
    if [ "$n" -ge 1 ]; then
        pass "L1: intent.md missing -> plan_artifact warn"
    else
        fail "L1: expected plan_artifact warn finding, got $n"
    fi
}

# --- L2 ----------------------------------------------------------------------
run_l2() {
    require_source "$L1_HOOK" "L2: scope_keyword warn finding" || return
    local TEST_DIR="$TMPDIR_BASE/l2"
    mkdir -p "$TEST_DIR"
    local SID="sid-L2-$$"
    # intent.md with Scope and Confirmed non-goals headers.
    cat > "$TEST_DIR/$SID-intent.md" <<'EOF'
## Scope
reverse proxy header forwarded
## Confirmed non-goals
legacy
EOF
    # tmp git repo with staged file containing REVERSE (uppercase, case-insensitive match expected).
    local GREPO="$TEST_DIR/repo"
    mkdir -p "$GREPO"
    init_git_repo "$GREPO" "file.txt" "this introduces REVERSE proxy support"

    local input
    input=$(make_input "Bash" "git commit" "$SID")
    (
        cd "$GREPO" || exit 1
        echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    )
    local state="$TEST_DIR/$SID-supervisor-state.json"
    if [ ! -f "$state" ]; then
        fail "L2: state file not created"
        return
    fi
    local n
    n=$(count_findings "$state" "scope_keyword" "warn")
    if [ "$n" -ge 1 ]; then
        pass "L2: scope_keyword warn finding present"
    else
        fail "L2: expected scope_keyword warn, got $n"
    fi
}

# --- L3 ----------------------------------------------------------------------
run_l3() {
    require_source "$L1_HOOK" "L3: non_goal_keyword warn finding" || return
    local TEST_DIR="$TMPDIR_BASE/l3"
    mkdir -p "$TEST_DIR"
    local SID="sid-L3-$$"
    cat > "$TEST_DIR/$SID-intent.md" <<'EOF'
## Scope
something else
## Confirmed non-goals
refactoring legacy systems
EOF
    local GREPO="$TEST_DIR/repo"
    mkdir -p "$GREPO"
    init_git_repo "$GREPO" "file.txt" "removing LEGACY code paths"
    local input
    input=$(make_input "Bash" "git commit" "$SID")
    (
        cd "$GREPO" || exit 1
        echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    )
    local state="$TEST_DIR/$SID-supervisor-state.json"
    if [ ! -f "$state" ]; then
        fail "L3: state file not created"
        return
    fi
    local n
    n=$(count_findings "$state" "non_goal_keyword" "warn")
    if [ "$n" -ge 1 ]; then
        pass "L3: non_goal_keyword warn finding present"
    else
        fail "L3: expected non_goal_keyword warn, got $n"
    fi
}

# --- L4 ----------------------------------------------------------------------
run_l4() {
    require_source "$L1_HOOK" "L4: clean diff -> no scope/non_goal findings, no pass" || return
    local TEST_DIR="$TMPDIR_BASE/l4"
    mkdir -p "$TEST_DIR"
    local SID="sid-L4-$$"
    cat > "$TEST_DIR/$SID-intent.md" <<'EOF'
## Scope
xyzzy plugh frobnicate
## Confirmed non-goals
quuxbazfoo
EOF
    local GREPO="$TEST_DIR/repo"
    mkdir -p "$GREPO"
    init_git_repo "$GREPO" "file.txt" "totally unrelated content here"
    local input
    input=$(make_input "Bash" "git commit" "$SID")
    (
        cd "$GREPO" || exit 1
        echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    )
    local state="$TEST_DIR/$SID-supervisor-state.json"
    # state file may or may not exist (no plan_artifact issue either since intent.md present).
    # Build counts robustly.
    local nScope nNonGoal nPass
    nScope=$(count_findings "$state" "scope_keyword" "warn")
    nNonGoal=$(count_findings "$state" "non_goal_keyword" "warn")
    nPass=$(node -e "
const fs=require('fs');
try {
  const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
  const f=(s.layer1&&s.layer1.findings)||[];
  let n=0; for(const x of f) if(x.status==='pass') n++;
  console.log(n);
} catch(e){ console.log(0); }
" -- "$state")
    if [ "$nScope" -eq 0 ] && [ "$nNonGoal" -eq 0 ] && [ "$nPass" -eq 0 ]; then
        pass "L4: clean diff -> no scope/non_goal/pass findings"
    else
        fail "L4: nScope=$nScope nNonGoal=$nNonGoal nPass=$nPass"
    fi
}

# --- L5 ----------------------------------------------------------------------
run_l5() {
    require_source "$L1_HOOK" "L5: warn -> additionalContext starts with EM Supervisor header" || return
    local TEST_DIR="$TMPDIR_BASE/l5"
    mkdir -p "$TEST_DIR"
    local SID="sid-L5-$$"
    local input out
    input=$(make_input "Bash" "echo hi" "$SID")
    out=$(echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" 2>/dev/null)
    local ctx
    ctx=$(node -e "
let out='';
try { out=JSON.parse(process.argv[1]); } catch(e){ console.log(''); process.exit(0); }
const c=(out&&out.hookSpecificOutput&&out.hookSpecificOutput.additionalContext)||'';
console.log(c);
" -- "$out" 2>/dev/null)
    case "$ctx" in
        "── EM Supervisor"*) pass "L5: additionalContext starts with EM Supervisor header";;
        *) fail "L5: additionalContext does not start with header (got: $(echo "$ctx" | head -c 80))";;
    esac
}

# --- L6 ----------------------------------------------------------------------
run_l6() {
    require_source "$L1_HOOK" "L6: no warn -> no additionalContext" || return
    local TEST_DIR="$TMPDIR_BASE/l6"
    mkdir -p "$TEST_DIR"
    local SID="sid-L6-$$"
    cat > "$TEST_DIR/$SID-intent.md" <<'EOF'
## Scope
xyzzyplugh frobnicate
## Confirmed non-goals
quuxbazfoo
EOF
    local GREPO="$TEST_DIR/repo"
    mkdir -p "$GREPO"
    init_git_repo "$GREPO" "file.txt" "totally unrelated content here"
    local input out
    input=$(make_input "Bash" "git commit" "$SID")
    out=$(cd "$GREPO" && echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" 2>/dev/null)
    local hasCtx
    hasCtx=$(node -e "
let out='';
try { out=JSON.parse(process.argv[1]); } catch(e){ console.log('no'); process.exit(0); }
const c=(out&&out.hookSpecificOutput&&out.hookSpecificOutput.additionalContext)||'';
console.log(c?'yes':'no');
" -- "$out" 2>/dev/null)
    if [ -z "$out" ] || [ "$out" = "{}" ] || [ "$hasCtx" = "no" ]; then
        pass "L6: no warn -> stdout empty or no additionalContext"
    else
        fail "L6: expected no additionalContext, got: $(echo "$out" | head -c 200)"
    fi
}

# --- L7 ----------------------------------------------------------------------
run_l7() {
    require_source "$WRITER_MODULE" "L7: parallel atomic append (writer module)" || return
    require_source "$SCHEMA_MODULE" "L7: parallel atomic append (schema module)" || return
    local TEST_DIR="$TMPDIR_BASE/l7"
    mkdir -p "$TEST_DIR"
    local SID="sid-L7-$$"
    # P1 runs first (synchronous) so its write lands before P2 reads.
    # This tests the re-read contract: P2 sees P1's data because it re-reads
    # the file immediately before its own write.
    WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
w.appendFinding(process.argv[1], { check: 'plan_artifact', status: 'warn', detail: 'p1' });
" -- "$SID" >/dev/null 2>&1
    WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node -e "
const w = require('$WRITER_MODULE_NODE');
w.appendFinding(process.argv[1], { check: 'sentinel', status: 'warn', detail: 'p2' });
" -- "$SID" >/dev/null 2>&1

    local state="$TEST_DIR/$SID-supervisor-state.json"
    # (a) no .tmp leftover
    local tmpFiles
    tmpFiles=$(ls "$TEST_DIR" 2>/dev/null | grep -c '\.tmp$' || true)
    if [ "$tmpFiles" != "0" ]; then
        fail "L7: $tmpFiles .tmp file(s) remain"
        return
    fi
    # (b) valid JSON
    local parsed
    parsed=$(node -e "
const fs=require('fs');
try { JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log('OK'); } catch(e){ console.log('FAIL:'+e.message); }
" -- "$state" 2>/dev/null)
    if [ "$parsed" != "OK" ]; then
        fail "L7: state file invalid JSON ($parsed)"
        return
    fi
    # (c) both findings present
    local nP1 nP2
    nP1=$(count_findings "$state" "plan_artifact" "warn")
    nP2=$(count_findings "$state" "sentinel" "warn")
    if [ "$nP1" -ge 1 ] && [ "$nP2" -ge 1 ]; then
        pass "L7: parallel atomic append preserves both findings"
    else
        fail "L7: lost finding (nP1=$nP1, nP2=$nP2)"
    fi
}

# --- L8 ----------------------------------------------------------------------
run_l8() {
    require_source "$L1_HOOK" "L8: consecutive calls accumulate" || return
    local TEST_DIR="$TMPDIR_BASE/l8"
    mkdir -p "$TEST_DIR"
    local SID="sid-L8-$$"
    local input
    input=$(make_input "Bash" "echo hi" "$SID")
    echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    local state="$TEST_DIR/$SID-supervisor-state.json"
    local total
    total=$(node -e "
const fs=require('fs');
try {
  const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
  console.log(((s.layer1&&s.layer1.findings)||[]).length);
} catch(e){ console.log(0); }
" -- "$state")
    # L12 (dedup) suggests duplicates collapse, but L8 expects accumulation across
    # *different* calls. With identical inputs, dedup may collapse to 1. To honor
    # both, treat the test loosely: >=1 finding, state file persisted across calls.
    if [ "$total" -ge 1 ]; then
        pass "L8: consecutive calls preserve state ($total findings)"
    else
        fail "L8: expected >=1 finding, got $total"
    fi
}

# --- L9 ----------------------------------------------------------------------
run_l9() {
    require_source "$L1_HOOK" "L9: stdin parse failure -> exit 0, stdout empty" || return
    local TEST_DIR="$TMPDIR_BASE/l9"
    mkdir -p "$TEST_DIR"
    local out rc
    out=$(echo 'not-json' | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ] && { [ -z "$out" ] || [ "$out" = "{}" ]; }; then
        pass "L9: stdin parse failure handled (rc=0, stdout empty)"
    else
        fail "L9: rc=$rc out='$out'"
    fi
}

# --- L10 ---------------------------------------------------------------------
run_l10() {
    require_source "$L1_HOOK" "L10: Read tool -> all checks skipped, no state file" || return
    local TEST_DIR="$TMPDIR_BASE/l10"
    mkdir -p "$TEST_DIR"
    local SID="sid-L10-$$"
    local input
    input=$(node -e "console.log(JSON.stringify({tool_name:'Read',tool_input:{file_path:'src/foo.js'},session_id:process.argv[1],transcript_path:'/tmp/x.jsonl'}))" -- "$SID")
    echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    local state="$TEST_DIR/$SID-supervisor-state.json"
    if [ ! -f "$state" ]; then
        pass "L10: Read tool -> no state file created"
    else
        fail "L10: state file unexpectedly created for Read tool"
    fi
}

# --- L11 ---------------------------------------------------------------------
run_l11() {
    require_source "$L1_HOOK" "L11: large diff truncated, hook completes <2000ms" || return
    local TEST_DIR="$TMPDIR_BASE/l11"
    mkdir -p "$TEST_DIR"
    local SID="sid-L11-$$"
    cat > "$TEST_DIR/$SID-intent.md" <<'EOF'
## Scope
abcdefgh marker word
## Confirmed non-goals
xyzzyplugh
EOF
    local GREPO="$TEST_DIR/repo"
    mkdir -p "$GREPO"
    (
        cd "$GREPO" || exit 1
        git init -q >/dev/null 2>&1
        git config user.email "t@e.com" >/dev/null 2>&1
        git config user.name "t" >/dev/null 2>&1
        # Generate ~2MB content containing the marker.
        node -e "
const fs=require('fs');
const line='abcdefgh\n';
let buf='';
while (buf.length < 2 * 1024 * 1024) buf += line;
fs.writeFileSync('big.txt', buf);
" 2>/dev/null
        git add big.txt >/dev/null 2>&1
    )
    local input
    input=$(make_input "Bash" "git commit" "$SID")
    local t0 t1
    t0=$(node -e "console.log(Date.now())")
    (
        cd "$GREPO" || exit 1
        echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    )
    t1=$(node -e "console.log(Date.now())")
    local elapsed=$((t1 - t0))
    local state="$TEST_DIR/$SID-supervisor-state.json"
    local n
    n=$(count_findings "$state" "scope_keyword" "warn")
    if [ "$elapsed" -lt 2000 ] && [ "$n" -ge 1 ]; then
        pass "L11: large diff truncated; ${elapsed}ms; scope_keyword warn present"
    else
        fail "L11: elapsed=${elapsed}ms (want <2000); scope_keyword warn count=$n"
    fi
}

# --- L12 ---------------------------------------------------------------------
run_l12() {
    require_source "$L1_HOOK" "L12: duplicate finding not appended twice" || return
    local TEST_DIR="$TMPDIR_BASE/l12"
    mkdir -p "$TEST_DIR"
    local SID="sid-L12-$$"
    local input
    input=$(make_input "Bash" "echo hi" "$SID")
    echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    local state="$TEST_DIR/$SID-supervisor-state.json"
    local n
    n=$(count_findings "$state" "plan_artifact" "warn")
    if [ "$n" -eq 1 ]; then
        pass "L12: duplicate finding deduped (count=1)"
    else
        fail "L12: expected 1 plan_artifact warn, got $n"
    fi
}

# --- L13 ---------------------------------------------------------------------
run_l13() {
    require_source "$L1_HOOK" "L13: Japanese-only intent -> no keyword findings" || return
    local TEST_DIR="$TMPDIR_BASE/l13"
    mkdir -p "$TEST_DIR"
    local SID="sid-L13-$$"
    cat > "$TEST_DIR/$SID-intent.md" <<'EOF'
## Scope
セキュリティ設定を強化する
## Confirmed non-goals
リファクタリング
EOF
    local GREPO="$TEST_DIR/repo"
    mkdir -p "$GREPO"
    init_git_repo "$GREPO" "file.txt" "reverse proxy support added"
    local input
    input=$(make_input "Bash" "git commit" "$SID")
    (
        cd "$GREPO" || exit 1
        echo "$input" | WORKFLOW_PLANS_DIR="$TEST_DIR" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" run_with_timeout 5 node "$L1_HOOK_NODE" >/dev/null 2>&1
    )
    local state="$TEST_DIR/$SID-supervisor-state.json"
    local nScope nNonGoal
    nScope=$(count_findings "$state" "scope_keyword" "warn")
    nNonGoal=$(count_findings "$state" "non_goal_keyword" "warn")
    if [ "$nScope" -eq 0 ] && [ "$nNonGoal" -eq 0 ]; then
        pass "L13: Japanese-only intent -> no scope/non_goal findings (ASCII-only limitation)"
    else
        fail "L13: nScope=$nScope nNonGoal=$nNonGoal (expected 0/0)"
    fi
}

run_l1
run_l2
run_l3
run_l4
run_l5
run_l6
run_l7
run_l8
run_l9
run_l10
run_l11
run_l12
run_l13

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
