#!/usr/bin/env bash
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/lib/tool-command-text.js, hooks/lib/write-tools.js, hooks/lib/protected-basenames.js
# Tags: block-clearance-token-write, dispatch, command-tools, runInTerminal, runCommands, protected-basename, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section C6 — the artifact-name boundary on ALL THREE command tools (review C2).
# dispatch.js:99 gates on isCommandTool() (list: hooks/lib/tool-command-text.js:32);
# Section C5 drives only Bash, so a payload shape reaching bashHitsProtected() with ""
# reads as "scanned and clean" — a silent full bypass (#1780). CPR-ORTH: every member.
C6_CONFIG=""
C6_WFDIR=""

# runCommands differs structurally — an ARRAY under `commands`, not a string under
# `command` — so its rows put the write in commands[1]. commandTextOf joins with "\n"
# so commands[1] is scanned as its own statement; a joiner regression would glue it
# onto commands[0]'s tail, and C6-6 is the row that catches that.

# _c6_run <stdin-json> -> raw hook stdout (+ <<HOOK_EXIT_n>> on a non-zero exit)
_c6_run() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        export AGENTS_CONFIG_DIR="$C6_CONFIG"
        export CLAUDE_WORKFLOW_DIR="$C6_WFDIR"
        export WORKFLOW_PLANS_DIR="$C6_WFDIR"
        run_hook_capture "$1" "$RWT" 20 node "$BCTW_HOOK"
    )
}

# _c6_payload <tool> <command-text> -> PreToolUse-shaped stdin, sid "wsid".
# Bash / runInTerminal both carry `command`; runCommands carries `commands[]` and the
# command under test is deliberately the SECOND element.
_c6_payload() {
    local tool="$1" cmd="$2"
    if [ "$tool" = "runCommands" ]; then
        printf '{"session_id":"wsid","tool_name":"runCommands","tool_input":{"commands":["echo start","%s"]}}' "$(json_esc "$cmd")"
    else
        printf '{"session_id":"wsid","tool_name":"%s","tool_input":{"command":"%s"}}' "$tool" "$(json_esc "$cmd")"
    fi
}

run_C6_command_tool_routes() {
    local dir dir_fwd tool cmdkey want label cmd out

    dir="$TMPBASE_SH/c6-cmdtools"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir"
    dir_fwd="$(node_path "$dir")"
    dir_fwd="${dir_fwd//\\//}"

    mkdir -p "$TMPBASE_SH/c6-config" "$TMPBASE_SH/c6-workflow"
    C6_CONFIG="$(node_path "$TMPBASE_SH/c6-config")"
    C6_WFDIR="$(node_path "$TMPBASE_SH/c6-workflow")"

    # C6-0 — harness guard, same reason as C5-0: an absent entrypoint approves
    # everything, the one failure mode the FP rows cannot tell from a correct narrowing.
    if [ -f "$BCTW_HOOK" ]; then
        pass "C6-0 block-clearance-token-write.js present"
    else
        fail "C6-0 block-clearance-token-write.js MISSING at $BCTW_HOOK - Section C6 would be vacuous"
        return
    fi

    # C6-0b — the tool list this section enumerates must BE the hook's own list, not a
    # copy of it: a fourth command tool then fails here instead of going unexercised.
    assert_eq "C6-0b command-tool set matches the SSOT list" "Bash runInTerminal runCommands" \
        "$(run_probe -e "process.stdout.write((require(process.argv[1]).COMMAND_TOOL_NAMES||[]).join(' '))" "$AGENTS_NODE/hooks/lib/tool-command-text.js")"

    # Table: one row per (tool x command-shape x direction). `cmdkey` selects the command
    # text so all THREE tools are driven with byte-identical shell text and the only
    # variable is the payload shape (CPR-SC).
    while IFS='|' read -r label tool cmdkey want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; tool="${tool//[[:space:]]/}"
        cmdkey="${cmdkey//[[:space:]]/}"; want="${want//[[:space:]]/}"
        case "$cmdkey" in
            tp-write)  cmd="echo x > $dir_fwd/wsid.gh-env" ;;
            fp-write)  cmd="echo x > $dir_fwd/issue-2108-survey.gh-env" ;;
            tp-rm)     cmd="rm -f $dir_fwd/wsid.gh-env" ;;
            fp-rm)     cmd="rm -f $dir_fwd/issue-2108-survey.gh-env" ;;
            plain)     cmd="echo x > $dir_fwd/plain-note.txt" ;;
            *)         cmd="echo unknown-key" ;;
        esac
        assert_eq "C6 $label [$tool $cmdkey]" "$want" "$(gate_decision "$(_c6_run "$(_c6_payload "$tool" "$cmd")")")"
    done <<'TABLE'
# label                  | tool          | command       | want
# --- DISCRIMINATOR: the route reaches an ALLOW at all in this fixture, so a block
# --- below is attributable to the basename classifier, not to ambient geography.
C6-1-plain               | Bash          | plain         | approve
C6-1-plain               | runInTerminal | plain         | approve
C6-1-plain               | runCommands   | plain         | approve
# --- TRUE POSITIVE: <sid>.<kind> is a forged clearance file on every command tool.
C6-2-tp-write            | Bash          | tp-write      | block
C6-2-tp-write            | runInTerminal | tp-write      | block
C6-2-tp-write            | runCommands   | tp-write      | block
# --- FALSE POSITIVE (#2108): the subagent's survey notes must pass on every tool.
C6-3-fp-write            | Bash          | fp-write      | approve
C6-3-fp-write            | runInTerminal | fp-write      | approve
C6-3-fp-write            | runCommands   | fp-write      | approve
# --- DELETE direction, both ways round (CPR-ORTH with C5-5).
C6-4-tp-rm               | Bash          | tp-rm         | block
C6-4-tp-rm               | runInTerminal | tp-rm         | block
C6-4-tp-rm               | runCommands   | tp-rm         | block
C6-5-fp-rm               | Bash          | fp-rm         | approve
C6-5-fp-rm               | runInTerminal | fp-rm         | approve
C6-5-fp-rm               | runCommands   | fp-rm         | approve
TABLE

    # C6-6 — runCommands, protected target in commands[1] AND a legitimate artifact
    # write in commands[0]. The clean element must not launder the forged one: a hook
    # scanning only commands[0] would approve while a real forgery executes.
    out="$(_c6_run "$(printf '{"session_id":"wsid","tool_name":"runCommands","tool_input":{"commands":["echo x > %s/issue-2108-survey.gh-env","echo x > %s/wsid.gh-env"]}}' "$dir_fwd" "$dir_fwd")")"
    assert_eq "C6-6 runCommands: a clean commands[0] does not launder a forged commands[1]" "block" \
        "$(gate_decision "$out")"
    assert_contains "C6-6 the block names the sanctioned sentinel route" "sentinel" "$(gate_reason "$out")"

    # C6-7 — the mirror: two ARTIFACT writes across both elements stay allowed, so C6-6
    # proves the classifier and not "runCommands blocks whenever it has two elements".
    assert_eq "C6-7 runCommands: two artifact writes across both elements are allowed" "approve" \
        "$(gate_decision "$(_c6_run "$(printf '{"session_id":"wsid","tool_name":"runCommands","tool_input":{"commands":["echo x > %s/issue-2108-survey.gh-env","echo y > %s/issue-2108-notes.workflow-off"]}}' "$dir_fwd" "$dir_fwd")")")"

    # C6-8 — Pattern 1 negative assertion: every blocked call above must have left the
    # forged target ABSENT. A verdict of "block" beside a file on disk is not a block.
    if [ -e "$dir/wsid.gh-env" ]; then
        fail "C6-8 blocked command-tool target was created at $dir/wsid.gh-env"
    else
        pass "C6-8 blocked command-tool target remains absent (Pattern 1)"
    fi

    # SKIPPED: runInTerminal / runCommands carrying PowerShell text.
    # Because: the pwsh scanner has its own suite (tests/enforce-protected-marker-write.sh)
    # and this file's tag set declares pwsh-not-required.
    # L3 gap: whether settings.json's matcher actually routes runInTerminal and
    # runCommands to this hook — asserted STATICALLY only, in Section C2.
}
