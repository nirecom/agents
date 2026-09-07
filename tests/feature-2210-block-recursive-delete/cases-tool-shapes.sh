# tests/feature-2210-block-recursive-delete/cases-tool-shapes.sh
# Tests: hooks/block-recursive-delete.js, hooks/lib/tool-command-text.js
# Tags: scope:issue-specific, recursive-delete, hook, tool-shapes, runcommands, TL2, pwsh-not-required
#
# Bash and runInTerminal carry `command`; runCommands carries a `commands` array
# — reading only `.command` let runCommands bypass silently (#1780). TL3 gap:
# text-only shapes, no real host process builds these payloads.


# payload_cmd_at_offset <offset> <marker> [tool] — pads with 'A' bytes so marker starts near that stdin byte offset (readStdin() 64KiB boundary, round-6).
payload_cmd_at_offset() {
    node -e '
const targetOffset = parseInt(process.argv[1], 10);
const marker = process.argv[2];
const toolName = process.argv[3] || "Bash";
const base = JSON.stringify({tool_name: toolName, tool_input: {command: "echo ; " + marker}});
const markerIdx = base.indexOf(marker);
const padLen = Math.max(0, targetOffset - markerIdx);
const full = JSON.stringify({tool_name: toolName, tool_input: {command: "echo " + "A".repeat(padLen) + "; " + marker}});
process.stdout.write(full);
' -- "$1" "$2" "${3:-Bash}"
}

# run_fault_injection_case <desc> <preload-js-body> <payload> [leak-needle] —
# runs the hook under a --require preload that simulates an in-process fault.
run_fault_injection_case() {
    local desc="$1" patch_body="$2" payload="$3" needle="${4:-}"
    local patch_file out st verdict
    patch_file="$(mktemp "${TMPDIR:-/tmp}/2210-fault-XXXXXX.js")"
    printf '%s\n' "$patch_body" > "$patch_file"
    out="$(printf '%s' "$payload" | NODE_OPTIONS="--require $(np "$patch_file")" run_with_timeout 60 node "$HOOK" 2>/dev/null)"
    st=$?
    rm -f "$patch_file"
    if [ "$st" -ne 0 ]; then
        fail "$desc — hook exited non-zero ($st): crash or timeout, not a verdict"; return 1
    fi
    if [ -z "$out" ]; then
        fail "$desc — hook produced EMPTY stdout: no verdict was emitted"; return 1
    fi
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then
        pass "$desc"
    else
        fail "$desc — expected block (fail-closed), got verdict '$verdict' from: $out"; return 1
    fi
    if [ -n "$needle" ]; then
        lacks "$desc — reason does not leak the blocked command's own text" "$needle" "$(reason_of "$out")"
    fi
}

run_tool_shape_cases() {
    echo ""
    echo "=== The same verdict through all three tool shapes ==="

    expect_block "Bash: rm -r dir" "$(payload_cmd 'rm -r dir' Bash)"
    expect_block "runInTerminal: rm -r dir" "$(payload_cmd 'rm -r dir' runInTerminal)"
    expect_block "runCommands (single element): rm -r dir" "$(payload_commands 'rm -r dir')"

    expect_approve "Bash: rm -f file (non-recursive)" "$(payload_cmd 'rm -f file' Bash)"
    expect_approve "runInTerminal: rm -f file (non-recursive)" "$(payload_cmd 'rm -f file' runInTerminal)"
    expect_approve "runCommands (single element): rm -f file" "$(payload_commands 'rm -f file')"

    echo ""
    echo "=== runCommands arrays of 2+ elements (newline-injection route) ==="

    expect_block "runCommands [echo done, rm -rf x]" \
        "$(payload_commands 'echo done' 'rm -rf x')"
    expect_block "runCommands [echo a, rm -r dir, echo b] (delete in the middle)" \
        "$(payload_commands 'echo a' 'rm -r dir' 'echo b')"
    expect_block "runCommands [echo done, Remove-Item -Recurse dir]" \
        "$(payload_commands 'echo done' 'Remove-Item -Recurse dir')"
    expect_approve "runCommands [echo hello, echo world] (no over-block)" \
        "$(payload_commands 'echo hello' 'echo world')"
    expect_approve "runCommands [git status, rm -f file] (non-recursive delete)" \
        "$(payload_commands 'git status' 'rm -f file')"

    echo ""
    echo "=== Payloads the hook must approve without inspecting a command ==="

    expect_approve "Read tool (not a command tool)" \
        '{"tool_name":"Read","tool_input":{"file_path":"/tmp/rm -rf.md"}}'
    expect_approve "empty command string" "$(payload_cmd '' Bash)"
    expect_approve "runCommands with an empty array" '{"tool_name":"runCommands","tool_input":{"commands":[]}}'
    expect_approve "missing tool_input" '{"tool_name":"Bash"}'
    # Unparseable stdin is a transport fault, not a command: fail-open by design.
    expect_approve "unparseable stdin JSON (transport fail-open)" 'not json at all'

    echo ""
    echo "=== MEDIUM: malformed tool_input shapes must not crash the guard ==="

    # Well-formed JSON with an ill-typed field, unlike the unparseable case above.
    # commandTextOf String()s a non-array `commands`, so a scalar one still scans
    # as real command text — expecting approve here was a real bypass, now fixed.
    expect_block "runCommands.commands is a string, not an array (commandTextOf degrades via String() to the literal command text — must still block)" \
        '{"tool_name":"runCommands","tool_input":{"commands":"rm -rf x"}}'
    expect_approve "Bash tool_input.command is a number, not a string" \
        '{"tool_name":"Bash","tool_input":{"command":42}}'
    expect_approve "tool_input is null" \
        '{"tool_name":"Bash","tool_input":null}'
    expect_approve "top-level JSON is an array, not an object" \
        '[{"tool_name":"Bash","tool_input":{"command":"rm -rf x"}}]'
    expect_approve "runCommands.commands contains a non-string element" \
        '{"tool_name":"runCommands","tool_input":{"commands":["echo ok", 42]}}'

    echo ""
    echo "=== MEDIUM: scalar top-level JSON body must not crash the guard (round-4 C7) ==="

    # JSON.parse succeeds here, but .tool_name on a non-object top level crashes
    # without an explicit guard — unlike the unparseable case, which throws first.
    expect_approve "top-level JSON is null" "null"
    expect_approve "top-level JSON is a string" '"just a string"'
    expect_approve "top-level JSON is a number" "42"

    echo ""
    echo "=== HIGH: readStdin() 64KiB read-loop boundary (round-6 regression, C2) ==="

    # Past regression: readStdin() kept a subarray VIEW over its reused 65536-byte
    # Buffer, so a delete after the first chunk was corrupted away and bypassed.
    expect_block "recursive delete straddling the 65536-byte read boundary" \
        "$(payload_cmd_at_offset 65533 'rm -rf x')"
    expect_block "recursive delete starting exactly at the 65536-byte boundary" \
        "$(payload_cmd_at_offset 65536 'rm -rf x')"
    expect_block "recursive delete well past the first 64KiB chunk (~70000 bytes in)" \
        "$(payload_cmd_at_offset 70000 'rm -rf x')"
    expect_approve "equally long benign payload past the 64KiB boundary must not over-block" \
        "$(payload_cmd_at_offset 70000 'echo done')"

    echo ""
    echo "=== HIGH: fail-closed on in-process faults, never leaking raw input (C3) ==="

    # The settings.json deny globs are gone, so this hook is the last layer: a
    # read fault or a corrupt lib must block, never approve. Neither is
    # reproducible without breaking the host, hence the preload injection.
    run_fault_injection_case \
        "readSync throws mid-read (simulated EAGAIN/EINTR) -> fail-closed block, not approve" \
        'const fs=require("fs");const orig=fs.readSync;fs.readSync=function(fd){if(fd===0){throw new Error("SIMULATED_EAGAIN_FAULT");}return orig.apply(this,arguments);};' \
        "$(payload_cmd 'echo secret-marker-9f3a1c; rm -rf x' Bash)" \
        "secret-marker-9f3a1c"
    run_fault_injection_case \
        "lazy require of recursive-delete-scan throws (simulated corrupt lib file) -> fail-closed block, not approve" \
        'const M=require("module");const orig=M._load;M._load=function(request){if(String(request).indexOf("recursive-delete-scan")!==-1){throw new Error("SIMULATED_CORRUPT_LIB_FAULT");}return orig.apply(this,arguments);};' \
        "$(payload_cmd 'echo secret-marker-9f3a1c; rm -rf x' Bash)" \
        "secret-marker-9f3a1c"
}
