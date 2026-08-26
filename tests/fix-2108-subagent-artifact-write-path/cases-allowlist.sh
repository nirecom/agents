#!/usr/bin/env bash
# Tests: hooks/workflow-gate/early-gate.js, hooks/workflow-gate/early-gate-allowlist.js, hooks/lib/claude-scratchpad-base.js
# Tags: workflow-gate, early-gate, scratchpad, plans-dir, allowlist, classifier, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section A — the early gate's write allowlist (Scope 1+2 of #2108). The allowlist
# sits BEFORE both tiers, so Tier 1 (workflow_init pending) and Tier 2 (clarify_intent
# pending) must reach the SAME verdict for the same target; asserting one tier only
# would leave its symmetric sibling unguarded (CPR-ORTH). Both verdicts are covered
# (Pattern 4): the allow side (a subagent finally has a legal exit) and the block side
# (the gate did not become a hole). Section D adds the F1 poisoned-TEMP counterweight.

# _a_target <key> -> absolute forward-slash path for that symbolic target
_a_target() {
    case "$1" in
        own-scratchpad)   printf '%s/issue-2108-survey.md' "$SCRATCH_A_FWD" ;;
        plans)            printf '%s/2108-intent.md' "$PLANS_FWD" ;;
        other-scratchpad) printf '%s/steal.md' "$SCRATCH_B_FWD" ;;
        claude-base)      printf '%s/loose.md' "$CLAUDE_BASE_FWD" ;;
        slash-tmp)        printf '/tmp/evil.md' ;;
        in-repo)          printf '%s/src/evil.js' "$REPO_FWD" ;;
        unset-scratchpad) printf '%s/fallback.md' "$SCRATCH_C_FWD" ;;
        *)                printf '/dev/null/unknown' ;;
    esac
}

# _a_scratchpad <key> -> SCRATCHPAD env value ("-" means explicitly unset)
_a_scratchpad() {
    case "$1" in
        unset-scratchpad) printf '%s' "-" ;;
        *)                printf '%s' "$SCRATCH_A" ;;
    esac
}

# The `caller` column carries the SUBAGENT IDENTITY of the tool call. `main` means
# no agent_id field at all (main conversation); anything else is emitted as
# `"agent_id":"<value>"`, which is exactly what hooks/lib/subagent-detect.js reads
# (isSubagentCall: a non-empty string agent_id). #2108 is a SUBAGENT report — the
# agent that had no legal write target — so the allowlist must be proven on the
# subagent-shaped payload and not only on the main-conversation one. The verdict is
# identity-INDEPENDENT by design (only the block WORDING branches on identity,
# Section B), which is why each subagent row mirrors a main row target-for-target.
run_A_allowlist() {
    local name tier sid tool tkey caller want target sp agent out got

    while IFS='|' read -r name tier tool tkey caller want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; tier="${tier//[[:space:]]/}"
        tool="${tool//[[:space:]]/}"; tkey="${tkey//[[:space:]]/}"
        caller="${caller//[[:space:]]/}"; want="${want//[[:space:]]/}"
        case "$tier" in
            T1) sid="$SID_T1" ;;
            *)  sid="$SID_T2" ;;
        esac
        agent=""
        [ "$caller" = "main" ] || agent="$caller"
        target="$(_a_target "$tkey")"
        sp="$(_a_scratchpad "$tkey")"
        out="$(run_gate "$(mk_edit_input "$tool" "$sid" "$target" "$agent")" "$sp")"
        got="$(gate_decision "$out")"
        assert_eq "A $name [$tier $tool $tkey $caller]" "$want" "$got"
    done <<'TABLE'
# name             | tier | tool      | target           | caller      | want
# --- ALLOW: the legal exits a blocked subagent must be able to take ----------
A1-scratch-write   | T1 | Write     | own-scratchpad   | main        | approve
A1-scratch-edit    | T1 | Edit      | own-scratchpad   | main        | approve
A1-scratch-multi   | T1 | MultiEdit | own-scratchpad   | main        | approve
A2-scratch-write   | T2 | Write     | own-scratchpad   | main        | approve
A2-scratch-edit    | T2 | Edit      | own-scratchpad   | main        | approve
A2-scratch-multi   | T2 | MultiEdit | own-scratchpad   | main        | approve
A3-plans-write     | T1 | Write     | plans            | main        | approve
A3-plans-edit      | T1 | Edit      | plans            | main        | approve
A3-plans-multi     | T1 | MultiEdit | plans            | main        | approve
A4-plans-write     | T2 | Write     | plans            | main        | approve
A4-plans-edit      | T2 | Edit      | plans            | main        | approve
A4-plans-multi     | T2 | MultiEdit | plans            | main        | approve
A5-nosp-write      | T1 | Write     | unset-scratchpad | main        | approve
A5-nosp-edit       | T1 | Edit      | unset-scratchpad | main        | approve
A6-nosp-write      | T2 | Write     | unset-scratchpad | main        | approve
A6-nosp-edit       | T2 | Edit      | unset-scratchpad | main        | approve
# --- ALLOW, SUBAGENT CALLER: the actual #2108 reporter. Same two destinations,
# --- both tiers, agent_id present. Without these rows the issue's own path is
# --- never exercised and the whole allow side proves only the main-conversation
# --- case (review C1).
A1s-sub-scratch-wr | T1 | Write     | own-scratchpad   | agent-2108  | approve
A1s-sub-scratch-ed | T1 | Edit      | own-scratchpad   | agent-2108  | approve
A1s-sub-scratch-mu | T1 | MultiEdit | own-scratchpad   | agent-2108  | approve
A2s-sub-scratch-wr | T2 | Write     | own-scratchpad   | agent-2108  | approve
A2s-sub-scratch-ed | T2 | Edit      | own-scratchpad   | agent-2108  | approve
A3s-sub-plans-wr   | T1 | Write     | plans            | agent-2108  | approve
A3s-sub-plans-mu   | T1 | MultiEdit | plans            | agent-2108  | approve
A4s-sub-plans-wr   | T2 | Write     | plans            | agent-2108  | approve
A4s-sub-plans-ed   | T2 | Edit      | plans            | agent-2108  | approve
A5s-sub-nosp-wr    | T1 | Write     | unset-scratchpad | agent-2108  | approve
A6s-sub-nosp-wr    | T2 | Write     | unset-scratchpad | agent-2108  | approve
# --- BLOCK: the gate must not have become a hole (CPR-ORTH counterweight) ----
A7-cross-session   | T1 | Write     | other-scratchpad | main        | block
A7-cross-edit      | T1 | Edit      | other-scratchpad | main        | block
A8-cross-session   | T2 | Write     | other-scratchpad | main        | block
A8-cross-multi     | T2 | MultiEdit | other-scratchpad | main        | block
A9-claude-base     | T1 | Write     | claude-base      | main        | block
A10-claude-base    | T2 | Write     | claude-base      | main        | block
A11-slash-tmp      | T1 | Write     | slash-tmp        | main        | block
A12-slash-tmp      | T2 | Write     | slash-tmp        | main        | block
A13-in-repo        | T1 | Write     | in-repo          | main        | block
A13-in-repo-edit   | T1 | Edit      | in-repo          | main        | block
A14-in-repo        | T2 | Write     | in-repo          | main        | block
A14-in-repo-multi  | T2 | MultiEdit | in-repo          | main        | block
# --- BLOCK, SUBAGENT CALLER: a subagent identity widens NOTHING. Paired with the
# --- allow rows above so "the subagent path works" cannot be satisfied by a hook
# --- that simply approves every subagent write (Pattern 4, both directions).
A7s-sub-cross      | T1 | Write     | other-scratchpad | agent-2108  | block
A8s-sub-cross      | T2 | Write     | other-scratchpad | agent-2108  | block
A9s-sub-base       | T1 | Write     | claude-base      | agent-2108  | block
A13s-sub-in-repo   | T1 | Write     | in-repo          | agent-2108  | block
A14s-sub-in-repo   | T2 | Write     | in-repo          | agent-2108  | block
TABLE

    # A15 — Pattern 1 (negative assertion): a blocked Write must leave the target
    # ABSENT, not merely report block. If a future refactor made the gate itself
    # touch the target path, this is what catches it.
    local victim="$FIX_REPO/src-negative.js"
    rm -f "$victim" 2>/dev/null || true
    out="$(run_gate "$(mk_edit_input Write "$SID_T1" "$REPO_FWD/src-negative.js")" "$SCRATCH_A")"
    assert_eq "A15 in-repo write is blocked" "block" "$(gate_decision "$out")"
    if [ -e "$victim" ]; then fail "A15 blocked target was created at $victim"
    else pass "A15 blocked target remains absent (Pattern 1 negative assertion)"; fi

    # A16 — CPR-ORTH control: once both tiers are clear the gate must go dormant.
    # Without this the allowlist could look "correct" by blocking everything.
    write_state "sid2108done" complete complete
    out="$(run_gate "$(mk_edit_input Write "sid2108done" "$REPO_FWD/src/ok.js")" "$SCRATCH_A")"
    assert_eq "A16 both tiers clear -> in-repo write approved (gate dormant)" "approve" "$(gate_decision "$out")"

    # A17 — tool scoping stays exactly as today: editFiles / NotebookEdit are early-gate
    # tools but NOT allowlist tools (plan R10), so a scratchpad target still blocks.
    out="$(run_gate "$(printf '{"session_id":"%s","tool_name":"editFiles","tool_input":{"file_path":"%s/x.md","old_string":"a","new_string":"b"}}' "$SID_T1" "$SCRATCH_A_FWD")" "$SCRATCH_A")"
    assert_eq "A17 editFiles into scratchpad still blocks (R10 accepted narrowness)" "block" "$(gate_decision "$out")"

    # SKIPPED: a real subagent invoking Write into its own scratchpad through the live
    # PreToolUse chain and observing the artifact land on disk.
    # Because: requires RUN_TL3=on + a real claude -p session; not reproducible at TL2.
    # L3 gap: whether settings.json routes a subagent's Write to workflow-gate.js at
    # all, and whether the harness exports SCRATCHPAD inside a subagent process.
}

# _a18_gate <stdin-json> <SCRATCHPAD value or "-"> -> approve | block | crash | ...
_a18_gate() { gate_decision "$(run_gate "$1" "$2")"; }

# _a18_input <sid> <tool_input-object-json> -> PreToolUse stdin for Write
_a18_input() { printf '{"session_id":"%s","tool_name":"Write","tool_input":%s}' "$1" "$2"; }

# Section A18 — the INPUT-SHAPE edges of the same allowlist (review C5). Section A
# drives one payload spelling (`file_path`, a valid SCRATCHPAD, a real string target).
# early-gate.js:52 also reads `path`, and hooks/lib/claude-scratchpad-base.js has a
# documented fallback when SCRATCHPAD is unusable — neither had a case, so a regression
# in either would be invisible. Every row is asserted in BOTH directions (Pattern 4).
run_A18_input_edges() {
    local label tier sid shape want sp bogus target out

    bogus="$TMPBASE_SH/a18-not-a-scratchpad"
    mkdir -p "$bogus" 2>/dev/null || true

    while IFS='|' read -r label tier shape want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; tier="${tier//[[:space:]]/}"
        shape="${shape//[[:space:]]/}"; want="${want//[[:space:]]/}"
        case "$tier" in T1) sid="$SID_T1" ;; *) sid="$SID_T2" ;; esac
        sp="$SCRATCH_A"
        case "$shape" in
            # `path` alias instead of `file_path` — same two destinations as Section A.
            path-scratch)  target="$(printf '{"path":"%s/alias.md","content":"x"}' "$SCRATCH_A_FWD")" ;;
            path-plans)    target="$(printf '{"path":"%s/alias.md","content":"x"}' "$PLANS_FWD")" ;;
            path-repo)     target="$(printf '{"path":"%s/src/alias.js","content":"x"}' "$REPO_FWD")" ;;
            path-tmp)      target='{"path":"/tmp/alias-evil.md","content":"x"}' ;;
            # SCRATCHPAD set to a directory OUTSIDE the claude base: the env value is
            # rejected and the allow root falls back to the claude base itself.
            bad-sp-under)  target="$(printf '{"file_path":"%s/fallback.md","content":"x"}' "$SCRATCH_A_FWD")"
                           sp="$(node_path "$bogus")" ;;
            bad-sp-root)   target="$(printf '{"file_path":"%s","content":"x"}' "$CLAUDE_BASE_FWD")"
                           sp="$(node_path "$bogus")" ;;
            bad-sp-child)  target="$(printf '{"file_path":"%s/loose.md","content":"x"}' "$CLAUDE_BASE_FWD")"
                           sp="$(node_path "$bogus")" ;;
            bad-sp-inside) target="$(printf '{"file_path":"%s/steal.md","content":"x"}' "${bogus//\\//}")"
                           sp="$(node_path "$bogus")" ;;
            # Empty / null / non-string / absent targets: nothing is named, so nothing
            # can be allowed. The gate must fall to its block, never to a fall-through.
            empty-target)  target='{"file_path":"","content":"x"}' ;;
            null-target)   target='{"file_path":null,"content":"x"}' ;;
            number-target) target='{"file_path":12345,"content":"x"}' ;;
            array-target)  target="$(printf '{"file_path":["%s/x.md"],"content":"x"}' "$SCRATCH_A_FWD")" ;;
            absent-target) target='{"content":"x"}' ;;
            *)             target='{"file_path":"/dev/null/unknown","content":"x"}' ;;
        esac
        assert_eq "A18 $label [$tier $shape]" "$want" "$(_a18_gate "$(_a18_input "$sid" "$target")" "$sp")"
    done <<'TABLE'
# label                   | tier | shape         | want
A18-path-alias-scratch    | T1 | path-scratch  | approve
A18-path-alias-scratch    | T2 | path-scratch  | approve
A18-path-alias-plans      | T1 | path-plans    | approve
A18-path-alias-plans      | T2 | path-plans    | approve
A18-path-alias-in-repo    | T1 | path-repo     | block
A18-path-alias-in-repo    | T2 | path-repo     | block
A18-path-alias-slash-tmp  | T1 | path-tmp      | block
A18-path-alias-slash-tmp  | T2 | path-tmp      | block
A18-bad-sp-falls-back     | T1 | bad-sp-under  | approve
A18-bad-sp-falls-back     | T2 | bad-sp-under  | approve
A18-bad-sp-root-itself    | T1 | bad-sp-root   | block
A18-bad-sp-root-itself    | T2 | bad-sp-root   | block
A18-bad-sp-base-child     | T1 | bad-sp-child  | approve
A18-bad-sp-base-child     | T2 | bad-sp-child  | approve
A18-bad-sp-value-unusable | T1 | bad-sp-inside | block
A18-bad-sp-value-unusable | T2 | bad-sp-inside | block
A18-empty-target          | T1 | empty-target  | block
A18-empty-target          | T2 | empty-target  | block
A18-null-target           | T1 | null-target   | block
A18-null-target           | T2 | null-target   | block
A18-number-target         | T1 | number-target | block
A18-number-target         | T2 | number-target | block
A18-array-target          | T1 | array-target  | block
A18-array-target          | T2 | array-target  | block
A18-absent-target         | T1 | absent-target | block
A18-absent-target         | T2 | absent-target | block
TABLE

    # A19 — the injected repository detector THROWS. The scratchpad allow's second
    # clause (F1) depends on it, so an exception must resolve to "not allowed", never
    # to "clause skipped". Asserted at unit level because a thrown detector cannot be
    # induced through the hook's own stdin, and paired with the non-throwing control so
    # a predicate that always returns false could not satisfy it (Pattern 4).
    local pred
    pred="$(
        export SCRATCHPAD="$SCRATCH_A"
        run_probe -e "const m=require(process.argv[1]);const t=process.argv[2];const boom=()=>{throw new Error('detector down')};process.stdout.write([m.isAllowedScratchpadTarget(t,boom),m.isAllowedScratchpadTarget(t,()=>null)].join(','))" \
            "$AGENTS_NODE/hooks/lib/claude-scratchpad-base.js" "$SCRATCH_A_FWD/probe.md" 2>/dev/null
    )"
    assert_eq "A19 a throwing repo detector fails CLOSED (throw=false, control=true)" "false,true" "$pred"

    # A20 — Pattern 1 negative assertion for the fallback-root block: the rejected
    # SCRATCHPAD directory must be left untouched by the blocked write.
    out="$bogus/steal.md"
    if [ -e "$out" ]; then fail "A20 blocked target was created at $out"
    else pass "A20 blocked target under the rejected SCRATCHPAD remains absent"; fi

    # SKIPPED: a SCRATCHPAD value that is a valid path but does not exist on disk.
    # Because: getScratchpadAllowRootNorm is lexical by contract (it never stats), so
    # the case would assert the absence of a behaviour rather than a behaviour.
    # L3 gap: a real harness that exports SCRATCHPAD before creating the directory.
}
