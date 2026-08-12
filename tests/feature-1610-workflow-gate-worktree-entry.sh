#!/bin/bash
# tests/feature-1610-workflow-gate-worktree-entry.sh
# Tests: hooks/workflow-gate/worktree-entry-gate.js, hooks/workflow-gate.js, hooks/enforce-worktree/worktree-remedy.js, hooks/enforce-worktree.js
# Tags: workflow-gate, enforce-worktree, worktree-entry, tier3, hook, TL2, pwsh-not-required, scope:issue-specific
#
# Issue #1610 — Tier 3 "session created a linked worktree but CWD is outside it"
# gate (Section G) and the double-block / deferral contract between
# workflow-gate.js and enforce-worktree.js (Section H).
# Section P0 guards the guards: the four sources have shipped, so their absence is a
# deletion, and it must turn this file RED rather than skipping every case green.
#
# TL3 gap (what this test does NOT catch):
# - How Claude Code presents TWO PreToolUse hooks that both return decision:block
#   (both reasons listed, or first-wins, and in which order) — observable only on a
#   real host. This test pins each hook's stdout contract, nothing beyond it.
# - Real PreToolUse payload shape drift (whether `cwd` is present on every event).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
EW_HOOK="$AGENTS_DIR/hooks/enforce-worktree.js"
ENTRY_GATE="$AGENTS_DIR/hooks/workflow-gate/worktree-entry-gate.js"
REMEDY="$AGENTS_DIR/hooks/enforce-worktree/worktree-remedy.js"

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

np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# suite_status — this file's exit code, as a value. A named seam so the P0 self-test
# below asserts the real decision instead of a copy of it.
suite_status() { if [ "$FAIL" -gt 0 ]; then echo 1; else echo 0; fi; }

# ---------------------------------------------------------------- Section P0 --
# Source presence: a deleted source must turn this file RED, never green-with-SKIPs.
#
# Why: require_source() reports a missing file as SKIP ("source not implemented yet"),
# and h_setup() collapses the same condition into H_READY=0 -> h_skip for every
# Section H case. That wording was true while #1610 was unimplemented; all four files
# below have shipped since. Today "missing" can only mean a deletion or a rename — and
# on the SKIP path FAIL stays 0, so every G and H case silently stops running while the
# suite still exits 0. Total loss of coverage for a shipped feature, reported as green.
# This check is deliberately NOT routed through require_source(): the behaviour under
# test is precisely "absence must not be a skip", so reusing the skipping helper to
# guard it would be circular.
SOURCE_FILES=("$GATE_HOOK" "$EW_HOOK" "$ENTRY_GATE" "$REMEDY")

# run_source_presence_check <path>... — prints "MISSING <path>" per absent file; rc=0
# only when every path exists. Parameterized so the self-test can drive it against a
# deliberately absent path: no real repo file is ever moved, copied or deleted, so an
# interrupted run cannot leave the checkout damaged.
run_source_presence_check() {
    local missing=0 p
    for p in "$@"; do
        if [ ! -f "$p" ]; then printf 'MISSING %s\n' "$p"; missing=$((missing + 1)); fi
    done
    [ "$missing" -eq 0 ]
}

# report_source_presence <path>... — one `fail` per missing file. `fail`, not `skip`:
# that single choice is what makes the process exit code non-zero.
report_source_presence() {
    local out line
    out="$(run_source_presence_check "$@")" && return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        fail "P0: required #1610 source file is missing (deleted or renamed): ${line#MISSING }"
    done <<< "$out"
    return 1
}

if report_source_presence "${SOURCE_FILES[@]}"; then
    pass "P0: all four #1610 source files are present on disk"
fi

# P0/self-test — proves the mechanism, not just its happy path. A path that is never
# created stands in for a deleted source file.
P0_ABSENT="$AGENTS_DIR/hooks/__t1610-source-presence-selftest-absent__.js"
P0_PROBE="$(
    PASS=0; FAIL=0; SKIP=0
    report_source_presence "$P0_ABSENT" >/dev/null
    printf '%s %s %s %s\n' "$PASS" "$FAIL" "$SKIP" "$(suite_status)"
)"
read -r p0_pass p0_fail p0_skip p0_status <<< "$P0_PROBE"
if [ "$p0_fail" -eq 1 ] && [ "$p0_skip" -eq 0 ] && [ "$p0_pass" -eq 0 ] && [ "$p0_status" -eq 1 ]; then
    pass "P0/self-test: a missing source file raises FAIL (never SKIP) and drives this file's exit code to 1"
else
    fail "P0/self-test: expected 1 FAIL / 0 SKIP / 0 PASS / status 1 for an absent source path (pass=$p0_pass fail=$p0_fail skip=$p0_skip status=$p0_status)"
fi

# P0/contrast — the gap being closed, stated as an assertion rather than a comment:
# the pre-existing require_source() path answers the same absence with a SKIP and
# leaves the suite green. P0 is the only thing standing between that and a false green.
P0_CONTRAST="$(
    PASS=0; FAIL=0; SKIP=0
    require_source "$P0_ABSENT" "probe" >/dev/null
    printf '%s %s %s\n' "$FAIL" "$SKIP" "$(suite_status)"
)"
read -r p0c_fail p0c_skip p0c_status <<< "$P0_CONTRAST"
if [ "$p0c_fail" -eq 0 ] && [ "$p0c_skip" -eq 1 ] && [ "$p0c_status" -eq 0 ]; then
    pass "P0/contrast: require_source() alone answers the same absence with SKIP and a green exit — which is why P0 exists"
else
    fail "P0/contrast: expected require_source() to skip and keep the suite green (fail=$p0c_fail skip=$p0c_skip status=$p0c_status)"
fi

for _bin in git node; do
    if ! command -v "$_bin" >/dev/null 2>&1; then
        skip "T1 whole file ($_bin not available)"
        echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit "$(suite_status)"
    fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MAIN="$TMP/main"; LINKED="$TMP/linked"; WF="$TMP/wf"; PLANS="$TMP/plans"
mkdir -p "$WF" "$PLANS"
if ! git init -q -b main "$MAIN" 2>/dev/null; then git init -q "$MAIN"; fi
# The machine-wide core.hooksPath points at agents/hooks, whose pre-commit hook
# would reject this throwaway fixture repo. Same neutralization other tests use.
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name T
git -C "$MAIN" commit -q --allow-empty --no-verify -m init
git -C "$MAIN" worktree add -q -b feature/t1610-fixture "$LINKED"
if [ ! -e "$LINKED/.git" ]; then
    skip "T1 whole file (git worktree fixture could not be created)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit "$(suite_status)"
fi

MAIN_N="$(np "$MAIN")"; LINKED_N="$(np "$LINKED")"
export CLAUDE_WORKFLOW_DIR="$(np "$WF")"
export WORKFLOW_PLANS_DIR="$(np "$PLANS")"
export ENFORCE_WORKTREE=on
SID="feat1610t1"

# mk_state <branching_status> <session_worktree_node_path|""> [extra_top_level_json]
mk_state() {
    rm -f "$WF/$SID.workflow-off" "$WF/$SID.worktree-off"
    node -e '
const fs=require("fs"),path=require("path");
const [dir,sid,cwd,swt,br,extra]=process.argv.slice(1);
const st=(s)=>({status:s,updated_at:null});
const steps={};
for(const k of ["workflow_init","clarify_intent","research","outline","detail","branching_complete",
  "write_tests","review_tests","run_tests","review_security","docs","user_verification",
  "cleanup","pre_final_report_gate"]) steps[k]=st("pending");
steps.workflow_init=st("complete"); steps.clarify_intent=st("complete"); steps.branching_complete=st(br);
const state={version:1,session_id:sid,created_at:new Date().toISOString(),cwd,steps};
if(swt) state.session_worktree=swt;
if(extra) Object.assign(state,JSON.parse(extra));
fs.writeFileSync(path.join(dir,sid+".json"),JSON.stringify(state,null,2));
' "$CLAUDE_WORKFLOW_DIR" "$SID" "$MAIN_N" "$2" "$1" "${3:-}"
}

# mk_payload <tool> <tool_input_key|""> <value> <cwd|__OMIT__> <agent_id|"">
mk_payload() {
    node -e '
const [tool,key,val,cwd,agent,sid]=process.argv.slice(1);
const o={tool_name:tool,tool_input:{},session_id:sid};
if(key) o.tool_input[key]=val;
if(cwd!=="__OMIT__") o.cwd=cwd;
if(agent) o.agent_id=agent;
process.stdout.write(JSON.stringify(o));
' "$1" "$2" "$3" "$4" "$5" "$SID"
}

run_gate() { printf '%s' "$1" | run_with_timeout 90 node "$GATE_HOOK" 2>/dev/null; }
run_ew() { ( cd "$MAIN" && printf '%s' "$1" | run_with_timeout 90 node "$EW_HOOK" 2>/dev/null ); }

# reason_of <hook stdout> -> the decoded `reason` string (empty when absent)
reason_of() {
    printf '%s' "$1" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  const lines=d.trim().split("\n").filter(Boolean);
  for(let i=lines.length-1;i>=0;i--){try{const j=JSON.parse(lines[i]);if(j&&typeof j.reason==="string"){process.stdout.write(j.reason);return;}}catch(e){}}
});'
}

count_of() { printf '%s' "$1" | grep -oF "$2" | wc -l | tr -d ' '; }

expect_block() { # desc, payload
    local out rc; out="$(run_gate "$2")"; rc=$?
    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF '"decision":"block"'; then pass "$1"
    else fail "$1 (rc=$rc, out=$out)"; fi
}
expect_no_block() { # desc, payload
    local out rc; out="$(run_gate "$2")"; rc=$?
    if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -qF '"decision":"block"'; then pass "$1"
    else fail "$1 (rc=$rc, out=$out)"; fi
}
check_has() { # desc, needle, haystack
    if printf '%s' "$3" | grep -qF "$2"; then pass "$1"; else fail "$1 -- missing [$2] in: $3"; fi
}
check_lacks() { # desc, needle, haystack
    if printf '%s' "$3" | grep -qF "$2"; then fail "$1 -- unexpected [$2] in: $3"; else pass "$1"; fi
}

# ---------------------------------------------------------------- Section G --
# Tier 3 in isolation. Every case is gated on the new module so an unimplemented
# tree skips instead of failing.

g_payload_main() { mk_payload Write file_path "$MAIN_N/x.md" "$MAIN_N" ""; }

run_G1() {
    require_source "$ENTRY_GATE" "G1: CWD outside session worktree -> block with full diagnosis" || return
    mk_state complete "$LINKED_N"
    local p out rc reason; p="$(g_payload_main)"; out="$(run_gate "$p")"; rc=$?
    reason="$(reason_of "$out")"
    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF '"decision":"block"'; then
        check_has "G1a: reason cites the shared protocol" "skills/_shared/worktree-transition.md" "$reason"
        check_has "G1b: reason cites WORKTREE_OFF escape hatch" "WORKFLOW_ENFORCE_WORKTREE_OFF" "$reason"
        check_has "G1c: reason cites WORKFLOW_OFF escape hatch" "WORKFLOW_ENFORCE_WORKFLOW_OFF" "$reason"
        check_has "G1d: reason names the session worktree" "Session worktree:" "$reason"
    else
        fail "G1: expected block (rc=$rc, out=$out)"
    fi
}

run_G2() {
    require_source "$ENTRY_GATE" "G2: no state file -> dormant" || return
    rm -f "$WF/$SID.json"
    expect_no_block "G2: no state file -> dormant" "$(g_payload_main)"
}

run_G3() {
    require_source "$ENTRY_GATE" "G3: branching_complete skipped -> dormant" || return
    mk_state skipped "$LINKED_N"
    expect_no_block "G3: branching_complete skipped -> dormant" "$(g_payload_main)"
}

run_G4() {
    require_source "$ENTRY_GATE" "G4: session WORKTREE_OFF marker -> dormant" || return
    mk_state complete "$LINKED_N"; : > "$WF/$SID.worktree-off"
    expect_no_block "G4: session WORKTREE_OFF marker -> dormant" "$(g_payload_main)"
    rm -f "$WF/$SID.worktree-off"
}

run_G5() {
    require_source "$ENTRY_GATE" "G5: session WORKFLOW_OFF marker -> dormant" || return
    mk_state complete "$LINKED_N"; : > "$WF/$SID.workflow-off"
    expect_no_block "G5: session WORKFLOW_OFF marker -> dormant" "$(g_payload_main)"
    rm -f "$WF/$SID.workflow-off"
}

run_G6() {
    require_source "$ENTRY_GATE" "G6: plans-dir write stays allowlisted ahead of Tier 3" || return
    mk_state complete "$LINKED_N"
    expect_no_block "G6: plans-dir write stays allowlisted ahead of Tier 3" \
        "$(mk_payload Write file_path "$WORKFLOW_PLANS_DIR/$SID-detail.md" "$MAIN_N" "")"
}

run_G7() {
    require_source "$ENTRY_GATE" "G7: CWD inside the session worktree -> dormant" || return
    mk_state complete "$LINKED_N"
    expect_no_block "G7: CWD inside the session worktree -> dormant" \
        "$(mk_payload Write file_path "$LINKED_N/x.md" "$LINKED_N" "")"
}

run_G8() {
    require_source "$ENTRY_GATE" "G8: Bash stays open so cd-based entry is possible" || return
    mk_state complete "$LINKED_N"
    local out; out="$(run_gate "$(mk_payload Bash command "cd $LINKED_N" "$MAIN_N" "")")"
    check_lacks "G8: Bash stays open so cd-based entry is possible" "Session worktree:" "$out"
}

run_G9() {
    require_source "$ENTRY_GATE" "G9: subagent call is advisory, not blocked" || return
    mk_state complete "$LINKED_N"
    expect_no_block "G9: subagent call is advisory, not blocked" \
        "$(mk_payload Write file_path "$MAIN_N/x.md" "$MAIN_N" "sub-1")"
}

run_G10() {
    require_source "$ENTRY_GATE" "G10: writing INTO the worktree from outside still blocks" || return
    mk_state complete "$LINKED_N"
    local p out rc reason
    p="$(mk_payload Write file_path "$LINKED_N/x.md" "$MAIN_N" "")"
    out="$(run_gate "$p")"; rc=$?; reason="$(reason_of "$out")"
    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF '"decision":"block"'; then
        check_has "G10: writing INTO the worktree from outside still blocks" \
            "does not establish the binding" "$reason"
    else
        fail "G10: expected block for in-worktree path with outside CWD (rc=$rc, out=$out)"
    fi
}

run_G11() {
    require_source "$ENTRY_GATE" "G11: ENFORCE_WORKTREE=off -> dormant" || return
    mk_state complete "$LINKED_N"
    local p out rc; p="$(g_payload_main)"
    out="$( export ENFORCE_WORKTREE=off; printf '%s' "$p" | run_with_timeout 90 node "$GATE_HOOK" 2>/dev/null )"
    rc=$?
    if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -qF '"decision":"block"'; then
        pass "G11: ENFORCE_WORKTREE=off -> dormant"
    else
        fail "G11: ENFORCE_WORKTREE=off -> dormant (rc=$rc, out=$out)"
    fi
}

run_G12() {
    require_source "$ENTRY_GATE" "G12: missing input.cwd -> dormant (fail-open)" || return
    mk_state complete "$LINKED_N"
    expect_no_block "G12: missing input.cwd -> dormant (fail-open)" \
        "$(mk_payload Write file_path "$MAIN_N/x.md" __OMIT__ "")"
}

run_G13() {
    require_source "$ENTRY_GATE" "G13: stale worktree_entered_at does not override CWD evidence" || return
    mk_state complete "$LINKED_N" "{\"worktree_entered_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    expect_block "G13: stale worktree_entered_at does not override CWD evidence" "$(g_payload_main)"
}

run_G14() {
    require_source "$ENTRY_GATE" "G14: branching_complete complete but no recorded session worktree -> dormant" || return
    # Isolated from G2 (no state file at all) and G3 (branching_complete=skipped):
    # here the state file exists and branching_complete=complete, but no
    # session_worktree key was ever written (resolveSessionWorktreePath -> null).
    mk_state complete ""
    expect_no_block "G14: branching_complete complete but no recorded session worktree -> dormant" "$(g_payload_main)"
}

run_G15() {
    require_source "$ENTRY_GATE" "G15: win32 case-insensitive path match -> dormant" || return
    local platform
    platform="$(node -e 'process.stdout.write(process.platform)' 2>/dev/null)"
    if [ "$platform" != "win32" ]; then
        skip "G15: win32 case-insensitive path match -> dormant (win32-only branch, platform=$platform)"
        return
    fi
    mk_state complete "$LINKED_N"
    local cwd_upper
    cwd_upper="$(printf '%s' "$LINKED_N" | tr 'a-z' 'A-Z')"
    expect_no_block "G15: win32 case-insensitive path match -> dormant" \
        "$(mk_payload Write file_path "$LINKED_N/x.md" "$cwd_upper" "")"
}

# ---------------------------------------------------------------- Section H --
# Double-block contract + forbidden-literal pinning on the REAL hook output.

H_READY=0
h_setup() {
    if [ ! -f "$ENTRY_GATE" ] || [ ! -f "$REMEDY" ]; then return 1; fi
    return 0
}
if h_setup; then H_READY=1; fi

h_skip() { skip "$1 (source not implemented yet)"; }

run_H() {
    if [ "$H_READY" -ne 1 ]; then
        for d in \
            "H1: both PreToolUse hooks block the same payload" \
            "H2: enforce-worktree defers the entry procedure to the shared protocol" \
            "H3: Tier 3 owns the 'Session worktree:' diagnosis" \
            "H4: write into linked worktree — Tier 3 only" \
            "H5: branching_complete pending falls back to the current wording" \
            "H6: workflow-gate reason carries no entry-procedure literals" \
            "H7: enforce-worktree reason carries no entry-procedure literals"; do
            h_skip "$d"
        done
        return
    fi

    # H1..H3, H6, H7 share one payload: write under MAIN with CWD at MAIN.
    mk_state complete "$LINKED_N"
    local p gate_out ew_out gate_reason ew_reason
    p="$(g_payload_main)"
    gate_out="$(run_gate "$p")"; ew_out="$(run_ew "$p")"
    gate_reason="$(reason_of "$gate_out")"; ew_reason="$(reason_of "$ew_out")"

    if printf '%s' "$gate_out" | grep -qF '"decision":"block"' \
       && printf '%s' "$ew_out" | grep -qF '"decision":"block"'; then
        pass "H1: both PreToolUse hooks block the same payload"
    else
        fail "H1: both PreToolUse hooks block the same payload (gate=$gate_out ew=$ew_out)"
    fi

    check_lacks "H2a: enforce-worktree drops the stale /worktree-start remedy" \
        "Run: /worktree-start" "$ew_reason"
    check_has "H2b: enforce-worktree points at the shared protocol" \
        "skills/_shared/worktree-transition.md" "$ew_reason"

    check_has "H3a: workflow-gate owns 'Session worktree:'" "Session worktree:" "$gate_reason"
    check_lacks "H3b: enforce-worktree does not restate 'Session worktree:'" \
        "Session worktree:" "$ew_reason"

    # H4 — target path inside the linked worktree, CWD still outside it.
    local p4 gate4 ew4
    p4="$(mk_payload Write file_path "$LINKED_N/x.md" "$MAIN_N" "")"
    gate4="$(run_gate "$p4")"; ew4="$(run_ew "$p4")"
    if printf '%s' "$gate4" | grep -qF '"decision":"block"' \
       && ! printf '%s' "$ew4" | grep -qF '"decision":"block"'; then
        pass "H4: write into linked worktree — Tier 3 only"
    else
        fail "H4: write into linked worktree — Tier 3 only (gate=$gate4 ew=$ew4)"
    fi

    # H5 — no worktree recorded yet: enforce-worktree keeps its default remedy,
    # Tier 3 stays dormant.
    mk_state pending ""
    local p5 gate5 ew5 ew5_reason gate5_reason
    p5="$(g_payload_main)"
    gate5="$(run_gate "$p5")"; ew5="$(run_ew "$p5")"
    ew5_reason="$(reason_of "$ew5")"; gate5_reason="$(reason_of "$gate5")"
    if printf '%s' "$ew5" | grep -qF '"decision":"block"'; then
        check_has "H5a: default branch keeps the current /worktree-start wording" \
            "Run: /worktree-start" "$ew5_reason"
    else
        fail "H5a: expected enforce-worktree block for pending branching_complete (ew=$ew5)"
    fi
    check_lacks "H5b: Tier 3 dormant while branching_complete is pending" \
        "Session worktree:" "$gate5_reason"

    # H6 / H7 — the entry procedure itself is the fragment's property.
    local lit n
    local h6_bad=0 h7_bad=0
    for lit in 'EnterWorktree' 'cd "' '/worktree-start' 'git rev-parse'; do
        printf '%s' "$gate_reason" | grep -qF "$lit" && h6_bad=1
        printf '%s' "$ew_reason" | grep -qF "$lit" && h7_bad=1
    done
    n="$(count_of "$gate_reason" "worktree-transition.md")"
    if [ "$h6_bad" -eq 0 ] && [ "$n" = "1" ]; then
        pass "H6: workflow-gate reason carries no entry-procedure literals (fragment ref x1)"
    else
        fail "H6: workflow-gate reason literal contract (bad=$h6_bad refs=$n) reason=$gate_reason"
    fi
    n="$(count_of "$ew_reason" "worktree-transition.md")"
    if [ "$h7_bad" -eq 0 ] && [ "$n" = "1" ]; then
        pass "H7: enforce-worktree reason carries no entry-procedure literals (fragment ref x1)"
    else
        fail "H7: enforce-worktree reason literal contract (bad=$h7_bad refs=$n) reason=$ew_reason"
    fi
}

run_G1; run_G2; run_G3; run_G4; run_G5; run_G6; run_G7
run_G8; run_G9; run_G10; run_G11; run_G12; run_G13
run_G14; run_G15
run_H

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$(suite_status)"
