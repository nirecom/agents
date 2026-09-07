# tests/feature-2210-block-recursive-delete/cases-cmdexe.sh
# Tests: hooks/block-recursive-delete.js, hooks/lib/bash-write-targets/cmd-exe.js
# Tags: scope:issue-specific, recursive-delete, hook, cmd-exe, rmdir, TL2
#
# Text-only: no real cmd.exe process runs, so its own %VAR%/!VAR! and escaping
# semantics stay unverified (TL3 gap, C10 — see the dispatcher's `# TL3 gap`).

run_cmdexe_cases() {
    echo ""
    echo "=== cmd.exe — recursive deletes must block ==="

    expect_block_cmd "cmd /c rmdir /s dir" "cmd /c rmdir /s dir"
    expect_block_cmd "cmd /c \"rmdir /s dir\" (quoted payload)" 'cmd /c "rmdir /s dir"'
    expect_block_cmd "cmd /c rd /s dir" "cmd /c rd /s dir"
    expect_block_cmd "cmd /c del /s dir" "cmd /c del /s dir"
    expect_block_cmd "cmd.exe /k rmdir /s /q dir (/k, quiet)" "cmd.exe /k rmdir /s /q dir"
    expect_block_cmd "cmd /c \"rmdir /s dir & echo done\" (recursive clause first)" \
        'cmd /c "rmdir /s dir & echo done"'
    expect_block_cmd "cmd /c rd /s C:/s (independent /s plus path tail)" \
        "cmd /c rd /s C:/s"

    echo ""
    echo "=== cmd.exe — clause separators beyond & must also route to blocking (C8) ==="

    expect_block_cmd "cmd /c \"rmdir /s dir && echo done\" (&&-joined clause)" \
        'cmd /c "rmdir /s dir && echo done"'
    expect_block_cmd "cmd /c \"rmdir /s dir || echo fail\" (||-joined clause)" \
        'cmd /c "rmdir /s dir || echo fail"'
    expect_block_cmd "cmd /c \"echo start | rmdir /s dir\" (pipe-joined clause)" \
        'cmd /c "echo start | rmdir /s dir"'
    expect_block_cmd "cmd /C rmdir /S dir (uppercase /C and /S)" \
        "cmd /C rmdir /S dir"
    expect_block_cmd "cmd /s /c rd /s dir (cmd.exe's own /S switch before /c, real /s still in the /c payload)" \
        "cmd /s /c rd /s dir"

    echo ""
    echo "=== cmd.exe — no-space /c token is a PREFIX match, still blocks (round-4 fix) ==="

    # The /c token match is a PREFIX, not exact — reverts a round-6 approve regression.
    expect_block_cmd 'cmd /c"rd /s dir" (no space after /c, prefix match, round-4 fix)' \
        'cmd /c"rd /s dir"'

    echo ""
    echo "=== cmd.exe — its own ^-escaping is a documented non-goal (round-4 C2) ==="

    # Accepted gap, not a required verdict: detail.md Step 3 excludes cmd.exe's own ^ escaping.
    expect_approve_cmd "cmd /c r^d /^s dir (caret-escaped, documented non-goal)" \
        "cmd /c r^d /^s dir"

    echo ""
    echo "=== cmd.exe — recursive flag placed AFTER the target must still block (C4) ==="

    expect_block_cmd "cmd /c rd dir /s (flag after target, C4)" "cmd /c rd dir /s"

    echo ""
    echo "=== cmd.exe — unresolvable /c payload folds to block (C2, hook-integration level) ==="

    expect_block_cmd "cmd /c rmdir /s \$(echo x) (unresolvable payload, null -> block, C2)" \
        'cmd /c rmdir /s $(echo x)'

    echo ""
    echo "=== cmd.exe — %VAR%/!VAR! at a /-flag position fails closed (round-4 fix, C6) ==="

    # Only a `/`-prefixed token carrying % or ! fails closed; verb- and
    # target-position variables stay approved.
    expect_approve_cmd "cmd /c %CMD% /s dir (%VAR% at the verb position, not flag-prefixed)" \
        "cmd /c %CMD% /s dir"
    expect_approve_cmd "cmd /c rd dir !F! (bare !VAR! at target position, not flag-prefixed)" \
        "cmd /c rd dir !F!"
    expect_block_cmd "cmd /c rd /%F% dir (/-prefixed %VAR% flag token, fails closed, round-4)" \
        "cmd /c rd /%F% dir"
    expect_block_cmd "cmd /c rd dir /!F! (/-prefixed !VAR! flag token, fails closed, round-4)" \
        "cmd /c rd dir /!F!"
    expect_block_cmd "cmd /c rd /s %TEMP%\\dir (literal /s present, %VAR% only in target)" \
        'cmd /c rd /s %TEMP%\dir'
    expect_approve_cmd "cmd /c rd %TEMP%\\dir (no /s anywhere, %VAR% only in target)" \
        'cmd /c rd %TEMP%\dir'

    echo ""
    echo "=== cmd.exe — false-positive shapes must approve ==="

    expect_approve_cmd "cmd /c \"echo rmdir /s test\" (mention through echo)" \
        'cmd /c "echo rmdir /s test"'
    expect_approve_cmd "cmd /c \"rd dir & xcopy /s foo\" (/s in another clause)" \
        'cmd /c "rd dir & xcopy /s foo"'
    expect_approve_cmd "cmd /c rd C:/s (path tail, not a flag)" "cmd /c rd C:/s"
    expect_approve_cmd "cmd /c rmdir dir (no /s — empty dir only)" "cmd /c rmdir dir"
    expect_approve_cmd "cmd /c dir (unrelated command)" "cmd /c dir"
    # cmd.exe's own /s switch modifies quote-stripping, not delete recursion.
    expect_approve_cmd "cmd /s /c rd dir (cmd.exe's own /S switch, no /s in the payload)" \
        "cmd /s /c rd dir"

    echo ""
    echo "=== cmd.exe — bare verb form with no cmd /c head (not a real vector) ==="

    # Approved, not a coverage gap: rd, rmdir and del are cmd.exe internals with no
    # standalone executable, and real PowerShell has no /s switch either.
    expect_approve_cmd "rd /s dir (bare cmd-exe verb, no cmd /c head — not a real vector)" \
        "rd /s dir"

    echo ""
    echo "=== cmd.exe — glued/clustered switches must still resolve (round9 C5) ==="

    expect_block_cmd "cmd /c rd/s dir (rd and /s glued together, no space)" "cmd /c rd/s dir"
    expect_block_cmd "cmd /c rmdir /s/q dir (glued /s/q cluster)" "cmd /c rmdir /s/q dir"
    expect_block_cmd "cmd /c rmdir /q/s dir (glued /q/s cluster, reversed order)" "cmd /c rmdir /q/s dir"
    expect_approve_cmd "cmd /c rmdir /q dir (only /q, no /s anywhere)" "cmd /c rmdir /q dir"

    echo ""
    echo "=== cmd.exe — @/if/else clause prefixes must not hide the verb (round9 C5) ==="

    # stripClausePrefixes peels a leading `@`, `if`, or `else` token before head detection.
    expect_block_cmd 'cmd /c "@rd /s dir" (leading @ echo-suppression prefix)' \
        'cmd /c "@rd /s dir"'
    expect_block_cmd 'cmd /c "if exist dir rd /s dir" (if-prefixed clause)' \
        'cmd /c "if exist dir rd /s dir"'
    expect_block_cmd 'cmd /c "if exist dir (rd /s dir) else (echo none)" (if/else with parenthesized block)' \
        'cmd /c "if exist dir (rd /s dir) else (echo none)"'
    expect_approve_cmd 'cmd /c "@echo off" (leading @ prefix, harmless payload)' \
        'cmd /c "@echo off"'
    expect_approve_cmd 'cmd /c "if exist dir echo found" (if-prefixed clause, harmless payload)' \
        'cmd /c "if exist dir echo found"'

    echo ""
    echo "=== cmd.exe — call/start launcher verbs must not hide the delete (round9 C5) ==="

    # CMD_LAUNCHER_VERBS: `call` and `start` are transparent — the remaining argv
    # is re-examined as its own clause candidate.
    expect_block_cmd 'cmd /c "call rd /s dir" (call launcher)' \
        'cmd /c "call rd /s dir"'
    expect_block_cmd 'cmd /c "start rd /s dir" (start launcher)' \
        'cmd /c "start rd /s dir"'
    expect_block_cmd 'cmd /c "start /b rd /s dir" (start with /b switch before the verb)' \
        'cmd /c "start /b rd /s dir"'
    expect_approve_cmd 'cmd /c "call echo hi" (call launcher, harmless payload)' \
        'cmd /c "call echo hi"'
    expect_approve_cmd 'cmd /c "start echo hi" (start launcher, harmless payload)' \
        'cmd /c "start echo hi"'

    echo ""
    echo "=== cmd.exe — nested cmd /c must recurse into the inner payload (round9 C5) ==="

    # scanCmdExeText recurses up to MAX_CMD_NEST levels deep.
    expect_block_cmd 'cmd /c "cmd /c rd /s dir" (one level of cmd /c nesting)' \
        'cmd /c "cmd /c rd /s dir"'
    expect_block_cmd 'cmd /c "cmd /c cmd /c rd /s dir" (two levels of cmd /c nesting)' \
        'cmd /c "cmd /c cmd /c rd /s dir"'
    expect_approve_cmd 'cmd /c "cmd /c echo hi" (nested cmd /c, harmless payload)' \
        'cmd /c "cmd /c echo hi"'

    echo ""
    echo "=== cmd.exe — path-qualified verb executables must still resolve (round9 C5) ==="

    # cmdVerbBasename strips a directory prefix and .exe suffix before matching the verb.
    expect_block_cmd 'cmd /c "C:\\Windows\\System32\\rd.exe /s dir" (path-qualified rd.exe verb)' \
        'cmd /c "C:\Windows\System32\rd.exe /s dir"'
    expect_block_cmd 'cmd /c "C:\\Windows\\System32\\cmd.exe /c rd /s dir" (path-qualified nested cmd.exe)' \
        'cmd /c "C:\Windows\System32\cmd.exe /c rd /s dir"'
    expect_approve_cmd 'cmd /c "C:\\Windows\\System32\\rd.exe dir" (path-qualified rd.exe, no /s)' \
        'cmd /c "C:\Windows\System32\rd.exe dir"'

    echo ""
    echo "=== cmd.exe — a foreign PowerShell clause embedded in cmd must still resolve (round9 C5) ==="

    # foreignClauseBlocks hands a pwsh-headed clause to the pwsh judge instead of
    # dismissing it as an unrecognized cmd.exe verb.
    expect_block_cmd 'cmd /c "powershell -Command \"Remove-Item -Recurse x\"" (foreign pwsh clause inside cmd)' \
        'cmd /c "powershell -Command \"Remove-Item -Recurse x\""'
    expect_approve_cmd 'cmd /c "powershell -Command \"Get-ChildItem x\"" (foreign pwsh clause, harmless payload)' \
        'cmd /c "powershell -Command \"Get-ChildItem x\""'

    echo ""
    echo "=== cmd.exe — clause/nesting overflow guard still fails closed (round9 C5) ==="

    # MAX_CLAUSE_CANDIDATES bounds only the launcher fan-out, not the outer
    # &-clause count — hence the 34-word `start` payload rather than many clauses.
    expect_block_cmd 'cmd /c "start w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 rd /s dir" (launcher fan-out exceeds MAX_CLAUSE_CANDIDATES, fail-closed)' \
        'cmd /c "start w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 rd /s dir"'

    echo ""
    echo "=== cmd.exe — dynamic-head distinction at clause-HEAD position (round9 fix landed) ==="

    # %VAR% at a clause head expands once at parse time, so a same-line `set` cannot
    # reach it; !VAR! under delayed expansion can, so only !VAR! must fail closed.
    expect_block_cmd 'cmd /v:on /c "set CMD=rd& !CMD! /s dir" (delayed-expansion !VAR! at clause head, fails closed)' \
        'cmd /v:on /c "set CMD=rd& !CMD! /s dir"'
    expect_approve_cmd 'cmd /c "%CMD% /s dir" (bare %VAR% at clause head, parse-time-once, safely approved)' \
        'cmd /c "%CMD% /s dir"'
    expect_approve_cmd 'cmd /c "set CMD=echo& %CMD% hi" (same-line set cannot affect %VAR% head, harmless payload)' \
        'cmd /c "set CMD=echo& %CMD% hi"'

    echo ""
    echo "=== cmd.exe — blocked command's own text must not leak into hook output (C8, CPR-ORTH with posix) ==="

    local secret_needle secret_cmd secret_combined
    secret_needle="sk-test-DUMMY1234567890ABCDEFGHIJ"
    secret_cmd="cmd /c rmdir /s C:\\cache-${secret_needle}"
    secret_combined="$(printf '%s' "$(payload_cmd "$secret_cmd")" | run_with_timeout 60 node "$HOOK" 2>&1)"
    lacks "blocked cmd.exe command's secret-looking substring never appears in hook stdout+stderr (C8)" \
        "$secret_needle" "$secret_combined"
}
