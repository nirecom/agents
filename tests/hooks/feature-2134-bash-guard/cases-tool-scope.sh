# tests/feature-2134-bash-guard/cases-tool-scope.sh
# Tests: hooks/bash-guard/judge.js, hooks/bash-guard/reasons.js, settings.json
# Tags: hook, bash-guard, tool-scope, pretooluse, registration, scope:issue-specific, pwsh-not-required, TL2
# T1-T4: the guard answers for tool_name "Bash" and nothing else. Sourced by the dispatcher.

# WHY THE SCOPE IS THIS NARROW (codex round 1, C4). The detector is a bash grammar reader.
# On a Windows host runInTerminal / runCommands can drive pwsh, where a backtick is a line
# continuation, `{ }` is a script block and `$env:` is a variable -- reading that with a bash
# parser produces confident false denials. The hole is deliberate and documented; closing it
# needs dialect support, which is a separate issue. Do not widen the matcher to make a row
# here pass.

t1_out_of_scope_tools() {
    local name tool got
    while IFS='~' read -r name tool; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        tool="${tool//[[:space:]]/}"
        ROWS=$((ROWS + 1))

        got="$(verdict_of 'git status && ls | grep x' 'sid-bg-armed' "$tool")"
        assert_eq "T1/$name: a compound payload on tool_name=$tool is allowed" "allow" "$got"

        got="$(probe judge 'git status && ls | grep x' 'sid-bg-armed' "$tool")"
        assert_contains "T1/$name: the allow is attributed to the out-of-scope reason code" \
            "BG-TOOL-OUT-OF-SCOPE" "$got"
    done <<'TABLE'
run-in-terminal ~ runInTerminal
run-commands    ~ runCommands
TABLE
}

t1_out_of_scope_tools

# T2: the same payload on tool_name=Bash IS denied -- otherwise T1 would pass because the
# guard denies nothing at all.
assert_eq "T2: the identical payload on tool_name=Bash is denied (T1 is not vacuous)" \
    "deny" "$(verdict_of 'git status && ls | grep x' 'sid-bg-armed' 'Bash')"

# T3: a write tool is out of scope too -- the guard reads tool_input.command, which Edit
# does not have, and must not invent a verdict from an absent field.
assert_eq "T3: a non-command tool is out of scope" \
    "allow" "$(verdict_of 'irrelevant' 'sid-bg-armed' 'Edit')"

# T4: registration. The PreToolUse group that runs hooks/bash-guard.js carries the bare
# matcher "Bash". This is the structural half of the TL3 gap recorded in the dispatcher.
assert_eq "T4: bash-guard is registered under exactly one PreToolUse matcher, and it is Bash" \
    "Bash" "$(probe guard-hook-matchers '')"
