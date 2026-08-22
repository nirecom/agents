#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C13 — CPR-SSOT reuse proven by MUTATION, not by grep.
#
# WHY: assert_source_has cannot distinguish "the guard reuses this" from "the
# guard mentions this" (a comment/unused import/dead code all pass it) — only a
# VERDICT that moves when the shared primitive changes proves real reuse.
# HOW: hooks/ is copied to a temp tree, one shared module in the copy is
# overridden via module.exports, and the copied hook runs the same payload.

run_block_c13() {
    echo ""
    echo "=== C13: dependency substitution over the shared primitives ==="

    local MUTROOT="$BASE/mut"
    local mutcount=0

    # mut_case <id> <module-rel-path> <append-js> <cwd> <baseline ask|silent> <command> [observe]
    # Runs the command twice: once against the pristine copied tree (which must
    # reproduce the baseline verdict) and once against the mutated copy (which
    # must NOT). Both halves are asserted — a mutation that changes nothing and a
    # baseline that never reproduced are different bugs with the same symptom.

    # <observe> selects WHAT must move: "decision" (default) compares the decision
    # token alone; "reason" compares decision AND reason text, for a module that
    # only shapes the sentence the user reads and can never move the token.
    mut_case() {
        local id="$1" rel="$2" js="$3" cwd="$4" baseline="$5" cmd="$6" observe="${7:-decision}"
        mutcount=$((mutcount + 1))
        local tree="$MUTROOT/$mutcount"
        rm -rf "$tree"; mkdir -p "$tree"
        if [ ! -d "$AGENTS_DIR/hooks" ]; then
            fail "$id" "hooks/ tree not found at $AGENTS_DIR/hooks"; return
        fi
        cp -r "$AGENTS_DIR/hooks" "$tree/hooks" 2>/dev/null
        local mut_hook="$tree/hooks/confirm-forge-target-ownership.js"
        if [ ! -f "$mut_hook" ]; then
            fail "$id [pristine copy reproduces the baseline]" \
                 "hook absent in the copied tree — guard source not created yet"
            fail "$id [mutating $rel changes the verdict]" \
                 "hook absent in the copied tree — guard source not created yet"
            rm -rf "$tree"; return
        fi
        if [ ! -f "$tree/hooks/$rel" ]; then
            fail "$id [pristine copy reproduces the baseline]" "no such module: hooks/$rel"
            fail "$id [mutating $rel changes the verdict]" "no such module: hooks/$rel"
            rm -rf "$tree"; return
        fi
        node "$BASE/mkjson.js" "$SID_MUT" "Bash" "$cwd" "$cmd" > "$BASE/in.json"
        local pristine_full mutated_full pristine mutated observed_p observed_m what
        pristine_full="$(_mut_dispatch "$mut_hook")"
        pristine="${pristine_full%%	*}"
        if [ "$pristine" = "$baseline" ]; then
            pass "$id [pristine copy reproduces the baseline $baseline]"
        else
            fail "$id [pristine copy reproduces the baseline $baseline]" "got $pristine"
        fi
        printf '\n%s\n' "$js" >> "$tree/hooks/$rel"
        mutated_full="$(_mut_dispatch "$mut_hook")"
        mutated="${mutated_full%%	*}"
        local shown_p shown_m
        if [ "$observe" = "reason" ]; then
            observed_p="$pristine_full"; observed_m="$mutated_full"; what="the reason"
            # The two reasons share a long prefix, so echoing them adds no signal:
            # the decision the reason rode in on is the useful context.
            shown_p="$pristine text"; shown_m="$mutated text (changed)"
        else
            observed_p="$pristine"; observed_m="$mutated"; what="the verdict"
            shown_p="$pristine"; shown_m="$mutated"
        fi
        if [ "$observed_m" != "$observed_p" ]; then
            pass "$id [mutating $rel moves $what: $shown_p -> $shown_m]"
        else
            fail "$id [mutating $rel moves $what]" \
                 "$what stayed $observed_m — the guard does not reach hooks/$rel"
        fi
        rm -rf "$tree"
    }
    # <hook-path> -> prints "<decision><TAB><reason>" (or a bare crash token).
    _mut_dispatch() {
        local d
        : > "$GH_LOG"
        env "${ENV_UNSET[@]}" PATH="$MOCKBIN:$PATH" GH_STUB_LOG="$GH_LOG" \
            "$RWT" 20 node "$1" < "$BASE/in.json" > "$BASE/mut-out.txt" 2>/dev/null
        local rc=$?
        [ "$rc" -ne 0 ] && { printf 'crash-rc%s' "$rc"; return; }
        d="$(node "$BASE/decide.js" "$BASE/mut-out.txt" 2>/dev/null)"
        printf '%s' "$d"
    }
    SID_MUT="dddddddd-0000-4000-8000-000000000001"

    # 1. Forge extraction. If the guard classified writes with its own regex, an
    #    isForgeScanTarget that answers "never a write" would not quiet it.
    mut_case "C13-1 forge extraction (forge-write-extract.js)" \
        "lib/forge-write-extract.js" \
        'module.exports.isForgeScanTarget = function () { return false; };
         module.exports.isRepoWriteTarget = function () { return false; };' \
        "$FX_OWNED" "ask" "gh issue create --repo $FOREIGN/r --title x"

    # 2. Remote parsing. The implicit target comes from origin; a parser that
    #    returns nothing must turn a previously-provable cwd into an ask.
    mut_case "C13-2 remote parsing (parse-remote-url.js)" \
        "lib/parse-remote-url.js" \
        'module.exports.parseOriginOwnerRepo = function () { return null; };' \
        "$FX_OWNED" "silent" "gh issue create --title x"

    # 3. Wrapper peeling. `nice gh ...` only resolves because peelWrappers
    #    strips the head; a peeler that gives up must make it unresolved.
    mut_case "C13-3 wrapper peeling (bash-write-patterns/segment-utils.js)" \
        "lib/bash-write-patterns/segment-utils.js" \
        'module.exports.peelWrappers = function (cmd0, argv) {
             return { cmd0: cmd0, argv: argv, ambiguous: true };
         };' \
        "$FX_OWNED" "silent" "nice gh issue create --repo $OWNER/agents --title x"

    # 4. Subcommand resolution. `gh -R x issue create` is only recognised because
    #    resolveGhSubArgv skips the global flag; without the skip the subcommand
    #    reads as "-R", and the verdict must move.
    mut_case "C13-4 subcommand resolution (bash-write-patterns/patterns.js)" \
        "lib/bash-write-patterns/patterns.js" \
        'module.exports.resolveGhSubArgv = function (argv) { return argv; };' \
        "$FX_OWNED" "ask" "gh -R $FOREIGN/repo issue create --title x"

    # 5. Reason codes. The registry is the guard-private SSOT for the text the
    #    user reads, never for control flow — so the evidence it is reached is the
    #    REASON moving, not the decision token (observe=reason).
    mut_case "C13-5 reason codes (confirm-forge-target-ownership/reasons.js)" \
        "confirm-forge-target-ownership/reasons.js" \
        'module.exports.reasonText = function () { return "c13-mutated-code"; };' \
        "$FX_OWNED" "ask" "bash -c \"cd $FX_FOREIGN && gh issue create --title x\"" \
        "reason"

    # 6. The nested-body depth cap is shared too: raising it to zero must make an
    #    ordinary single-level body unresolvable.
    mut_case "C13-6 nested-scan depth cap (confirm-forge-target-ownership/nested-commands.js)" \
        "confirm-forge-target-ownership/nested-commands.js" \
        'module.exports.nestedBodyOf = function () { return { kind: "none" }; };' \
        "$FX_OWNED" "ask" "bash -c \"gh issue create --repo $FOREIGN/x\""

    # The mutation harness itself must be able to fail: if cp/append/dispatch
    # were broken, every row above would report the same "verdict stayed" text
    # and look like a genuine SSOT finding. This row mutates the ENTRY hook to
    # emit a fixed ask, which must move a baseline-silent case.
    mut_case "C13-7 harness self-check (the entry hook itself)" \
        "confirm-forge-target-ownership.js" \
        'process.stdout.write(JSON.stringify({ hookSpecificOutput: {
             hookEventName: "PreToolUse", permissionDecision: "ask",
             permissionDecisionReason: "c13-harness-selfcheck" } }));' \
        "$FX_OWNED" "silent" "gh issue create --repo $OWNER/agents --title x"

    rm -rf "$MUTROOT"
    unset -f mut_case _mut_dispatch
}
