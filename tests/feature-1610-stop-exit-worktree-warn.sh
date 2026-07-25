#!/bin/bash
# tests/feature-1610-stop-exit-worktree-warn.sh
# Tests: hooks/stop-exit-worktree-warn.js, hooks/postuse-native-worktree-record.js, settings.json, hooks/workflow-mark.js
# Tags: stop, hook, worktree, exit-worktree, advisory, TL2, pwsh-not-required, scope:issue-specific
#
# Issue #1610 — Stop-side advisory when a session entered a linked worktree and
# never released the binding. Section S pins the transcript-only path; Section R
# pins the PostToolUse recorder and the evidence-precedence rule (positive
# evidence of exit in EITHER medium suppresses the advisory).
#
# TL3 gap (what this test does NOT catch):
# - Whether the Stop hook actually fires at session stop on a real Claude Code host;
#   registration is asserted statically from settings.json, never observed firing.
# - Real transcript JSONL shape after compaction — fixtures are minimal crafted lines.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOP_HOOK="$AGENTS_DIR/hooks/stop-exit-worktree-warn.js"
RECORDER="$AGENTS_DIR/hooks/postuse-native-worktree-record.js"
SETTINGS="$AGENTS_DIR/settings.json"
WORKFLOW_MARK="$AGENTS_DIR/hooks/workflow-mark.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

make_fixture() {
    local path="$1"; shift
    for line in "$@"; do printf '%s\n' "$line"; done > "$path"
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if ! command -v node >/dev/null 2>&1; then
    skip "T2 whole file (node not available)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WF="$TMP/wf"; mkdir -p "$WF"
export CLAUDE_WORKFLOW_DIR="$(node_path "$WF")"

TU_ENTER='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e1","name":"EnterWorktree","input":{"path":"/wt"}}]}}'
TU_EXIT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"x1","name":"ExitWorktree","input":{}}]}}'
TU_BASH='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"echo hi"}}]}}'

ALL_S_OUT=""
OUT=""; RC=0

# run_stop <sid> <transcript_path_node> -> sets OUT and RC in the current shell.
run_stop() {
    printf '{"stop_hook_active":false,"session_id":"%s","transcript_path":"%s"}' "$1" "$2" \
        | run_with_timeout 60 node "$STOP_HOOK" > "$TMP/stdout.txt" 2>/dev/null
    RC=$?
    OUT="$(cat "$TMP/stdout.txt")"
}

# run_recorder <json payload> -> sets OUT and RC in the current shell.
run_recorder() {
    printf '%s' "$1" | run_with_timeout 60 node "$RECORDER" > "$TMP/stdout.txt" 2>/dev/null
    RC=$?
    OUT="$(cat "$TMP/stdout.txt")"
}

# mk_state <sid> [extra_top_level_json]
mk_state() {
    node -e '
const fs=require("fs"),path=require("path");
const [dir,sid,extra]=process.argv.slice(1);
const st=()=>({status:"complete",updated_at:null});
const state={version:1,session_id:sid,created_at:new Date().toISOString(),
  steps:{workflow_init:st(),clarify_intent:st(),branching_complete:st()}};
if(extra) Object.assign(state,JSON.parse(extra));
fs.writeFileSync(path.join(dir,sid+".json"),JSON.stringify(state,null,2));
' "$CLAUDE_WORKFLOW_DIR" "$1" "${2:-}"
}

state_field() {
    node -e '
const fs=require("fs"),path=require("path");
const [dir,sid,key]=process.argv.slice(1);
try{const s=JSON.parse(fs.readFileSync(path.join(dir,sid+".json"),"utf8"));
  process.stdout.write(s[key]==null?"":String(s[key]));}catch(e){}
' "$CLAUDE_WORKFLOW_DIR" "$1" "$2"
}

state_keys() {
    node -e '
const fs=require("fs"),path=require("path");
const [dir,sid]=process.argv.slice(1);
try{const s=JSON.parse(fs.readFileSync(path.join(dir,sid+".json"),"utf8"));
  process.stdout.write(Object.keys(s).sort().join(","));}catch(e){}
' "$CLAUDE_WORKFLOW_DIR" "$1"
}

check_has() { if printf '%s' "$3" | grep -qF "$2"; then pass "$1"; else fail "$1 -- missing [$2] in: $3"; fi; }
check_lacks() { if printf '%s' "$3" | grep -qF "$2"; then fail "$1 -- unexpected [$2] in: $3"; else pass "$1"; fi; }
check_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi; }

# ---------------------------------------------------------------- Section S --
# Transcript-only evidence: no workflow-state record exists for these sids.

run_S1() {
    require_source "$STOP_HOOK" "S1: EnterWorktree without ExitWorktree -> advisory" || return
    make_fixture "$TMP/s1.jsonl" "$TU_ENTER"
    run_stop s1sid "$(node_path "$TMP/s1.jsonl")"
    ALL_S_OUT="$ALL_S_OUT$OUT"
    if [ "$RC" -eq 0 ]; then
        check_has "S1a: advisory emitted as additionalContext" "additionalContext" "$OUT"
        check_has "S1b: advisory names the ExitWorktree tool" "ExitWorktree" "$OUT"
        check_has "S1c: advisory points at the shared protocol" "worktree-transition.md" "$OUT"
    else
        fail "S1: expected exit 0 (rc=$RC, out=$OUT)"
    fi
}

run_S2() {
    require_source "$STOP_HOOK" "S2: Enter then Exit -> silent" || return
    make_fixture "$TMP/s2.jsonl" "$TU_ENTER" "$TU_EXIT"
    run_stop s2sid "$(node_path "$TMP/s2.jsonl")"
    ALL_S_OUT="$ALL_S_OUT$OUT"
    if [ "$RC" -eq 0 ]; then check_lacks "S2: Enter then Exit -> silent" "additionalContext" "$OUT"
    else fail "S2: expected exit 0 (rc=$RC, out=$OUT)"; fi
}

run_S3() {
    require_source "$STOP_HOOK" "S3: no worktree tool_use at all -> empty stdout" || return
    make_fixture "$TMP/s3.jsonl" "$TU_BASH"
    run_stop s3sid "$(node_path "$TMP/s3.jsonl")"
    ALL_S_OUT="$ALL_S_OUT$OUT"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "S3: no worktree tool_use at all -> empty stdout"
    else fail "S3: no worktree tool_use at all -> empty stdout (rc=$RC, out=$OUT)"; fi
}

run_S4() {
    require_source "$STOP_HOOK" "S4: re-entered after exit -> advisory (last-index folding)" || return
    make_fixture "$TMP/s4.jsonl" "$TU_EXIT" "$TU_ENTER"
    run_stop s4sid "$(node_path "$TMP/s4.jsonl")"
    ALL_S_OUT="$ALL_S_OUT$OUT"
    if [ "$RC" -eq 0 ]; then
        check_has "S4: re-entered after exit -> advisory (last-index folding)" "additionalContext" "$OUT"
    else fail "S4: expected exit 0 (rc=$RC, out=$OUT)"; fi
}

run_S5() {
    require_source "$STOP_HOOK" "S5: missing transcript -> empty stdout, exit 0" || return
    run_stop s5sid "$(node_path "$TMP/does-not-exist.jsonl")"
    ALL_S_OUT="$ALL_S_OUT$OUT"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "S5: missing transcript -> empty stdout, exit 0"
    else fail "S5: missing transcript -> empty stdout, exit 0 (rc=$RC, out=$OUT)"; fi
}

run_S6() {
    require_source "$STOP_HOOK" "S6: never emits a decision (non-blocking invariant)" || return
    local bad=0
    if printf '%s' "$ALL_S_OUT" | grep -qF '"decision"'; then bad=1; fi
    if printf '%s' "$ALL_S_OUT" | grep -qF '"block"'; then bad=1; fi
    if [ "$bad" -eq 0 ]; then pass "S6: never emits a decision (non-blocking invariant)"
    else fail "S6: decision/block leaked into Stop output: $ALL_S_OUT"; fi
}

run_S7() {
    require_source "$STOP_HOOK" "S7: registered in settings.json Stop hooks" || return
    local got
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const hooks=((s.hooks&&s.hooks.Stop&&s.hooks.Stop[0]&&s.hooks.Stop[0].hooks)||[]);
process.stdout.write(String(hooks.filter(h=>String(h.command||"").includes("stop-exit-worktree-warn.js")).length));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "S7: registered in settings.json Stop hooks" "1" "$got"
}

run_S8() {
    require_source "$STOP_HOOK" "S8: malformed transcript line is skipped, valid EnterWorktree honored -> advisory" || return
    make_fixture "$TMP/s8.jsonl" "$TU_ENTER" "not valid json {{{ garbage line"
    run_stop s8sid "$(node_path "$TMP/s8.jsonl")"
    if [ "$RC" -eq 0 ]; then
        check_has "S8: malformed transcript line is skipped, valid EnterWorktree honored -> advisory" "additionalContext" "$OUT"
    else
        fail "S8: expected exit 0 despite malformed line (rc=$RC, out=$OUT)"
    fi
}

run_S9() {
    require_source "$STOP_HOOK" "S9: bare ExitWorktree with no preceding EnterWorktree -> silent" || return
    make_fixture "$TMP/s9.jsonl" "$TU_EXIT"
    run_stop s9sid "$(node_path "$TMP/s9.jsonl")"
    if [ "$RC" -eq 0 ]; then
        check_lacks "S9: bare ExitWorktree with no preceding EnterWorktree -> silent" "additionalContext" "$OUT"
    else
        fail "S9: expected exit 0 (rc=$RC, out=$OUT)"
    fi
}

# ---------------------------------------------------------------- Section R --
# Recorder + evidence precedence. P0 verdict is P+ (SETTLED): both PreToolUse and
# PostToolUse fire for EnterWorktree/ExitWorktree, so the recorder and evidence-
# precedence cases below run once hooks/postuse-native-worktree-record.js lands
# (Step 8b). While it is absent they skip, which is a passing outcome for this
# file pre-implementation.

R_LABELS=(
    "R1: EnterWorktree PostToolUse records worktree_entered_at"
    "R2: ExitWorktree records worktree_exited_at and keeps entered"
    "R3: unrelated tool adds no state keys"
    "R4: missing session_id -> fail-open, no state written"
    "R5: malformed JSON -> fail-open, empty stdout"
    "R6: transcript exit outweighs a record that lacks it"
    "R7: recorded exit outweighs a transcript that lacks it"
    "R8: no record + transcript entry only -> advisory"
    "R9: record entry only + unreadable transcript -> advisory"
    "R10: recorder registered once in settings.json PostToolUse"
    "R11: workflow-mark.js Bash-only guard untouched"
    "R12: idempotent EnterWorktree re-invocation keeps a valid entered_at, no spurious exit key"
    "R13: no pre-existing state file -> fail-open, recorder does not fabricate one"
)

run_R() {
    if [ ! -f "$RECORDER" ]; then
        local l
        for l in "${R_LABELS[@]}"; do skip "$l (recorder not implemented — P0 verdict P-)"; done
        return
    fi

    local entered exited kept before after got first_entered second_entered second_exited

    # R1
    mk_state r1sid
    run_recorder '{"tool_name":"EnterWorktree","session_id":"r1sid","tool_input":{}}'
    entered="$(state_field r1sid worktree_entered_at)"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && printf '%s' "$entered" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
        pass "${R_LABELS[0]}"
    else fail "${R_LABELS[0]} (rc=$RC out=$OUT entered=$entered)"; fi

    # R2
    run_recorder '{"tool_name":"ExitWorktree","session_id":"r1sid","tool_input":{}}'
    exited="$(state_field r1sid worktree_exited_at)"
    kept="$(state_field r1sid worktree_entered_at)"
    if [ "$RC" -eq 0 ] && [ -n "$exited" ] && [ "$kept" = "$entered" ] && [ ! "$exited" \< "$entered" ]; then
        pass "${R_LABELS[1]}"
    else fail "${R_LABELS[1]} (rc=$RC entered=$entered kept=$kept exited=$exited)"; fi

    # R3
    mk_state r3sid
    before="$(state_keys r3sid)"
    run_recorder '{"tool_name":"Write","session_id":"r3sid","tool_input":{"file_path":"/x"}}'
    after="$(state_keys r3sid)"
    check_eq "${R_LABELS[2]}" "$before" "$after"

    # R4
    run_recorder '{"tool_name":"EnterWorktree","tool_input":{}}'
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -f "$WF/undefined.json" ] && [ ! -f "$WF/null.json" ]; then
        pass "${R_LABELS[3]}"
    else fail "${R_LABELS[3]} (rc=$RC out=$OUT)"; fi

    # R5
    run_recorder 'not json at all'
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "${R_LABELS[4]}"
    else fail "${R_LABELS[4]} (rc=$RC out=$OUT)"; fi

    # R12 — idempotency: two consecutive EnterWorktree calls for the same sid.
    # The second call must not corrupt state: entered_at stays a valid ISO
    # timestamp (it may be overwritten with a later one — that is acceptable)
    # and no exit key is spuriously added.
    mk_state r12sid
    run_recorder '{"tool_name":"EnterWorktree","session_id":"r12sid","tool_input":{}}'
    first_entered="$(state_field r12sid worktree_entered_at)"
    run_recorder '{"tool_name":"EnterWorktree","session_id":"r12sid","tool_input":{}}'
    second_entered="$(state_field r12sid worktree_entered_at)"
    second_exited="$(state_field r12sid worktree_exited_at)"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
        && printf '%s' "$second_entered" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
        && [ -z "$second_exited" ]; then
        pass "${R_LABELS[11]}"
    else
        fail "${R_LABELS[11]} (rc=$RC out=$OUT first=$first_entered second=$second_entered exited=$second_exited)"
    fi

    # R13 — no pre-existing state file: the recorder only augments an EXISTING
    # state via the workflow-state writer with new keys; it must not fabricate
    # a fresh state file when none exists yet for the sid. Deliberately skip
    # mk_state here.
    rm -f "$WF/r13sid.json"
    run_recorder '{"tool_name":"EnterWorktree","session_id":"r13sid","tool_input":{}}'
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -f "$WF/r13sid.json" ]; then
        pass "${R_LABELS[12]}"
    else
        local r13_exists="no"; [ -f "$WF/r13sid.json" ] && r13_exists="yes"
        fail "${R_LABELS[12]} (rc=$RC out=$OUT state_file_created=$r13_exists)"
    fi

    if [ -f "$STOP_HOOK" ]; then
        # R6 — record says entered-only, transcript proves exit.
        mk_state r6sid '{"worktree_entered_at":"2026-07-24T00:00:00.000Z"}'
        make_fixture "$TMP/r6.jsonl" "$TU_ENTER" "$TU_EXIT"
        run_stop r6sid "$(node_path "$TMP/r6.jsonl")"
        check_lacks "${R_LABELS[5]}" "additionalContext" "$OUT"

        # R7 — record proves exit, transcript shows entry only.
        mk_state r7sid '{"worktree_entered_at":"2026-07-24T00:00:00.000Z","worktree_exited_at":"2026-07-24T01:00:00.000Z"}'
        make_fixture "$TMP/r7.jsonl" "$TU_ENTER"
        run_stop r7sid "$(node_path "$TMP/r7.jsonl")"
        check_lacks "${R_LABELS[6]}" "additionalContext" "$OUT"

        # R8 — no record at all, transcript shows entry only.
        make_fixture "$TMP/r8.jsonl" "$TU_ENTER"
        run_stop r8nostate "$(node_path "$TMP/r8.jsonl")"
        check_has "${R_LABELS[7]}" "additionalContext" "$OUT"

        # R9 — record shows entry only, transcript unreadable.
        mk_state r9sid '{"worktree_entered_at":"2026-07-24T00:00:00.000Z"}'
        run_stop r9sid "$(node_path "$TMP/absent-r9.jsonl")"
        check_has "${R_LABELS[8]}" "additionalContext" "$OUT"
    else
        skip "${R_LABELS[5]} (Stop hook not implemented yet)"
        skip "${R_LABELS[6]} (Stop hook not implemented yet)"
        skip "${R_LABELS[7]} (Stop hook not implemented yet)"
        skip "${R_LABELS[8]} (Stop hook not implemented yet)"
    fi

    # R10
    got="$(run_with_timeout 60 node -e '
const s=require(process.argv[1]);
const groups=((s.hooks&&s.hooks.PostToolUse)||[]).filter(g=>
  (g.hooks||[]).some(h=>String(h.command||"").includes("postuse-native-worktree-record.js")));
process.stdout.write(groups.length+"|"+groups.map(g=>g.matcher||"").join(","));
' "$(node_path "$SETTINGS")" 2>/dev/null)"
    check_eq "${R_LABELS[9]}" "1|EnterWorktree|ExitWorktree" "$got"

    # R11
    if grep -qF 'input.tool_name !== "Bash"' "$WORKFLOW_MARK"; then pass "${R_LABELS[10]}"
    else fail "${R_LABELS[10]} -- Bash-only guard missing from hooks/workflow-mark.js"; fi
}

run_S1; run_S2; run_S3; run_S4; run_S5; run_S6; run_S7
run_S8; run_S9
run_R

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
