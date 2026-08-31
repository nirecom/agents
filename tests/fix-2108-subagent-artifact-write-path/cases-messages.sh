#!/usr/bin/env bash
# Tests: hooks/workflow-gate/early-gate.js, hooks/workflow-gate/early-gate-messages.js, hooks/lib/subagent-detect.js
# Tags: workflow-gate, early-gate, subagent, block-message, sentinel, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section B — block wording (Scope 3 of #2108). The verdict stays `block` in both
# contexts; what branches is the REMEDY. A subagent can neither invoke a skill nor
# emit a sentinel, so a message naming only those two routes describes an exit that
# does not exist and pushes the agent to hunt for a bypass. Main-conversation callers
# must keep every sentinel line they have today (Pattern 4: both directions), and both
# tiers must carry the same section structure (CPR-ORTH, one shared builder).

# _b_reason <sid> [agent_id] [SCRATCHPAD value, "-" = unset]
_b_reason() {
    local sid="$1" agent="${2:-}" sp="${3:-$SCRATCH_A}"
    gate_reason "$(run_gate "$(mk_edit_input Write "$sid" "$REPO_FWD/src/blocked.js" "$agent")" "$sp")"
}

# Path comparison for message assertions: case- and separator-insensitive. The gate
# advertises a NATIVE resolved path, and hooks/lib/claude-scratchpad-base.js folds case
# on win32, so a raw string compare would fail on spelling rather than on substance.
_b_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr '\\' '/'; }

run_B_block_messages() {
    local plans_native scratch_native r1 r2 s1 s2 tier

    plans_native="$(node -e "process.stdout.write(require('path').resolve(process.env.WORKFLOW_PLANS_DIR))" 2>/dev/null)"
    scratch_native="$SCRATCH_A"

    r1="$(_b_reason "$SID_T1")"
    r2="$(_b_reason "$SID_T2")"
    s1="$(_b_reason "$SID_T1" agent-2108)"
    s2="$(_b_reason "$SID_T2" agent-2108)"

    # B0 — harness guard: an empty reason would make every assertion below vacuous.
    if [ -n "$r1" ]; then pass "B0 Tier 1 block produced a reason string"
    else fail "B0 Tier 1 produced no reason - Section B would be vacuous"; fi
    if [ -n "$r2" ]; then pass "B0 Tier 2 block produced a reason string"
    else fail "B0 Tier 2 produced no reason - Section B would be vacuous"; fi

    # B1 — diagnosis line still names the step that is pending (both tiers).
    assert_contains "B1 Tier 1 names workflow_init" "workflow_init has not been completed" "$r1"
    assert_contains "B1 Tier 2 names clarify_intent" "clarify_intent has not been completed" "$r2"

    # B2 — main conversation keeps ALL of today's sentinel guidance (regression guard
    # for R8: the rewrite must not quietly drop the routes main callers depend on).
    assert_contains "B2 T1 main keeps mark-step sentinel" "<<WORKFLOW_MARK_STEP_workflow_init_complete>>" "$r1"
    assert_contains "B2 T1 main keeps reset sentinel" "<<WORKFLOW_RESET_FROM_workflow_init" "$r1"
    assert_contains "B2 T1 main keeps skill route" "workflow-init" "$r1"
    assert_contains "B2 T2 main keeps not-needed sentinel" "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED" "$r2"
    assert_contains "B2 T2 main keeps reset sentinel" "<<WORKFLOW_RESET_FROM_clarify_intent" "$r2"
    assert_contains "B2 T2 main keeps skill route" "clarify-intent" "$r2"

    # B3 — both tiers must name the write targets that ARE still open. This is the
    # line whose absence produced #2108: the agent was told what it could not do and
    # nothing about what it could.
    for tier in 1 2; do
        local r; [ "$tier" = 1 ] && r="$r1" || r="$r2"
        assert_contains "B3 Tier $tier main names the plans dir"  "$plans_native"   "$r"
        assert_contains "B3 Tier $tier main names the scratchpad" "$scratch_native" "$r"
        # DELIBERATE EDIT (#2120): this assertion used to require "Read, Grep, Glob, Bash".
        # Naming Bash in a block message is what #2120 is about — the agent reads it as
        # "Bash is the way through", reaches for a Bash write, and enforce-worktree /
        # the write-detector blocks it again. The note must keep the genuinely read-only
        # tools and drop Bash; the narrowed substring plus the negative assertion below
        # is what pins that, so a re-added "Bash" cannot pass silently.
        assert_contains "B3 Tier $tier main keeps the read-tools note" "Read, Grep, Glob" "$r"
        assert_not_contains "B3 Tier $tier main note no longer advertises Bash" "Bash" "$r"
        assert_contains "B3 Tier $tier main note keeps AskUserQuestion" "AskUserQuestion" "$r"
    done

    # B3b (#2120) — CPR-ORTH: both branches share READ_TOOLS_NOTE, so the subagent
    # message must lose Bash on exactly the same terms. Asserting only the main
    # branch would let a branch-local re-add of "Bash" survive.
    for tier in 1 2; do
        local s; [ "$tier" = 1 ] && s="$s1" || s="$s2"
        assert_contains "B3b Tier $tier subagent keeps the read-tools note" "Read, Grep, Glob" "$s"
        assert_not_contains "B3b Tier $tier subagent note no longer advertises Bash" "Bash" "$s"
        assert_contains "B3b Tier $tier subagent note keeps AskUserQuestion" "AskUserQuestion" "$s"
    done

    # B4 — subagent context: NOT ONE sentinel literal may appear. Asserting the
    # presence of the advisory alone would pass a message that still dangles the
    # impossible route beside it, so the negative assertion is the load-bearing one.
    assert_not_contains "B4 T1 subagent emits no sentinel" "<<WORKFLOW_" "$s1"
    assert_not_contains "B4 T2 subagent emits no sentinel" "<<WORKFLOW_" "$s2"

    # B5 — and it must still point at the two real exits, resolved to real paths.
    assert_contains "B5 T1 subagent names the plans dir"  "$plans_native"   "$s1"
    assert_contains "B5 T1 subagent names the scratchpad" "$scratch_native" "$s1"
    assert_contains "B5 T2 subagent names the plans dir"  "$plans_native"   "$s2"
    assert_contains "B5 T2 subagent names the scratchpad" "$scratch_native" "$s2"
    assert_contains "B5 T1 subagent says the route is closed" "Subagent context" "$s1"
    assert_contains "B5 T2 subagent says the route is closed" "Subagent context" "$s2"

    # B6 — verdict is NOT downgraded to advisory for subagents. Tier 3 downgrades
    # because an interactive worktree move is unreachable there; Tier 1/2 now have a
    # legal exit (Section A), so downgrading would open arbitrary pre-init repo writes.
    assert_eq "B6 T1 subagent verdict stays block" "block" \
        "$(gate_decision "$(run_gate "$(mk_edit_input Write "$SID_T1" "$REPO_FWD/src/blocked.js" agent-2108)" "$SCRATCH_A")")"
    assert_eq "B6 T2 subagent verdict stays block" "block" \
        "$(gate_decision "$(run_gate "$(mk_edit_input Write "$SID_T2" "$REPO_FWD/src/blocked.js" agent-2108)" "$SCRATCH_A")")"

    # B7 — structural parity between tiers (one shared builder, CPR-SSOT). Equality
    # ALONE is false-green: `grep -c` answers 0 when it finds nothing, so two messages
    # that never mention ALLOWED at all compare equal and the case passes while proving
    # nothing. Each count is therefore first asserted PRESENT (>=1) and only then
    # compared, so "found nothing" and "found the same thing" are different verdicts.
    # B3 already proved both the plans dir AND the scratchpad are individually named
    # (2 distinct ALLOWED targets), so >=1 is not the real floor here - >=2 is. A count
    # of exactly 1 would mean one of B3's two targets collapsed into the other line.
    local a1 a2 sshape1 sshape2
    a1="$(printf '%s' "$r1" | grep -c 'ALLOWED')"
    a2="$(printf '%s' "$r2" | grep -c 'ALLOWED')"
    assert_ge "B7 Tier 1 ALLOWED-targets block lists both targets" 2 "$a1"
    assert_ge "B7 Tier 2 ALLOWED-targets block lists both targets" 2 "$a2"
    assert_eq "B7 both tiers carry the ALLOWED-targets block equally" "$a1" "$a2"
    assert_contains "B7 Tier 1 keeps the reset-state label" "To reset workflow state" "$r1"
    assert_contains "B7 Tier 2 keeps the reset-state label" "To reset workflow state" "$r2"
    sshape1="$(printf '%s' "$s1" | grep -c 'ALLOWED')"
    sshape2="$(printf '%s' "$s2" | grep -c 'ALLOWED')"
    assert_ge "B7 T1 subagent ALLOWED-targets block lists both targets" 2 "$sshape1"
    assert_ge "B7 T2 subagent ALLOWED-targets block lists both targets" 2 "$sshape2"
    assert_eq "B7 both subagent messages carry the ALLOWED-targets block" "$sshape1" "$sshape2"

    run_B8_scratchpad_fallback_message

    # SKIPPED: confirming a real subagent READS the advisory and stops probing for a
    # write route (the behavioural claim the message exists to produce).
    # Because: that is a model-behaviour observation, not a hook-output assertion.
    # L3 gap: whether the reason string reaches the subagent's context at all.
}

# _b_present <count> -> present | absent  (0 and "not a number" are both absent)
_b_present() { case "$1" in ''|*[!0-9]*) printf 'absent' ;; 0) printf 'absent' ;; *) printf 'present' ;; esac; }

# B8 — the CONFIG-DEPENDENT half of the message contract. Every case above pins a
# valid SCRATCHPAD; here it is (i) unset and (ii) set to a directory OUTSIDE the claude
# base, which getScratchpadAllowRootNorm() rejects. In both states the allow root falls
# back to the claude base, so the message must advertise THAT root — never an empty
# fragment, an `undefined`, or the rejected value, which would send the agent to write
# somewhere the allowlist will not honour (a worse outcome than #2108 itself). Full
# tier x context x fallback-state matrix (8 cells, table-driven) — a partial diagonal
# slice previously let a tier/context-specific regression in the fallback path hide
# behind a cell that was never exercised for that combination.
run_B8_scratchpad_fallback_message() {
    local bogus base_n plans_n
    bogus="$TMPBASE_SH/not-a-scratchpad"
    mkdir -p "$bogus" 2>/dev/null || true
    base_n="$(_b_norm "$CLAUDE_BASE")"
    plans_n="$(_b_norm "$(node -e "process.stdout.write(require('path').resolve(process.env.WORKFLOW_PLANS_DIR))" 2>/dev/null)")"

    local label sid agent state r sv
    while IFS='|' read -r label sid agent state; do
        [ -z "$label" ] && continue
        case "$state" in
            unset) sv="-" ;;
            invalid) sv="$(node_path "$bogus")" ;;
        esac
        r="$(_b_reason "$sid" "$agent" "$sv")"

        if [ -z "$r" ]; then
            fail "B8-0 $label produced no reason - this cell would be vacuous"
            continue
        fi
        pass "B8-0 $label still produces a reason string"

        assert_not_contains "B8-1 $label: no undefined path fragment leaks into the message" "undefined" "$r"
        assert_not_contains "B8-1 $label: no unexpanded env reference leaks into the message" "\$SCRATCHPAD" "$r"
        assert_contains "B8-2 $label: message names the fallback allow root" "$base_n" "$(_b_norm "$r")"

        if [ "$state" = "invalid" ]; then
            # B8-3 — must NOT advertise the rejected value itself.
            assert_not_contains "B8-3 $label: the rejected SCRATCHPAD value is never advertised" \
                "$(_b_norm "$bogus")" "$(_b_norm "$r")"
        fi

        # B8-4 — the identity branch survives the fallback in every cell.
        if [ -n "$agent" ]; then
            assert_not_contains "B8-4 $label: subagent fallback message still emits no sentinel" "<<WORKFLOW_" "$r"
        else
            assert_contains "B8-4 $label: main fallback message still names the plans dir" "$plans_n" "$(_b_norm "$r")"
        fi
    done <<EOF
T1-main-unset|$SID_T1||unset
T2-main-unset|$SID_T2||unset
T1-subagent-unset|$SID_T1|agent-2108|unset
T2-subagent-unset|$SID_T2|agent-2108|unset
T1-main-invalid|$SID_T1||invalid
T2-main-invalid|$SID_T2||invalid
T1-subagent-invalid|$SID_T1|agent-2108|invalid
T2-subagent-invalid|$SID_T2|agent-2108|invalid
EOF
}

# _b9_input <sid> <raw agent_id JSON literal, or "-" for the field being absent>
_b9_input() {
    local sid="$1" raw="$2" fld=""
    [ "$raw" = "-" ] || fld="$(printf ',"agent_id":%s' "$raw")"
    printf '{"session_id":"%s"%s,"tool_name":"Write","tool_input":{"file_path":"%s/src/blocked.js","content":"x"}}' \
        "$sid" "$fld" "$REPO_FWD"
}

# Section B9 — the IDENTITY input edges (review C6). Section B drives two shapes only:
# `agent_id` absent, and a well-formed non-empty string. hooks/lib/subagent-detect.js
# takes a JSON value of any type, and the whole message split hangs off its answer —
# so a malformed identity that fell to the SUBAGENT branch would strip a MAIN caller's
# sentinel routes, which is the #2108 defect pointed the other way round.
run_B9_agent_id_edges() {
    local label raw branch tier sid r

    while IFS='|' read -r label tier raw branch; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; tier="${tier//[[:space:]]/}"
        raw="${raw//[[:space:]]/}"; branch="${branch//[[:space:]]/}"
        case "$tier" in T1) sid="$SID_T1" ;; *) sid="$SID_T2" ;; esac
        r="$(gate_reason "$(run_gate "$(_b9_input "$sid" "$raw")" "$SCRATCH_A")")"
        if [ -z "$r" ]; then
            fail "B9-0 $label [$tier] produced no reason - this cell would be vacuous"
            continue
        fi
        pass "B9-0 $label [$tier] still produces a reason string"
        if [ "$branch" = "main" ]; then
            assert_contains "B9 $label [$tier] keeps main-context sentinel guidance" "<<WORKFLOW_" "$r"
        else
            assert_not_contains "B9 $label [$tier] takes the subagent branch" "<<WORKFLOW_" "$r"
            assert_contains "B9 $label [$tier] still names the subagent advisory" "Subagent context" "$r"
        fi
    done <<'TABLE'
# label                | tier | agent_id JSON  | branch
B9-absent               | T1 | -              | main
B9-absent               | T2 | -              | main
B9-empty-string         | T1 | ""             | main
B9-empty-string         | T2 | ""             | main
B9-null                 | T1 | null           | main
B9-null                 | T2 | null           | main
B9-number               | T1 | 12345          | main
B9-number               | T2 | 12345          | main
B9-boolean              | T1 | true           | main
B9-boolean              | T2 | true           | main
B9-object               | T1 | {"id":"a"}     | main
B9-array                | T1 | ["a"]          | main
B9-valid-string         | T1 | "agent-2108"   | subagent
B9-valid-string         | T2 | "agent-2108"   | subagent
TABLE

    # B9-6 — the predicate itself, all shapes in one call, so the message-level rows
    # above cannot pass for a reason unrelated to identity classification. Whitespace
    # is deliberately the LAST column: it is a non-empty string, so the current
    # contract (subagent-detect.js:11) counts it as a subagent identity.
    local pred
    pred="$(run_probe -e "const {isSubagentCall}=require(process.argv[1]);process.stdout.write([{},{agent_id:''},{agent_id:null},{agent_id:12345},{agent_id:true},{agent_id:{}},{agent_id:'agent-2108'},{agent_id:'   '}].map(i=>String(isSubagentCall(i))).join(','))" "$AGENTS_NODE/hooks/lib/subagent-detect.js")"
    assert_eq "B9-6 isSubagentCall over absent/empty/null/number/bool/object/valid/whitespace" \
        "false,false,false,false,false,false,true,true" "$pred"

    # SKIPPED: tightening the contract so a whitespace-only agent_id reads as MAIN.
    # Because: subagent-detect.js is not in #2108's change set, and narrowing it would
    # change which callers lose their sentinel routes — a separate decision.
    # L3 gap: whether Claude Code can ever emit a blank-but-present agent_id at all.
}
