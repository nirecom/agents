#!/usr/bin/env bash
# Tests: hooks/lib/protected-basenames.js, hooks/enforce-worktree.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/enforce-worktree/handle-bash-write.js, hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/lib/claude-scratchpad-base.js
# Tags: protected-basename, ssot, marker-gate, session-context, enforce-worktree, block-clearance-token-write, scratchpad, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Sections C2..C4 + D — everything AROUND the stem rule. C2: exactly one stem rule
# exists (a second copy is how the two call chains drift apart). C3: the marker gate's
# allow fast-path, asserted on its own functions only — never on a final verdict, which
# depends on worktree state this fixture does not own. C4: the stdin session_id has to
# REACH the classifier at all four call sites, otherwise every C1 allow silently
# regresses to fail-closed. D: the F1 poisoned-TEMP counterweight to Section A.

run_C2_shared_predicate() {
    local ident reimpl cycle

    # C2-1 — runtime reference identity. Both call chains must reach the SAME regexp
    # object; a structurally-equal copy would satisfy a string comparison and still
    # drift on the next edit, so identity (===) is the assertion.
    ident="$(run_probe -e "const a=require(process.argv[1]),b=require(process.argv[2]);process.stdout.write(String(a.PROTECTED_MARKER_BASENAME_RE===b.PROTECTED_MARKER_BASENAME_RE))" "$MARKER_GATE_NODE" "$PB_NODE")"
    assert_eq "C2-1 marker-gate re-exports the SSOT regexp by reference" "true" "$ident"

    # C2-2 — no call site may re-implement the session-id shape. The stem rule is only
    # single-sourced if the uuid/timestamp bodies live in protected-basenames.js alone.
    # is-plan-artifact.js is excluded by name: it matches PLAN FILE names, has no part
    # in the clearance decision, and predates #2108. Narrow, named exception (CPR-UNV).
    reimpl="$(grep -rlE '\[0-9a-fA-F\]\{8\}-|\[0-9\]\{8\}-\[0-9\]\{6\}' "$AGENTS_DIR/hooks" 2>/dev/null | grep -v 'protected-basenames.js' | grep -v 'session-id' | grep -v 'is-plan-artifact.js' | head -5)"
    if [ -z "$reimpl" ]; then
        pass "C2-2 no hook re-implements the session-id shape outside the SSOT"
    else
        fail "C2-2 session-id shape re-implemented outside protected-basenames.js: $(printf '%s' "$reimpl" | tr '\n' ' ')"
    fi

    # C2-3 — R13 one-way dependency edge. protected-basenames.js may consume the
    # observation module; the observation module must NOT reach back, or the two form
    # a require cycle whose resolution order decides whether the narrowing applies.
    cycle="$(grep -cE "require\(.*protected-basenames" "$AGENTS_DIR/hooks/lib/active-session-ids.js" 2>/dev/null)"
    assert_eq "C2-3 active-session-ids.js does not require protected-basenames (R13)" "0" "$cycle"

    # C2-4 — and the module actually loads standalone. A require cycle or a missing
    # dependency would otherwise surface as an unrelated failure much later.
    assert_eq "C2-4 protected-basenames.js loads standalone" "ok" \
        "$(run_probe -e "require(process.argv[1]);process.stdout.write('ok')" "$PB_NODE")"
}

run_C3_marker_gate() {
    local probe

    # NOT an end-to-end verdict. These four assertions are on marker-gate's own two
    # predicates; whether a Bash write is finally blocked also depends on worktree
    # state, ENFORCE_WORKTREE and the clearance markers, none of which this fixture
    # owns. Asserting the final verdict here would make the case fixture-dependent.
    cat > "$PROBE_DIR/mg-probe.js" <<'PROBE_EOF'
"use strict";
const g = require(process.argv[2]);
const wf = process.env.CLAUDE_WORKFLOW_DIR;
const path = require("path");
const ctx = { sessionCtx: { sessionId: "wsid" } };
const inWf = (n) => path.join(wf, n);
const out = [];
out.push(`under-plain=${String(g.areAllBashTargetsUnderWorkflowDir([inWf("plain-note.txt")], ctx))}`);
out.push(`outside-wf=${String(g.areAllBashTargetsUnderWorkflowDir([inWf("plain-note.txt"), "/elsewhere/b.txt"], ctx))}`);
out.push(`under-artifact=${String(g.areAllBashTargetsUnderWorkflowDir([inWf("issue-2108-survey.gh-env")], ctx))}`);
out.push(`under-marker=${String(g.areAllBashTargetsUnderWorkflowDir([inWf("wsid.gh-env")], ctx))}`);
out.push(`hit-artifact=${String(g.bashTargetsHitProtectedMarker([inWf("issue-2108-survey.gh-env")], ctx))}`);
out.push(`hit-marker=${String(g.bashTargetsHitProtectedMarker([inWf("wsid.gh-env")], ctx))}`);
process.stdout.write(out.join("\n"));
PROBE_EOF
    probe="$(run_probe "$PROBE_DIR/mg-probe.js" "$MARKER_GATE_NODE")"
    if [ -z "$probe" ]; then
        fail "C3 marker-gate probe produced no output (module unusable)"
        return
    fi

    # C3-1/C3-2 pass today: they prove the probe drives the real predicate, so a
    # failure in C3-3..C3-6 is the stem rule and not a broken fixture.
    assert_eq "C3-1 plain file under the workflow dir is contained" "true" \
        "$(printf '%s\n' "$probe" | grep -F 'under-plain=' | sed 's/.*=//')"
    assert_eq "C3-2 a target outside the workflow dir breaks containment" "false" \
        "$(printf '%s\n' "$probe" | grep -F 'outside-wf=' | sed 's/.*=//')"
    # C3-3/C3-5: the artifact name must stop excluding itself from the allow
    # fast-path. C3-4/C3-6: the real marker must keep being excluded from it.
    assert_eq "C3-3 artifact stem no longer withholds the allow fast-path" "true" \
        "$(printf '%s\n' "$probe" | grep -F 'under-artifact=' | sed 's/.*=//')"
    assert_eq "C3-4 real session marker still withholds it (counterweight)" "false" \
        "$(printf '%s\n' "$probe" | grep -F 'under-marker=' | sed 's/.*=//')"
    assert_eq "C3-5 artifact stem does NOT hit the protected marker gate" "false" \
        "$(printf '%s\n' "$probe" | grep -F 'hit-artifact=' | sed 's/.*=//')"
    assert_eq "C3-6 real session marker still hits the gate (counterweight)" "true" \
        "$(printf '%s\n' "$probe" | grep -F 'hit-marker=' | sed 's/.*=//')"
}

# _c4_run <hook-path> <stdin-json> -> approve | block | unrecognized
# Every verdict-affecting input is pinned here rather than inherited: session-id env is
# unset (the stdin sid is the wiring under test), ENFORCE_WORKTREE is forced on, and
# AGENTS_CONFIG_DIR points at an EMPTY dir — hooks/lib/load-env.js overrides any var
# whose current value is falsy, so exporting "" would not shield these from a real .env
# and an unpinned exclude pattern could turn any route below into a silent approve.
_c4_run() {
    local hook="$1" input="$2"
    (
        cd "$FIX_REPO" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        unset ENFORCE_WORKTREE_EXCLUDE ENFORCE_WORKTREE_EXCLUDE_REPOS
        unset ENFORCE_WORKTREE_ADDITIONAL_REPOS ENFORCE_WORKTREE_EXTRA_REPOS
        export ENFORCE_WORKTREE=on
        export DEFAULT_BRANCHES=main
        export AGENTS_CONFIG_DIR="$C4_CONFIG"
        export CLAUDE_PROJECT_DIR="$FIX_REPO_NODE"
        export CLAUDE_WORKFLOW_DIR="$C4_WFDIR"
        # run_hook_capture carries the subprocess EXIT STATUS out as a token, so a crash
        # or a 20s timeout classifies as crash/timeout instead of collapsing into the
        # empty-stdout allow that every _c4_route "approve" leg would accept (review C1).
        gate_decision "$(run_hook_capture "$input" "$RWT" 20 node "$hook")"
    )
}

# _c4_route <label> <hook> <plain-json> <tp-json> <fp-json>
# Three calls, identical in every respect except the target BASENAME. The plain call
# proves the route reaches an ALLOW in this fixture, so a TP block cannot be attributed
# to worktree geography or any other ambient guard (review C5); the TP call proves the
# route reaches the classifier at all. Either one coming out wrong is a FAILURE, never
# a skip — a silent skip would let the whole section evaporate the moment the fixture
# drifts while the suite still reported green (review C4).
_c4_route() {
    local label="$1" hook="$2" plain="$3" tp="$4" fp="$5" pd tpd
    pd="$(_c4_run "$hook" "$plain")"
    if [ "$pd" != "approve" ]; then
        fail "C4 $label discriminator: a PLAIN basename was blocked too (verdict=$pd) - this route's block is not attributable to the marker classifier"
        return
    fi
    pass "C4 $label discriminator: a plain basename is allowed on this route"
    tpd="$(_c4_run "$hook" "$tp")"
    if [ "$tpd" != "block" ]; then
        fail "C4 $label control: <sid>-stemmed target was NOT blocked (verdict=$tpd) - route unexercised, FP assertion would be vacuous"
        return
    fi
    pass "C4 $label control: <sid>-stemmed target is blocked on this route"
    assert_eq "C4 $label artifact stem reaches the classifier (sessionCtx wired)" "approve" \
        "$(_c4_run "$hook" "$fp")"
}

# _c4_bash <command-text> -> PreToolUse-shaped stdin for the Bash tool, sid "wsid"
_c4_bash() {
    printf '{"session_id":"wsid","tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_esc "$1")"
}

run_C4_session_ctx_trace() {
    local wf w tp fp on

    # An EMPTY but READABLE workflow dir: the observation succeeds (complete:true) and
    # yields exactly the stdin sid, so any fail-closed verdict here means the stdin
    # session_id never arrived.
    wf="$TMPBASE_SH/c4-workflow"
    rm -rf "$wf" 2>/dev/null || true
    mkdir -p "$wf"
    C4_WFDIR="$(node_path "$wf")"
    w="${C4_WFDIR//\\//}"
    C4_CONFIG="$(node_path "$TMPBASE_SH/c4-config")"
    mkdir -p "$TMPBASE_SH/c4-config"

    # C4-0 — the fixture's own precondition, asserted rather than assumed. If
    # enforcement were off, every route below would approve for a reason that has
    # nothing to do with the stem rule and the section would silently pass.
    on="$(
        cd "$FIX_REPO" || exit 1
        unset ENFORCE_WORKTREE_EXCLUDE ENFORCE_WORKTREE_EXCLUDE_REPOS
        export ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$C4_CONFIG"
        run_probe -e "process.stdout.write(String(require(process.argv[1]).isEnforceWorktreeOn()))" \
            "$AGENTS_NODE/hooks/enforce-worktree/config.js"
    )"
    assert_eq "C4-0 enforce-worktree is ON under the pinned fixture env" "true" "$on"

    # Targets are ABSOLUTE and inside the workflow dir: that is where the marker gate
    # is load-bearing, because it is the workflow-dir allow fast-path that it withholds.
    # Route 1 - handle-bash-write.js:59, the simple redirect.
    _c4_route "route1 simple redirect (enforce-worktree)" "$EW_HOOK" \
        "$(_c4_bash "echo x > $w/plain-note.txt")" \
        "$(_c4_bash "echo x > $w/wsid.workflow-off")" \
        "$(_c4_bash "echo x > $w/issue-2108-survey.workflow-off")"

    # Route 2 - handle-bash-write.js:223, the sequenced/heredoc path via segment-checks.
    _c4_route "route2 sequenced heredoc (enforce-worktree)" "$EW_HOOK" \
        "$(_c4_bash "cd /tmp && cat > $w/plain-note.txt <<EOF\nx\nEOF")" \
        "$(_c4_bash "cd /tmp && cat > $w/wsid.workflow-off <<EOF\nx\nEOF")" \
        "$(_c4_bash "cd /tmp && cat > $w/issue-2108-survey.workflow-off <<EOF\nx\nEOF")"

    # Route 3 - handle-bash-write.js:239, the outside-scope branch. Target is outside
    # both the repo and the workflow dir, so the ALLOW here comes from a different
    # disjunct than routes 1/2 — which is why it gets its own row.
    _c4_route "route3 outside-scope write (enforce-worktree)" "$EW_HOOK" \
        "$(_c4_bash "cp a.txt /elsewhere/plain-note.txt")" \
        "$(_c4_bash "cp a.txt /elsewhere/wsid.off-clearance")" \
        "$(_c4_bash "cp a.txt /elsewhere/issue-2108-survey.off-clearance")"

    # Route 4 - block-clearance-token-write/dispatch.js:90, the Edit/Write path.
    tp='{"session_id":"wsid","tool_name":"Write","tool_input":{"file_path":"/tmp/wsid.off-clearance","content":"x"}}'
    fp='{"session_id":"wsid","tool_name":"Write","tool_input":{"file_path":"/tmp/issue-2108-survey.off-clearance","content":"x"}}'
    _c4_route "route4 Edit/Write dispatch (block-clearance-token-write)" "$BCTW_HOOK" \
        '{"session_id":"wsid","tool_name":"Write","tool_input":{"file_path":"/tmp/plain-note.txt","content":"x"}}' \
        "$tp" "$fp"

    # Route 5 - the DELETE direction. Every route above creates; removal is the opposite
    # half of the same guard (CPR-ORTH), and a narrowing that leaked only on `rm` would
    # let a subagent delete its own survey notes' namesake state file.
    _c4_route "route5 delete direction (enforce-worktree)" "$EW_HOOK" \
        "$(_c4_bash "rm -f $w/plain-note.txt")" \
        "$(_c4_bash "rm -f $w/wsid.workflow-off")" \
        "$(_c4_bash "rm -f $w/issue-2108-survey.workflow-off")"

    # Route 4b - the Bash spelling of the SAME hook keeps its tail match (R2c), so the
    # two spellings are observably different end to end, not just in the unit probe.
    local bash_fp
    bash_fp='{"session_id":"wsid","tool_name":"Bash","tool_input":{"command":"echo x > report-0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6.off-clearance"}}'
    # The R2c exception is the ONLY thing keeping the two spellings apart end to end,
    # so "not exercised" here is indistinguishable from "the exception was lost".
    assert_eq "C4 route4b bash spelling keeps the tail match (R2c)" "block" \
        "$(_c4_run "$BCTW_HOOK" "$bash_fp")"
}

run_D_f1_regression() {
    local poisoned poisoned_fwd out

    if [ "$REPO_OK" != yes ]; then
        skip "D F1 regression needs the git fixture repo (git unavailable)"
        return
    fi

    # F1 (fix-1441): the scratchpad allow is keyed on the OS temp dir, which an
    # attacker-controlled TEMP can move. Section A only proves the allow works; this
    # proves it cannot be relocated INTO a repo, where it would become an arbitrary
    # source-write channel for a pre-init subagent. Both conditions of
    # isAllowedScratchpadTarget must hold - under the allow root AND not in a repo.
    poisoned="$FIX_REPO/fake-tmp/claude/c--test-2108/sessA/scratchpad"
    mkdir -p "$poisoned"
    poisoned_fwd="${poisoned//\\//}"

    out="$(
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        export TMPDIR="$FIX_REPO_NODE/fake-tmp" TEMP="$FIX_REPO_NODE/fake-tmp" TMP="$FIX_REPO_NODE/fake-tmp"
        export SCRATCHPAD="$poisoned_fwd"
        printf '%s' "$(mk_edit_input Write "$SID_T1" "$poisoned_fwd/steal.md")" | MSYS_NO_PATHCONV=1 "$RWT" 20 node "$GATE_HOOK" 2>/dev/null
    )"
    assert_eq "D1 poisoned TEMP inside a repo does NOT open the scratchpad allow" "block" \
        "$(gate_decision "$out")"

    # D2 - Pattern 1 negative assertion: the blocked target must not exist afterwards.
    if [ -e "$poisoned/steal.md" ]; then fail "D2 blocked poisoned-scratchpad target was created"
    else pass "D2 blocked poisoned-scratchpad target remains absent"; fi

    # D3 - counterweight: with TEMP honest again the very same shape is allowed, so D1
    # is proving the repo-containment clause and not merely a broken allowlist.
    out="$(run_gate "$(mk_edit_input Write "$SID_T1" "$SCRATCH_A_FWD/honest.md")" "$SCRATCH_A")"
    assert_eq "D3 honest scratchpad target is still allowed" "approve" "$(gate_decision "$out")"

    # D4 - the predicate itself, both directions in one call (Pattern 4). SAME path and
    # SAME allow root on both legs; only the repo-containment answer differs, which
    # isolates the F1 clause from the "under the allow root" clause. The target is the
    # honest scratchpad, so a `false` can only come from the repo clause.
    local pred
    pred="$(
        export SCRATCHPAD="$SCRATCH_A"
        run_probe -e "const m=require(process.argv[1]);const t=process.argv[2],r=process.argv[3];process.stdout.write([m.isAllowedScratchpadTarget(t,()=>r),m.isAllowedScratchpadTarget(t,()=>null)].join(','))" "$AGENTS_NODE/hooks/lib/claude-scratchpad-base.js" "$SCRATCH_A_FWD/probe.md" "$FIX_REPO_NODE" 2>/dev/null
    )"
    if [ -n "$pred" ]; then
        assert_eq "D4 isAllowedScratchpadTarget: in-repo false, non-repo true" "false,true" "$pred"
    else
        skip "D4 isAllowedScratchpadTarget not exported yet (S3a not implemented)"
    fi
}
