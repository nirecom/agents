#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C3 — the runCommands array payload, in every shape the tool really sends.
#
# WHY: tool-command-text.js reads tool_input.commands[] for runCommands; a
# guard blind to the array family misses an empty array, a null element that
# crashes a naive join, and — the actual bypass — a foreign write parked at an
# index the scan stops before reaching. Every index is in scope.

run_block_c3() {
    echo ""
    echo "=== C3: runCommands commands[] — element count, holes, and index ==="

    local OWNED_CMD="gh issue create --repo $OWNER/agents --title x"
    local FOREIGN_CMD="gh issue create --repo $FOREIGN/r --title x"
    local FILLER="echo filler"

    # Degenerate shapes first: neither may crash, and neither may be treated as
    # "a write happened" — an empty array is not a forge write.
    reset_env
    run_commands_json "$FX_OWNED" '[]'
    assert_decision "C3-1 empty commands[] -> silent, no crash" "silent"
    assert_probes "C3-1b an empty array spends no probe" "api user" 0

    reset_env
    run_commands_json "$FX_OWNED" '[null]'
    assert_decision "C3-2 a lone null element -> silent, no crash" "silent"

    reset_env
    run_commands_json "$FX_OWNED" '["'"$FOREIGN_CMD"'"]'
    assert_decision "C3-3 one-element array, foreign write -> ask" "ask"
    reset_env
    run_commands_json "$FX_OWNED" '["'"$OWNED_CMD"'"]'
    assert_decision "C3-4 one-element array, owned write -> silent allow" "silent"

    # The one-element array is the shape a collapsing builder would have turned
    # into tool_input.command. C3-3/C3-4 above and this pair together prove the
    # guard reaches the same verdict through BOTH payload spellings.
    reset_env
    run_case "$FX_OWNED" "$FOREIGN_CMD"
    assert_decision "C3-5a tool_input.command foreign -> ask (parity control)" "ask"
    reset_env
    run_commands_json "$FX_OWNED" '["'"$FOREIGN_CMD"'"]'
    assert_decision "C3-5b commands[0] foreign reaches the same verdict" "ask"

    # Duplicates must not deduplicate into "already checked, skip".
    reset_env
    run_commands_json "$FX_OWNED" '["'"$FOREIGN_CMD"'","'"$FOREIGN_CMD"'"]'
    assert_decision "C3-6 the same foreign write twice -> ask" "ask"
    reset_env
    run_commands_json "$FX_OWNED" '["'"$OWNED_CMD"'","'"$OWNED_CMD"'"]'
    assert_decision "C3-7 the same owned write twice -> silent allow" "silent"

    # A null hole must not truncate the scan: the foreign write sits AFTER it.
    reset_env
    run_commands_json "$FX_OWNED" '["'"$FILLER"'",null,"'"$FOREIGN_CMD"'"]'
    assert_decision "C3-8 a null element does not truncate the scan -> ask" "ask"
    # And a non-string element is equally unable to end the scan early.
    reset_env
    run_commands_json "$FX_OWNED" '[42,{"a":1},"'"$FOREIGN_CMD"'"]'
    assert_decision "C3-9 non-string elements do not truncate the scan -> ask" "ask"

    # THE index sweep. A foreign write at every position of a 4-element array.
    # A scan that reads only the first or only the last element passes three of
    # these four and ships the bypass.
    local i idx_json
    for i in 0 1 2 3; do
        idx_json="$(node -e '
            const n = Number(process.argv[1]), foreign = process.argv[2], filler = process.argv[3];
            const a = [];
            for (let k = 0; k < 4; k++) a.push(k === n ? foreign : filler);
            process.stdout.write(JSON.stringify(a));
        ' "$i" "$FOREIGN_CMD" "$FILLER")"
        reset_env
        run_commands_json "$FX_OWNED" "$idx_json"
        assert_decision "C3-10[$i] foreign write at commands[$i] of 4 -> ask" "ask"
    done

    # The symmetric control: the same 4-element shape, all owned. Without it,
    # C3-10 would also pass a guard that asks at every multi-element array.
    reset_env
    run_commands_json "$FX_OWNED" '["'"$FILLER"'","'"$OWNED_CMD"'","'"$FILLER"'","'"$OWNED_CMD"'"]'
    assert_decision "C3-11 four elements, every write owned -> silent allow" "silent"

    # An implicit target inside an array element still depends on the cwd that
    # element runs in, and the array shares one shell context (see Q-6).
    reset_env
    run_commands_json "$FX_OWNED" '["cd '"$FX_FOREIGN"'","gh issue create --title x"]'
    assert_decision "C3-12 cd in commands[0], bare create in commands[1] -> ask" "ask"

    # runInTerminal is the third registered shape and must not be forgotten.
    reset_env
    run_tool_case "runInTerminal" "$FX_OWNED" "$OWNED_CMD"
    assert_decision "C3-13 runInTerminal with an owned target -> silent allow" "silent"
}
