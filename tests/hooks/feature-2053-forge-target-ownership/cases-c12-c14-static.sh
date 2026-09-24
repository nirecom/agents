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
    echo "=== R3-NUL: no guard module carries a raw NUL byte ==="

    # WHY: prove-ownership.js once joined its fingerprint parts on a literal
    # 0x00 byte. At runtime that is identical to "\u0000", but git classifies
    # a file containing it as binary and prints "Binary files ... differ"
    # instead of a diff, blinding every diff-based reviewer to the whole file.
    # The behavioral fingerprint cases stay green either way — which is why
    # this defect needs a BYTE-level check. Scoped to the whole guard directory
    # (CPR-E2C): the class is "a raw NUL anywhere in this implementation".

    local GUARD="$AGENTS_DIR/hooks/confirm-forge-target-ownership"
    local js_count=0
    if [ -d "$GUARD" ]; then js_count="$(ls "$GUARD"/*.js 2>/dev/null | wc -l | tr -d ' ')"; fi
    if [ "${js_count:-0}" -lt 1 ]; then
        fail "R3-NUL-0 the guard implementation directory holds .js modules" \
             "no .js modules found under $GUARD"
    else
        pass "R3-NUL-0 the guard implementation directory holds .js modules ($js_count)"
        local offenders
        offenders="$(nul_scan "$(npath "$GUARD")")"
        if [ -z "$offenders" ]; then
            pass "R3-NUL-1 no .js module under the guard directory contains a 0x00 byte"
        else
            fail "R3-NUL-1 no .js module under the guard directory contains a 0x00 byte" \
                 "raw NUL byte(s) found — git treats these as binary and hides them from every diff review: $(printf '%s' "$offenders" | tr '\n' ' ')"
        fi
    fi

    # The scanner itself must be able to fail, or R3-NUL-1 is a false green.
    local probe="$BASE/nul-probe.js"
    printf 'const sep = "a\000b";\n' > "$probe"
    local probe_hit
    probe_hit="$(nul_scan "$(npath "$probe")")"
    if printf '%s' "$probe_hit" | grep -q 'nul-probe.js:'; then
        pass "R3-NUL-2 the scanner flags a planted raw NUL byte (mutation probe)"
    else
        fail "R3-NUL-2 the scanner flags a planted raw NUL byte (mutation probe)" \
             "a file containing 0x00 was not reported: ${probe_hit:-<no output>}"
    fi
    printf 'const sep = "a\\u0000b";\n' > "$probe"
    probe_hit="$(nul_scan "$(npath "$probe")")"
    assert_eq "R3-NUL-3 the escaped backslash-u0000 form is not flagged" "" "$probe_hit"
    rm -f "$probe"

    # R3-NUL-4: nul_scan only walks .js files, so a raw NUL planted in one of
    # THIS suite's own .sh files — this file included — would pass R3-NUL-1
    # silently. Scope matches the class, not just the guard's own language.
    local TESTDIR="$AGENTS_DIR/tests/feature-2053-forge-target-ownership"
    local sh_offenders
    sh_offenders="$(nul_scan_sh "$(npath "$TESTDIR")")"
    if [ -z "$sh_offenders" ]; then
        pass "R3-NUL-4 no .sh file under this feature's own test directory contains a 0x00 byte"
    else
        fail "R3-NUL-4 no .sh file under this feature's own test directory contains a 0x00 byte" \
             "raw NUL byte(s) found — git treats these as binary and hides them from every diff review: $(printf '%s' "$sh_offenders" | tr '\n' ' ')"
    fi

    # nul_scan_sh must be able to fail too, or R3-NUL-4 is a false green — same
    # reasoning as the R3-NUL-2/R3-NUL-3 mutation probes for nul_scan itself.
    local sh_probe="$BASE/nul-probe.sh"
    printf 'echo "a\000b"\n' > "$sh_probe"
    local sh_probe_hit
    sh_probe_hit="$(nul_scan_sh "$(npath "$sh_probe")")"
    if printf '%s' "$sh_probe_hit" | grep -q 'nul-probe.sh:'; then
        pass "R3-NUL-5 nul_scan_sh flags a planted raw NUL byte (mutation probe)"
    else
        fail "R3-NUL-5 nul_scan_sh flags a planted raw NUL byte (mutation probe)" \
             "a .sh file containing 0x00 was not reported: ${sh_probe_hit:-<no output>}"
    fi
    printf 'echo "a\\u0000b"\n' > "$sh_probe"
    sh_probe_hit="$(nul_scan_sh "$(npath "$sh_probe")")"
    assert_eq "R3-NUL-6 the escaped backslash-u0000 form is not flagged by nul_scan_sh" "" "$sh_probe_hit"
    rm -f "$sh_probe"

    echo ""
    echo "=== R3-FP: authFingerprint has no un-separated component boundary ==="

    # WHY C1: parts.join uses a real NUL separator between fields (see R3-NUL
    # above). If a future edit ever concatenated the parts WITHOUT that
    # separator, two different (GH_CONFIG_DIR, GH_HOST) pairs whose text
    # straddles the boundary differently would hash to the identical
    # fingerprint, and a proof earned under one profile/host would silently
    # authorize the other. config="ab",host="c" and config="a",host="bc"
    # concatenate to the same "abc" without a separator but must not fingerprint
    # the same WITH one.
    local FP_MOD
    FP_MOD="$(npath "$AGENTS_DIR/hooks/confirm-forge-target-ownership/prove-ownership.js")"
    local fp_a fp_b
    fp_a="$(env -i PATH="$PATH" GH_CONFIG_DIR="ab" GH_HOST="c" \
        node -e 'process.stdout.write(require(process.argv[1]).authFingerprint());' "$FP_MOD" 2>/dev/null)"
    fp_b="$(env -i PATH="$PATH" GH_CONFIG_DIR="a" GH_HOST="bc" \
        node -e 'process.stdout.write(require(process.argv[1]).authFingerprint());' "$FP_MOD" 2>/dev/null)"
    if [ -z "$fp_a" ] || [ -z "$fp_b" ]; then
        fail "R3-FP-1 authFingerprint is callable with a controlled auth context" \
             "empty output (a=${fp_a:-<empty>} b=${fp_b:-<empty>})"
    else
        pass "R3-FP-1 authFingerprint is callable with a controlled auth context"
        if [ "$fp_a" = "$fp_b" ]; then
            fail "R3-FP-2 a GH_CONFIG_DIR/GH_HOST boundary shift changes the fingerprint" \
                 "config='ab',host='c' and config='a',host='bc' collided: $fp_a"
        else
            pass "R3-FP-2 a GH_CONFIG_DIR/GH_HOST boundary shift changes the fingerprint"
        fi
    fi

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

# nul_scan <dir-or-file...> — prints one "<path>:<byte-offset>" line per .js file
# whose bytes contain 0x00, and nothing when every file is clean. It reads raw
# buffers, so no text encoding can hide the byte from it.
nul_scan() {
    node -e '
        const fs = require("fs"), path = require("path");
        const walk = (p, out) => {
            if (fs.statSync(p).isDirectory()) {
                for (const e of fs.readdirSync(p).sort()) walk(path.join(p, e), out);
                return out;
            }
            if (!p.endsWith(".js")) return out;
            const i = fs.readFileSync(p).indexOf(0);
            if (i !== -1) out.push(p.replace(/\\/g, "/") + ":" + i);
            return out;
        };
        const out = [];
        for (const a of process.argv.slice(1)) walk(a, out);
        process.stdout.write(out.join("\n"));
    ' "$@" 2>&1
}

# nul_scan_sh <dir-or-file...> — same raw-byte walk as nul_scan, scoped to
# .sh files instead of .js. A sibling, not a parameterized nul_scan, so the
# R3-NUL-2/3 mutation probes above stay pinned to the one behavior they cover.
nul_scan_sh() {
    node -e '
        const fs = require("fs"), path = require("path");
        const walk = (p, out) => {
            if (fs.statSync(p).isDirectory()) {
                for (const e of fs.readdirSync(p).sort()) walk(path.join(p, e), out);
                return out;
            }
            if (!p.endsWith(".sh")) return out;
            const i = fs.readFileSync(p).indexOf(0);
            if (i !== -1) out.push(p.replace(/\\/g, "/") + ":" + i);
            return out;
        };
        const out = [];
        for (const a of process.argv.slice(1)) walk(a, out);
        process.stdout.write(out.join("\n"));
    ' "$@" 2>&1
}
