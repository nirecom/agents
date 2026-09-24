# tests/feature-2134-bash-guard/cases-runtime-pretooluse.sh
# Tests: hooks/bash-guard.js, hooks/bash-guard/judge.js, settings.json
# Tags: hook, bash-guard, pretooluse, runtime, subprocess, dispatcher, scope:issue-specific, pwsh-not-required, TL2
# P1-P5: the hook driven as a real process, plus its dispatcher shape. Sourced by the dispatcher.

# WHY A SUBPROCESS AND NOT judgeBashCommand(). Every other file here calls the module in
# process, so all of them would still pass if hooks/bash-guard.js never read stdin, never
# printed the protocol envelope, or exited non-zero. Claude Code sees only stdout and the exit
# code: a hook that throws is a hook that silently permits. These rows are the only place the
# wire format itself is asserted, so they are what stands between a green suite and a guard
# that has never actually blocked anything.

BG_HOOK="$AGENTS_DIR/hooks/bash-guard.js"
BG_RUNTIME_OUT="$TMPROOT/runtime-out.txt"

# bg_run <tool> <command> -> "<exit-code>|<decision-or-none>"; a missing hook is reported as
# such instead of letting node's own error text stand in for a verdict.
bg_run() {
    local tool="$1" cmd="$2" rc payload decision
    if [ ! -f "$BG_HOOK" ]; then printf '%s' "<MISSING:hooks/bash-guard.js>"; return; fi
    payload="$(BG_TOOL="$tool" BG_CMD="$cmd" node -e 'process.stdout.write(JSON.stringify({session_id:"sid-bg-armed",tool_name:process.env.BG_TOOL,tool_input:{command:process.env.BG_CMD}}))')"
    printf '%s' "$payload" | HOME="$FIXTURE_HOME" USERPROFILE="$FIXTURE_HOME" \
        run_with_timeout 30 node "$(node_path "$BG_HOOK")" > "$BG_RUNTIME_OUT" 2>/dev/null
    rc=$?
    decision="$(grep -o '"decision"[[:space:]]*:[[:space:]]*"[a-z]*"' "$BG_RUNTIME_OUT" | head -1 | grep -o '[a-z]*"$' | tr -d '"')"
    printf '%s|%s' "$rc" "${decision:-none}"
}

# bg_run_raw <stdin-text> -> the same "<exit-code>|<decision-or-none>" for a payload the hook
# never had a chance to parse.
bg_run_raw() {
    local rc decision
    if [ ! -f "$BG_HOOK" ]; then printf '%s' "<MISSING:hooks/bash-guard.js>"; return; fi
    printf '%s' "$1" | HOME="$FIXTURE_HOME" USERPROFILE="$FIXTURE_HOME" \
        run_with_timeout 30 node "$(node_path "$BG_HOOK")" > "$BG_RUNTIME_OUT" 2>/dev/null
    rc=$?
    decision="$(grep -o '"decision"[[:space:]]*:[[:space:]]*"[a-z]*"' "$BG_RUNTIME_OUT" | head -1 | grep -o '[a-z]*"$' | tr -d '"')"
    printf '%s|%s' "$rc" "${decision:-none}"
}

p1_runtime() {
    local name tool cmd want got
    while IFS='~' read -r name tool cmd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        tool="${tool//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(bg_run "$tool" "$cmd")"
        assert_eq "P1/$name: the hook process exits 0 and emits the expected decision" "$want" "$got"
    done <<'TABLE'
compound-bash ~ Bash          ~ git status && ls | grep x ~ 0|block
plain-bash    ~ Bash          ~ git status               ~ 0|approve
out-of-scope  ~ runInTerminal ~ git status && ls | grep x ~ 0|approve
TABLE
}

p1_runtime

# P2: the block carries its reason on the same envelope. A block with an empty reason is the
# #2120 failure mode -- the model is stopped and told nothing.
printf '%s' '{"session_id":"sid-bg-armed","tool_name":"Bash","tool_input":{"command":"git status && ls"}}' \
    | HOME="$FIXTURE_HOME" USERPROFILE="$FIXTURE_HOME" \
      run_with_timeout 30 node "$(node_path "$BG_HOOK")" > "$BG_RUNTIME_OUT" 2>/dev/null
assert_contains "P2: the block envelope carries a non-empty reason" \
    "Command-Line Issuance Discipline" "$(cat "$BG_RUNTIME_OUT" 2>/dev/null)"

# P3: malformed stdin must not stop the session. The hook is on every Bash call, so a crash
# here is a crash on every command -- fail-open reaches all the way to the process boundary.
assert_eq "P3: malformed stdin exits 0 and emits no block" "0|none" "$(bg_run_raw 'not json at all')"

# P4: the entrypoint is dispatch + re-export (file-split Pattern A). Requiring it must expose
# judgeBashCommand and do nothing else -- the probe requires it without stdin, so a module that
# reads stdin or calls process.exit at load time cannot answer here.
assert_eq "P4: hooks/bash-guard.js re-exports judgeBashCommand" "function" "$(probe entry-shape '')"

# P5: no leakage to the USER-VISIBLE surface. The in-process rows assert only the internal
# `sample` field, which would stay clean even if the process echoed the whole command line to
# stdout or stderr. A denied command routinely carries a downstream credential in an argument,
# and the hook's output is transcript text -- so the real stdout, the real stderr and the
# serialized `reason` must all be free of the token AND of the raw command line.
BG_SECRET_OUT="$TMPROOT/secret-out.txt"
BG_SECRET_ERR="$TMPROOT/secret-err.txt"
BG_FAKE_TOKEN="notreal-2134-canary-9d41ba7e-token"
BG_SECRET_CMD="curl -H Authorization:Bearer-$BG_FAKE_TOKEN https://example.com/v1 | tee /tmp/leak.log"
BG_SECRET_PAYLOAD="$(BG_CMD="$BG_SECRET_CMD" node -e 'process.stdout.write(JSON.stringify({session_id:"sid-bg-armed",tool_name:"Bash",tool_input:{command:process.env.BG_CMD}}))')"
printf '%s' "$BG_SECRET_PAYLOAD" | HOME="$FIXTURE_HOME" USERPROFILE="$FIXTURE_HOME" \
    run_with_timeout 30 node "$(node_path "$BG_HOOK")" > "$BG_SECRET_OUT" 2> "$BG_SECRET_ERR"
BG_SECRET_STDOUT="$(cat "$BG_SECRET_OUT" 2>/dev/null)"
BG_SECRET_STDERR="$(cat "$BG_SECRET_ERR" 2>/dev/null)"

# Vacuity guard: if the command were allowed there would be no reason string to leak from,
# and every absence check below would pass against an empty envelope.
ROWS=$((ROWS + 1))
assert_contains "P5: the secret-bearing compound command is actually blocked" \
    '"decision":"block"' "$BG_SECRET_STDOUT"
ROWS=$((ROWS + 1))
assert_not_contains "P5: the token never reaches stdout (the reason the model reads)" \
    "$BG_FAKE_TOKEN" "$BG_SECRET_STDOUT"
ROWS=$((ROWS + 1))
assert_not_contains "P5: the token never reaches stderr" "$BG_FAKE_TOKEN" "$BG_SECRET_STDERR"
ROWS=$((ROWS + 1))
assert_not_contains "P5: the raw command line is not echoed back on stdout" \
    "$BG_SECRET_CMD" "$BG_SECRET_STDOUT$BG_SECRET_STDERR"

# SKIPPED: asserting that Claude Code itself dispatches the hook on a live Bash tool call.
# Because: that is host behaviour -- the suite can drive the process and assert the matcher in
#          settings.json (cases-tool-scope.sh T4), but not the host's wiring between them.
# L3 gap: the 5s hook timeout under a cold Node start; recorded in the dispatcher's TL3 block.
