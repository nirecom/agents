#!/bin/bash
# Tests: skills/_shared/judge-task-complexity.md
# Tags: skill, bin, static, scope:common
# Fragment of tests/skills/feature-write-code-skill-static.sh, sourced after _lib.sh (not
# standalone): the complexity-judge dispatch chain and the WCD-0 / WCD-2 / WCD-3 gates.

# ---------------------------------------------------------------------------
# m. Control-flow ordering: CONFIRM_CODE < complexity-judge < Agent tool
# ---------------------------------------------------------------------------
echo "=== m. Control-flow ordering in SKILL.md ==="
if require_file "$WRITE_CODE_SKILL"; then
    line_confirm=$(grep -n "CONFIRM_CODE" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_judge=$(grep -n "complexity-judge" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_agent=$(grep -n "Agent" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)

    if [ -z "$line_confirm" ] || [ -z "$line_judge" ] || [ -z "$line_agent" ]; then
        fail "control-flow ordering: could not find all three anchors (CONFIRM_CODE=$line_confirm, complexity-judge=$line_judge, Agent=$line_agent)"
    else
        if [ "$line_confirm" -lt "$line_judge" ] && [ "$line_judge" -lt "$line_agent" ]; then
            pass "control-flow ordering: CONFIRM_CODE (L$line_confirm) < complexity-judge (L$line_judge) < Agent (L$line_agent)"
        else
            fail "control-flow ordering wrong: CONFIRM_CODE=L$line_confirm, complexity-judge=L$line_judge, Agent=L$line_agent (expected ascending)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# n. SKILL.md contains "Model selected:" AND references complexity-judge dispatch
# ---------------------------------------------------------------------------
echo "=== n. SKILL.md contains 'Model selected:' and complexity-judge dispatch ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "Model selected:" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'Model selected:'"
    else
        fail "SKILL.md missing 'Model selected:'"
    fi
    # #2460 moved the dispatch into the shared procedure: pin each link of
    # SKILL.md -> shared procedure -> complexity-judge agent -> rubric.
    if has_fixed 'follow `skills/_shared/jev-two-stage-judge.md` with point=`complexity-judge`' "$WRITE_CODE_SKILL"; then
        pass "SKILL.md routes the complexity-judge point through skills/_shared/jev-two-stage-judge.md"
    else
        fail "SKILL.md does not route point=complexity-judge through skills/_shared/jev-two-stage-judge.md"
    fi
    if require_file "$JEV_JUDGE_PROC"; then
        if has_fixed 'Dispatch `subagent_type: <SUBAGENT>`' "$JEV_JUDGE_PROC"; then
            pass "jev-two-stage-judge.md dispatches 'subagent_type: <SUBAGENT>'"
        else
            fail "jev-two-stage-judge.md missing the 'subagent_type: <SUBAGENT>' dispatch"
        fi
    fi
    if require_file "$COMPLEXITY_JUDGE_AGENT"; then
        if has '^name: complexity-judge$' "$COMPLEXITY_JUDGE_AGENT" \
            && has_fixed 'skills/_shared/judge-task-complexity.md' "$COMPLEXITY_JUDGE_AGENT"; then
            pass "agents/complexity-judge.md is the dispatched agent and reads the rubric"
        else
            fail "agents/complexity-judge.md is not named complexity-judge or does not read skills/_shared/judge-task-complexity.md"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# o. SKILL.md does NOT contain "skip silently"; DOES contain "check skipped"
# ---------------------------------------------------------------------------
echo "=== o. SKILL.md: no 'skip silently', has 'check skipped' ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "skip silently" "$WRITE_CODE_SKILL"; then
        fail "SKILL.md must NOT contain 'skip silently'"
    else
        pass "SKILL.md correctly omits 'skip silently'"
    fi
    if has_fixed "check skipped" "$WRITE_CODE_SKILL"; then
        pass "SKILL.md contains 'check skipped'"
    else
        fail "SKILL.md missing 'check skipped'"
    fi
fi

# ---------------------------------------------------------------------------
# p. SSOT XOR: module-system guidance tokens must not appear in both nodejs.md and SKILL.md
# ---------------------------------------------------------------------------
echo "=== p. SSOT XOR: module-system guidance tokens ==="
if require_file "$NODEJS_RULES" && require_file "$WRITE_CODE_SKILL"; then
    for token in "module system" "CommonJS"; do
        if grep -F -- "$token" "$NODEJS_RULES" >/dev/null 2>&1; then
            # Token is canonical in nodejs.md — must NOT appear in SKILL.md
            if grep -F -- "$token" "$WRITE_CODE_SKILL" >/dev/null 2>&1; then
                fail "SSOT violation: '$token' is in nodejs.md (canonical) but also in SKILL.md (must not duplicate)"
            else
                pass "SSOT XOR ok: '$token' in nodejs.md, absent from SKILL.md"
            fi
        else
            pass "SSOT XOR skip: '$token' not in nodejs.md — no constraint on SKILL.md"
        fi
    done
fi

# ---------------------------------------------------------------------------
# q. Step 6 CONFIRM_CODE post-action gate
# ---------------------------------------------------------------------------
echo "=== q. Step 6 CONFIRM_CODE post-action gate ==="
if require_file "$WRITE_CODE_SKILL"; then
    hit=$(awk '/Present the final edited file list/{a=NR} a && NR>=a-8 && NR<=a+8 && /CONFIRM_CODE/{print NR; exit}' "$WRITE_CODE_SKILL")
    if [ -n "$hit" ]; then
        pass "Step 6 CONFIRM_CODE gate adjacent to 'Present the final edited file list' (line $hit)"
    else
        fail "Step 6 CONFIRM_CODE gate missing near 'Present the final edited file list'"
    fi
fi

# ---------------------------------------------------------------------------
# WCD-READ-1: SKILL.md invokes read-session-facts (#2102 bundled reader)
# ---------------------------------------------------------------------------
echo "=== WCD-READ-1: SKILL.md invokes read-session-facts ==="
if require_file "$WRITE_CODE_SKILL"; then
    if has_fixed "read-session-facts" "$WRITE_CODE_SKILL"; then
        pass "WCD-READ-1. SKILL.md contains 'read-session-facts'"
    else
        fail "WCD-READ-1. SKILL.md missing 'read-session-facts'"
    fi
fi

# ---------------------------------------------------------------------------
# WCD-READ-2: read-session-facts precedes complexity-judge dispatch (WCD-0's
# bundled read happens before the NONE-fallback dispatches the subagent)
# ---------------------------------------------------------------------------
echo "=== WCD-READ-2: read-session-facts precedes complexity-judge dispatch ==="
if require_file "$WRITE_CODE_SKILL"; then
    line_read=$(grep -n "read-session-facts" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_judge=$(grep -n "complexity-judge" "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$line_read" ] || [ -z "$line_judge" ]; then
        fail "WCD-READ-2. could not find both anchors (read-session-facts=$line_read, complexity-judge=$line_judge)"
    elif [ "$line_read" -lt "$line_judge" ]; then
        pass "WCD-READ-2. read-session-facts (L$line_read) precedes complexity-judge (L$line_judge)"
    else
        fail "WCD-READ-2. ordering wrong: read-session-facts=L$line_read, complexity-judge=L$line_judge (expected read first)"
    fi
fi

# ---------------------------------------------------------------------------
# r. WCD-2 GATE_CONFIRM_CODE verdict table: OFF proceeds, ON and ERROR both
#    ask — an ERROR verdict silently proceeding would be a fail-open gate.
# ---------------------------------------------------------------------------
echo "=== r. WCD-2 GATE_CONFIRM_CODE verdict table ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd2_section=$(sed -n '/^WCD-2\./,/^WCD-3\./p' "$WRITE_CODE_SKILL")
    if [ -z "$wcd2_section" ]; then
        fail "r. WCD-2 section not found in SKILL.md"
    else
        if printf '%s\n' "$wcd2_section" | grep -qF '`OFF`: proceed to WCD-3'; then
            pass "r. WCD-2: 'OFF' verdict proceeds without asking"
        else
            fail "r. WCD-2: 'OFF' verdict does not document proceeding to WCD-3"
        fi
        if printf '%s\n' "$wcd2_section" | grep -qF '`ON` or `ERROR`: present the planned edits via `AskUserQuestion`'; then
            pass "r. WCD-2: 'ON' and 'ERROR' verdicts both route to AskUserQuestion (no silent fail-open)"
        else
            fail "r. WCD-2: 'ON'/'ERROR' verdicts do not both route to AskUserQuestion — possible fail-open"
        fi
        # A copy-paste slip from write-tests/SKILL.md's near-identical WT-5 gate
        # (which branches on GATE_CONFIRM_TESTS) would still pass every check
        # above — pin the exact gate key WCD-2 branches on, and that its sibling
        # gate key never leaks into this section.
        if printf '%s\n' "$wcd2_section" | grep -qF 'branch on `GATE_CONFIRM_CODE`'; then
            pass "s. WCD-2: branches on the exact key 'GATE_CONFIRM_CODE'"
        else
            fail "s. WCD-2: does not branch on 'GATE_CONFIRM_CODE' verbatim"
        fi
        if printf '%s\n' "$wcd2_section" | grep -qF 'GATE_CONFIRM_TESTS'; then
            fail "s. WCD-2: leaks the sibling gate key 'GATE_CONFIRM_TESTS' (copy-paste from write-tests)"
        else
            pass "s. WCD-2: does not leak the sibling gate key 'GATE_CONFIRM_TESTS'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# t. WCD-3 judges its own stage, not the write-tests sibling's (a wrong-stage
#    copy-paste from write-tests/SKILL.md's WT-6 would still pass every prior
#    check in this file). #2460: WCD-3 re-judges every run, so it reuses no
#    stored evaluation key either.
# ---------------------------------------------------------------------------
echo "=== t. WCD-3 judges stage=write-code and reuses no stored evaluation ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd3_section=$(sed -n '/^WCD-3\./,/^WCD-3a\./p' "$WRITE_CODE_SKILL")
    if [ -z "$wcd3_section" ]; then
        fail "t. WCD-3 section not found in SKILL.md"
    else
        if printf '%s\n' "$wcd3_section" | grep -qF 'follow `skills/_shared/jev-two-stage-judge.md` with point=`complexity-judge` stage=`write-code`'; then
            pass "t. WCD-3 follows the shared procedure with point=complexity-judge stage=write-code"
        else
            fail "t. WCD-3 does not follow the shared procedure with point=complexity-judge stage=write-code"
        fi
        if printf '%s\n' "$wcd3_section" | grep -qF 'stage=`write-tests`'; then
            fail "t. WCD-3 leaks the sibling stage 'write-tests' (copy-paste from write-tests)"
        else
            pass "t. WCD-3 does not leak the sibling stage 'write-tests'"
        fi
        if printf '%s\n' "$wcd3_section" | grep -qF 'SIGNALS_CSV'; then
            pass "t. WCD-3 takes its signals from the shared procedure's 'SIGNALS_CSV'"
        else
            fail "t. WCD-3 does not name 'SIGNALS_CSV'"
        fi
        stored_keys=$(printf '%s\n' "$wcd3_section" | grep -oE 'COMPLEXITY_(LEVEL|MODEL)_write_code|COMPLEXITY_SIGNALS' | sort -u | tr '\n' ' ')
        if [ -z "$stored_keys" ]; then
            pass "t. WCD-3 reuses no stored evaluation key"
        else
            fail "t. WCD-3 still reuses a stored evaluation key: $stored_keys"
        fi
        if printf '%s\n' "$wcd3_section" | grep -qF 'COMPLEXITY_LEVEL_write_tests'; then
            fail "t. WCD-3 leaks the sibling key 'COMPLEXITY_LEVEL_write_tests' (copy-paste from write-tests)"
        else
            pass "t. WCD-3 does not leak the sibling key 'COMPLEXITY_LEVEL_write_tests'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# u. WCD-0 fail-closed contract on PLANS_DIR: halt (never construct a path)
#    on a non-zero exit or PLANS_DIR=NONE, and this halt is documented before
#    WCD-2/WCD-3 so it actually gates them rather than being dead prose.
# ---------------------------------------------------------------------------
echo "=== u. WCD-0 PLANS_DIR fail-closed contract precedes WCD-2/WCD-3 ==="
if require_file "$WRITE_CODE_SKILL"; then
    wcd0_section=$(sed -n '/^WCD-0\./,/^WCD-1\./p' "$WRITE_CODE_SKILL")
    if [ -z "$wcd0_section" ]; then
        fail "u. WCD-0 section not found in SKILL.md"
    else
        if printf '%s\n' "$wcd0_section" | grep -qF 'PLANS_DIR=NONE'; then
            pass "u. WCD-0 names the 'PLANS_DIR=NONE' halt condition"
        else
            fail "u. WCD-0 does not name the 'PLANS_DIR=NONE' halt condition"
        fi
        if printf '%s\n' "$wcd0_section" | grep -qF 'never construct a path like `NONE/<session-id>-...`'; then
            pass "u. WCD-0 forbids constructing a path from the unresolved PLANS_DIR"
        else
            fail "u. WCD-0 does not forbid constructing a path from the unresolved PLANS_DIR"
        fi
    fi
    line_halt=$(grep -n 'PLANS_DIR=NONE' "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_wcd2=$(grep -n '^WCD-2\.' "$WRITE_CODE_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$line_halt" ] || [ -z "$line_wcd2" ]; then
        fail "u. could not find both anchors (PLANS_DIR=NONE=$line_halt, WCD-2=$line_wcd2)"
    elif [ "$line_halt" -lt "$line_wcd2" ]; then
        pass "u. PLANS_DIR=NONE halt (L$line_halt) precedes WCD-2 (L$line_wcd2)"
    else
        fail "u. ordering wrong: PLANS_DIR=NONE halt=L$line_halt, WCD-2=L$line_wcd2 (expected halt documented first)"
    fi
fi
echo "=== v. WCD-2/WCD-0 gate has real runtime coverage, not just static text ==="
# This file is static-only by design (its own name says so) — it cannot afford
# the session/config fixture that a real GATE_CONFIRM_CODE ON/OFF/ERROR run
# needs (tests/bin/feature-2102-session-facts/values.sh already pays that cost).
# What it CAN and must check: that the CLI WCD-0 tells the orchestrator to run
# is the exact CLI whose runtime output values.sh pins — so a rename here can't
# silently orphan that coverage and leave WCD-2's branch untested end-to-end.
READ_SESSION_FACTS_BIN="$REPO_ROOT/bin/workflow/read-session-facts"
RUNTIME_GATE_TEST="$REPO_ROOT/tests/bin/feature-2102-session-facts/values.sh"
if require_file "$WRITE_CODE_SKILL" && require_file "$RUNTIME_GATE_TEST"; then
    if has_fixed "bin/workflow/read-session-facts" "$WRITE_CODE_SKILL"; then
        pass "v. WCD-0 names bin/workflow/read-session-facts as the runtime source of GATE_CONFIRM_CODE"
    else
        fail "v. WCD-0 does not name bin/workflow/read-session-facts"
    fi
    if [ -f "$READ_SESSION_FACTS_BIN" ]; then
        pass "v. the CLI WCD-0 names actually exists at bin/workflow/read-session-facts"
    else
        fail "v. bin/workflow/read-session-facts does not exist — WCD-0 documents a dead command"
    fi
    if has_fixed "GATE_CONFIRM_CODE" "$RUNTIME_GATE_TEST"; then
        pass "v. tests/bin/feature-2102-session-facts/values.sh pins GATE_CONFIRM_CODE's runtime ON/OFF/ERROR values — the CLI's behavior is exercised, not just this file's prose"
    else
        fail "v. tests/bin/feature-2102-session-facts/values.sh no longer pins GATE_CONFIRM_CODE — the runtime side of WCD-2's gate has no coverage anywhere"
    fi
fi
