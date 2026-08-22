#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Blocks C12 (issue-create SKILL.md Scope) and C14 (marker-bypass contract).
#
# WHY C12: #2053's documented path was "run gh issue create --repo OWNER/REPO
# directly" — the exact command this guard now stops — so the doc change is
# part of the fix, not decoration. WHY C14: marker-bypass-contract.md is the
# SSOT for which hooks a .workflow-off marker silences; this pins that the
# contract SAYS so, while L-1 in cases-r-k-l.sh is its runtime twin.

run_block_c12_c14() {
    echo ""
    echo "=== C12: skills/issue-create/SKILL.md no longer routes around the guard ==="

    local SKILL="$AGENTS_DIR/skills/issue-create/SKILL.md"
    if [ ! -f "$SKILL" ]; then
        fail "GAP-C12-0 skills/issue-create/SKILL.md exists" "not found at $SKILL"
        return
    fi

    # The Scope section only. A --repo mention elsewhere in the file (the
    # preflight line, for instance) is a different statement and must survive —
    # narrowing to Scope is what keeps this from becoming a whole-file grep.
    local scope
    scope="$(awk '/^## Scope/{f=1;next} /^## /{f=0} f' "$SKILL")"
    if [ -z "$scope" ]; then
        fail "GAP-C12-1 the Scope section is readable" "no '## Scope' section in SKILL.md"
        return
    fi
    if printf '%s' "$scope" | grep -q 'gh issue create --repo'; then
        fail "GAP-C12-1 Scope no longer sends cross-repo users straight to gh issue create --repo" \
             "the bare-command instruction is still there"
    else
        pass "GAP-C12-1 Scope no longer sends cross-repo users straight to gh issue create --repo"
    fi
    if printf '%s' "$scope" | grep -qi 'directly'; then
        fail "GAP-C12-2 Scope no longer says to run it directly" "'directly' still present in Scope"
    else
        pass "GAP-C12-2 Scope no longer says to run it directly"
    fi

    # Removing the sentence is only half the fix: the reader still needs to be
    # told what to do instead, or the doc has a hole where the route used to be.

    # Round-2 C12: the previous form matched a bare occurrence of "ownership",
    # "confirm" or "approval" anywhere in Scope. "No ownership check is needed"
    # satisfied that, and so would the word "confirm" in an unrelated sentence —
    # the assertion could not fail for the defect it was written to catch. What
    # the reader needs is an AFFIRMATIVE instruction, so that is what is asserted.
    local aff
    aff="$(printf '%s\n' "$scope" \
           | grep -Ei '(confirm|verif|prov)[a-z]*[^.]{0,80}(owner|ownership)' \
           | grep -Evi '(do not|does not|never|no need|not required|without|unless)')"
    if [ -n "$aff" ]; then
        pass "GAP-C12-3a Scope carries an affirmative 'confirm ownership' instruction"
    else
        fail "GAP-C12-3a Scope carries an affirmative 'confirm ownership' instruction" \
             "no un-negated line in Scope requires ownership to be confirmed"
    fi
    # The instruction has to be about THIS action, and ordered before it. A line
    # requiring ownership confirmation for something else, or after the issue is
    # already filed, documents a route that does not exist.
    if printf '%s' "$aff" | grep -Eqi '(cross-repo|another repo|other repos|OWNER/REPO|issue)' \
       && printf '%s' "$aff" | grep -Eqi '(before|first|prior to)'; then
        pass "GAP-C12-3b and it applies to cross-repo issue creation, BEFORE the issue is filed"
    else
        fail "GAP-C12-3b and it applies to cross-repo issue creation, BEFORE the issue is filed" \
             "the affirmative line does not tie ownership confirmation to filing a cross-repo issue first: ${aff:-<none>}"
    fi
    # And the rest of the file must keep working: --repo is still the right flag
    # for the preflight call, so a blanket deletion would break the skill.
    if grep -q -- '--repo OWNER/REPO' "$SKILL"; then
        pass "GAP-C12-4 the preflight --repo instruction elsewhere in the file survived"
    else
        fail "GAP-C12-4 preflight --repo instruction" \
             "--repo OWNER/REPO was removed from the whole file, not just from Scope"
    fi

    echo ""
    echo "=== C14: the guard is registered in the marker-bypass contract ==="

    local CONTRACT="$AGENTS_DIR/docs/architecture/claude-code/marker-bypass-contract.md"
    if [ ! -f "$CONTRACT" ]; then
        fail "GAP-C14-0 marker-bypass-contract.md exists" "not found at $CONTRACT"
        return
    fi
    local row
    row="$(grep -F 'hooks/confirm-forge-target-ownership.js' "$CONTRACT" | head -1)"
    if [ -z "$row" ]; then
        fail "GAP-C14-1 the guard has a row in the honoring-hooks table" \
             "no hooks/confirm-forge-target-ownership.js line in the contract"
        fail "GAP-C14-2 it honors neither .workflow-off nor .worktree-off" "row absent"
        fail "GAP-C14-3 the row is a PreToolUse row" "row absent"
        return
    fi
    pass "GAP-C14-1 the guard has a row in the honoring-hooks table"
    # Both marker columns must read No. A Yes in either column would contradict
    # L-1, which asserts at runtime that the marker does not silence the guard.
    local cols
    cols="$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); gsub(/ /,"",$5); print $4 "," $5}')"
    assert_eq "GAP-C14-2 it honors neither .workflow-off nor .worktree-off" "No,No" "$cols"
    if printf '%s' "$row" | grep -qF 'PreToolUse'; then
        pass "GAP-C14-3 the row records it as a PreToolUse hook"
    else
        fail "GAP-C14-3 the row records it as a PreToolUse hook" "layer column is not PreToolUse: $row"
    fi

    # Registration in settings.json is what makes the contract row true. The TL3
    # sibling exercises it live; this is the static half, and it is the assertion
    # that fails first if the hook is written but never wired.
    local SETTINGS="$AGENTS_DIR/settings.json"
    local reg
    reg="$(node -e '
        const s = require(process.argv[1]);
        const hit = (s.hooks.PreToolUse || []).filter(e =>
            (e.hooks || []).some(h => String(h.command).includes("confirm-forge-target-ownership")));
        process.stdout.write(hit.map(e => e.matcher).join(";"));
    ' "$SETTINGS" 2>/dev/null)"
    if [ -z "$reg" ]; then
        fail "GAP-C14-4 settings.json registers the guard on PreToolUse" \
             "no PreToolUse entry runs confirm-forge-target-ownership.js"
        fail "GAP-C14-5 its matcher covers all three shell tools" "not registered"
    else
        pass "GAP-C14-4 settings.json registers the guard on PreToolUse"
        local missing=""
        for t in Bash runInTerminal runCommands; do
            printf '%s' "$reg" | grep -qF "$t" || missing="$missing $t"
        done
        assert_eq "GAP-C14-5 its matcher covers all three shell tools" "" "$missing"
    fi

    echo ""
    echo "=== R2-C10: the registered timeout must outlast the guard's own budget ==="

    # WHY: a matcher that is present proves the guard is CALLED. It says nothing
    # about whether it is allowed to FINISH. The host kills a hook at the timeout
    # written beside it in settings.json; a hook killed mid-probe contributes no
    # decision, and the tool call proceeds as if no guard existed. That converts
    # every ask in this suite into a silent allow on a slow network — the exact
    # #2053 outcome, reached by a route no verdict assertion can see.

    # MAX_DECISION_BUDGET_S is the ceiling block G already enforces on the hook
    # itself (G-1b/G-2b/G-3b: a decision within 10s even when every probe hangs).
    # The registered timeout must be strictly greater, or the two numbers race.
    local MAX_DECISION_BUDGET_S=10
    local reg_timeout
    reg_timeout="$(node -e '
        const s = require(process.argv[1]);
        const t = [];
        for (const e of (s.hooks.PreToolUse || [])) {
            for (const h of (e.hooks || [])) {
                if (String(h.command).includes("confirm-forge-target-ownership")) t.push(Number(h.timeout) || 0);
            }
        }
        process.stdout.write(t.length ? String(Math.min.apply(null, t)) : "");
    ' "$SETTINGS" 2>/dev/null)"
    if [ -z "$reg_timeout" ] || [ "$reg_timeout" = "0" ]; then
        fail "R2-C10-1 the guard's PreToolUse entry declares a timeout" \
             "no numeric timeout on any entry running confirm-forge-target-ownership (got '${reg_timeout:-<none>}')"
        fail "R2-C10-2 that timeout exceeds the ${MAX_DECISION_BUDGET_S}s decision budget" "no timeout to compare"
        fail "R2-C10-3 a stalled probe reaches the host as an ask, not as a kill" "no timeout to run under"
        return
    fi
    pass "R2-C10-1 the guard's PreToolUse entry declares a timeout (${reg_timeout}s)"
    if [ "$reg_timeout" -gt "$MAX_DECISION_BUDGET_S" ]; then
        pass "R2-C10-2 ${reg_timeout}s exceeds the ${MAX_DECISION_BUDGET_S}s decision budget"
    else
        fail "R2-C10-2 that timeout exceeds the ${MAX_DECISION_BUDGET_S}s decision budget" \
             "registered ${reg_timeout}s <= budget ${MAX_DECISION_BUDGET_S}s — the host can kill the guard mid-decision"
    fi

    # R2-C10-3: the live half. Run the hook under the REAL registered timeout
    # (not the suite's generous 20s) with every probe stalled. A guard that leaves
    # the ask to the host's kill signal produces rc 124 and no output here.
    if [ ! -f "$HOOK" ]; then
        fail "R2-C10-3 a stalled probe reaches the host as an ask, not as a kill" \
             "hook absent — the guard cannot be run under its own registered timeout"
        return
    fi
    node "$BASE/mkjson.js" "cccccccc-0000-4000-8000-000000000010" "Bash" "$FX_OWNED" \
        "gh issue create --repo $OWNER/agents --title x" > "$BASE/in.json"
    : > "$GH_LOG"
    env "${ENV_UNSET[@]}" PATH="$MOCKBIN:$PATH" GH_STUB_LOG="$GH_LOG" GH_STUB_SLEEP=30 \
        "$RWT" "$reg_timeout" node "$HOOK" < "$BASE/in.json" > "$BASE/out.txt" 2>/dev/null
    local live_rc=$?
    local live_dec
    live_dec="$(node "$BASE/decide.js" "$BASE/out.txt" 2>/dev/null)"
    live_dec="${live_dec%%	*}"
    if [ "$live_rc" -eq 124 ]; then
        fail "R2-C10-3 a stalled probe reaches the host as an ask, not as a kill" \
             "the hook was still running at ${reg_timeout}s — the host would kill it and the write would proceed unguarded"
    elif [ "$live_dec" = "ask" ]; then
        pass "R2-C10-3 a stalled probe reaches the host as an ask, not as a kill"
    else
        fail "R2-C10-3 a stalled probe reaches the host as an ask, not as a kill" \
             "finished within ${reg_timeout}s but decided '$live_dec' (rc=$live_rc)"
    fi
}
