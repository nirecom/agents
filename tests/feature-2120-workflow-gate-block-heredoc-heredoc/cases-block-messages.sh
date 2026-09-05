# Tests: hooks/workflow-gate/early-gate-messages.js, hooks/enforce-worktree.js, hooks/enforce-worktree/handle-edit-write.js, hooks/workflow-gate/worktree-entry-gate.js, hooks/lib/alt-target-remedy.js
# Tags: workflow-gate, enforce-worktree, block-message, scope:issue-specific
# M1-M6 — the #2120 block-message contract at all four sites: stop advertising
# Bash, and name an alternative write target the agent can actually reach.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

# M1 (#2120 cases 1-3) — buildEarlyGateReason must stop advertising Bash, in BOTH
# identity branches (they share READ_TOOLS_NOTE, CPR-ORTH). The note is NARROWED,
# never deleted: the read-only tools are asserted present in the same breath.
run_M1() {
    local ctx tier r
    for tier in workflow_init clarify_intent; do
        for ctx in main subagent; do
            r="$(run_with_timeout 30 node -e '
const {buildEarlyGateReason}=require(process.argv[1]);
process.stdout.write(buildEarlyGateReason({tier:process.argv[2],toolName:"Write",isSubagent:process.argv[3]==="subagent"}));
' "$EARLY_MSG" "$tier" "$ctx" 2>/dev/null)"
            if [ -z "$r" ]; then fail "M1 $tier/$ctx produced no reason — every assertion below would be vacuous"; continue; fi
            pass "M1 $tier/$ctx produced a reason string"
            lacks "M1 $tier/$ctx no longer advertises Bash" "Bash" "$r"
            has   "M1 $tier/$ctx keeps Read/Grep/Glob"      "Read, Grep, Glob" "$r"
            has   "M1 $tier/$ctx keeps AskUserQuestion"     "AskUserQuestion"  "$r"
        done
    done
}

# M2 (#2120 case 5) — Bash write from the MAIN worktree. The verdict is unchanged
# (still block); what the fix adds is a target the agent can actually write to.
run_M2() {
    local out r
    out="$(ew_run "$MAIN" "$(bash_payload "rm -rf $MAIN_N/README.md")")"
    if is_block "$out"; then pass "M2: Bash write from main worktree still BLOCKS (verdict unchanged)"
    else fail "M2: expected block from main worktree, got: $out"; return; fi
    r="$(reason_of "$out")"
    has "M2: reason still names the main-worktree diagnosis" "main worktree" "$r"
    alt_target_wording "M2 main-worktree Bash block" "$r"
}

# M3 (#2120 case 6) — Bash write on a PROTECTED branch in a linked worktree.
# DEFAULT_BRANCHES is pinned: a config-dependent branch must never be decided by
# the ambient repo's protected set.
run_M3() {
    local out r
    [ -e "$LINKED/.git" ] || { skip "!! M3 NOT RUN — linked-worktree fixture unavailable; see the M0b FAIL above. This is missing coverage, NOT a pass."; return; }
    out="$(DEFAULT_BRANCHES=feature/t2120-fixture ew_run "$LINKED" "$(bash_payload "rm -rf $LINKED_N/README.md")")"
    if is_block "$out"; then pass "M3: Bash write on protected branch still BLOCKS (verdict unchanged)"
    else fail "M3: expected protected-branch block, got: $out"; return; fi
    r="$(reason_of "$out")"
    has "M3: reason still names the protected-branch diagnosis" "protected branch" "$r"
    alt_target_wording "M3 protected-branch Bash block" "$r"
}

# M4 (#2120 case 7) — the Edit/Write/MultiEdit half (handle-edit-write.js).
# CPR-ORTH sibling of M2: the same remedy must reach the agent whichever tool it
# reached for, or it just switches tools and gets blocked again.
run_M4() {
    local tool out r
    for tool in Write Edit MultiEdit; do
        out="$(ew_run "$MAIN" "$(edit_payload "$MAIN_N/README.md" "$tool")")"
        if is_block "$out"; then pass "M4/$tool: main-worktree edit still BLOCKS (verdict unchanged)"
        else fail "M4/$tool: expected block, got: $out"; continue; fi
        r="$(reason_of "$out")"
        has "M4/$tool: reason still names the main-worktree diagnosis" "main worktree" "$r"
        alt_target_wording "M4/$tool main-worktree edit block" "$r"
    done
}

# M4b (C1, test-review round 1) — the BATCH branch of handle-edit-write.js
# (Array.isArray(toolInput.edits) && toolInput.edits.length > 0, lines ~36-72)
# is a distinct code path from the single-file fall-through M4 exercises above:
# it loops collectEditWritePaths(), skipping EXCLUDE and non-git-scope targets
# per-edit before ever reaching the main-worktree / protected-branch checks. A
# real MultiEdit-shaped payload (top-level file_path + edits[] with no path of
# its own) must reach that loop and still block from the main worktree.
run_M4b() {
    local out r
    out="$(ew_run "$MAIN" "$(multiedit_payload "$MAIN_N/README.md")")"
    if is_block "$out"; then pass "M4b: genuine MultiEdit batch payload from main worktree still BLOCKS"
    else fail "M4b: expected block from main-worktree MultiEdit batch, got: $out"; return; fi
    r="$(reason_of "$out")"
    has "M4b: reason still names the main-worktree diagnosis" "main worktree" "$r"
    alt_target_wording "M4b main-worktree MultiEdit batch block" "$r"

    # Bug 1 (EXCLUDE-skip): a batch whose ONLY named target matches the built-in
    # .worktree-backup/** exclude must fall through the loop with every edit
    # skipped (`continue`) and reach the trailing `done()` (allow) -- never the
    # main-worktree block above, even though CWD is still the main worktree.
    # assert_allowed (not `if is_block ... else pass`) so a crash/timeout/empty
    # stdout fails instead of false-greening as "allowed" -- C7, round 2.
    assert_allowed "M4b EXCLUDE-skip: per-edit EXCLUDE match is skipped, batch allowed" \
        "$MAIN" "$(multiedit_payload "" "$MAIN_N/.worktree-backup/x.txt")"

    # Bug 2 (non-git-path-skip): a batch target outside any git repo is skipped
    # the same way -- not blocked, not crashed.
    assert_allowed "M4b non-git-skip: per-edit non-git-scope target is skipped, batch allowed" \
        "$MAIN" "$(multiedit_payload "" "$TMP/not-a-repo/x.txt")"

    # Mixed batch (handle-edit-write.js comment: "a mixed-repo batch must not
    # slip through"): the FIRST edit is excluded (skip/continue), the SECOND
    # is a real main-worktree target -- the loop must still reach and block on
    # the second, proving the skip does not short-circuit the whole call.
    out="$(ew_run "$MAIN" "$(multiedit_payload "" "$MAIN_N/.worktree-backup/x.txt" "$MAIN_N/README.md")")"
    if is_block "$out"; then pass "M4b mixed-batch: an excluded first edit does not shadow a blocking second edit"
    else fail "M4b mixed-batch: expected block on the second (non-excluded) edit, got: $out"; fi
}

# M5 (#2120 case 8) — Edit/Write on a protected branch in a linked worktree.
run_M5() {
    local out r
    [ -e "$LINKED/.git" ] || { skip "!! M5 NOT RUN — linked-worktree fixture unavailable; see the M0b FAIL above. This is missing coverage, NOT a pass."; return; }
    out="$(DEFAULT_BRANCHES=feature/t2120-fixture ew_run "$LINKED" "$(edit_payload "$LINKED_N/README.md" Write)")"
    if is_block "$out"; then pass "M5: protected-branch edit still BLOCKS (verdict unchanged)"
    else fail "M5: expected protected-branch block, got: $out"; return; fi
    r="$(reason_of "$out")"
    has "M5: reason still names the protected-branch diagnosis" "protected branch" "$r"
    alt_target_wording "M5 protected-branch edit block" "$r"
}

# M5b (C1) — CPR-ORTH sibling of M4b: the batch branch's protected-branch check
# (`if (branch && protected_.includes(branch))`, the SECOND block site inside
# the same loop) must also fire on a genuine MultiEdit batch payload.
run_M5b() {
    local out r
    [ -e "$LINKED/.git" ] || { skip "!! M5b NOT RUN — linked-worktree fixture unavailable; see the M0b FAIL above. This is missing coverage, NOT a pass."; return; }
    out="$(DEFAULT_BRANCHES=feature/t2120-fixture ew_run "$LINKED" "$(multiedit_payload "$LINKED_N/README.md")")"
    if is_block "$out"; then pass "M5b: genuine MultiEdit batch payload on protected branch still BLOCKS"
    else fail "M5b: expected protected-branch block from MultiEdit batch, got: $out"; return; fi
    r="$(reason_of "$out")"
    has "M5b: reason still names the protected-branch diagnosis" "protected branch" "$r"
    alt_target_wording "M5b protected-branch MultiEdit batch block" "$r"
}

# mk_tier3_state — branching_complete + a real linked worktree, so Tier 3 arms.
mk_tier3_state() {
    rm -f "$WF/$SID.workflow-off" "$WF/$SID.worktree-off"
    run_with_timeout 30 node -e '
const fs=require("fs"),path=require("path");
const [dir,sid,cwd,swt]=process.argv.slice(1);
const st=(s)=>({status:s,updated_at:null});
const steps={};
for(const k of ["workflow_init","clarify_intent","research","outline","detail","branching_complete",
  "write_tests","review_tests","run_tests","review_security","docs","user_verification",
  "cleanup","pre_final_report_gate"]) steps[k]=st("pending");
steps.workflow_init=st("complete"); steps.clarify_intent=st("complete"); steps.branching_complete=st("complete");
const state={version:1,session_id:sid,created_at:new Date().toISOString(),cwd,steps,session_worktree:swt};
fs.writeFileSync(path.join(dir,sid+".json"),JSON.stringify(state,null,2));
' "$CLAUDE_WORKFLOW_DIR" "$SID" "$MAIN_N" "$LINKED_N" 2>/dev/null
}

# M6 (#2120 case 9) — Tier 3 worktree-entry gate, in two layers: the reason builder
# the fix edits (M6a), and the real workflow-gate.js process (M6b), so a builder
# that is edited but never reached is still caught.
run_M6() {
    local r out gr
    r="$(run_with_timeout 30 node -e '
const {buildBlockReason}=require(process.argv[1]);
process.stdout.write(buildBlockReason({toolName:"Write",worktreePath:"/wt",cwd:"/elsewhere"}));
' "$ENTRY_GATE" 2>/dev/null)"
    if [ -z "$r" ]; then fail "M6a: buildBlockReason produced nothing — assertions would be vacuous"
    else
        pass "M6a: buildBlockReason produced a reason string"
        lacks "M6a: Tier 3 reason no longer advertises Bash" "Bash" "$r"
        has   "M6a: Tier 3 reason keeps Read/Grep/Glob"      "Read, Grep, Glob" "$r"
        has   "M6a: Tier 3 reason keeps AskUserQuestion"     "AskUserQuestion"  "$r"
        has   "M6a: Tier 3 reason keeps the escape hatches"  "WORKFLOW_ENFORCE_WORKTREE_OFF" "$r"
        alt_target_wording "M6a Tier 3 gate" "$r"
    fi

    [ -e "$LINKED/.git" ] || { skip "!! M6b NOT RUN — linked-worktree fixture unavailable; see the M0b FAIL above. This is missing coverage, NOT a pass."; return; }
    mk_tier3_state
    out="$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1]},cwd:process.argv[2],session_id:process.argv[3]}))' -- "$MAIN_N/x.txt" "$MAIN_N" "$SID" | run_with_timeout 60 node "$GATE_HOOK" 2>/dev/null)"
    if is_block "$out"; then
        pass "M6b: Tier 3 gate verdict is still block (CWD outside the session worktree)"
        gr="$(reason_of "$out")"
        lacks "M6b: real Tier 3 block reason no longer advertises Bash" "Bash" "$gr"
        alt_target_wording "M6b Tier 3 gate (real hook)" "$gr"
    else
        fail "M6b: expected a Tier 3 block from the real gate, got: $out"
    fi
}
