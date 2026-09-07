# tests/feature-2210-block-recursive-delete/cases-pwsh.sh
# Tests: hooks/block-recursive-delete.js, hooks/lib/bash-write-targets/pwsh.js
# Tags: scope:issue-specific, recursive-delete, hook, powershell, remove-item, TL2
#
# Text-only: no real powershell.exe or pwsh process runs, so payload expansion
# stays unverified (TL3 gap, C10 — see the dispatcher's `# TL3 gap` block).

run_pwsh_cases() {
    echo ""
    echo "=== PowerShell Remove-Item family — recursive forms must block ==="

    expect_block_cmd "Remove-Item -Recurse dir (no -Force)" "Remove-Item -Recurse dir"
    expect_block_cmd "Remove-Item -Recurse -Force dir (former deny glob order)" \
        "Remove-Item -Recurse -Force dir"
    expect_block_cmd "Remove-Item -Force -Recurse dir (former deny glob order, reversed)" \
        "Remove-Item -Force -Recurse dir"
    expect_block_cmd "ri -r dir (alias + short flag)" "ri -r dir"
    expect_block_cmd "rd -Recurse dir (alias)" "rd -Recurse dir"
    expect_block_cmd "del -Recurse dir (alias)" "del -Recurse dir"
    expect_block_cmd "Remove-Item -Recurse:\$true dir (explicit switch value)" \
        'Remove-Item -Recurse:$true dir'

    # Regression (detail.md Step 2): a variable TARGET must not defeat the flag match.
    expect_block_cmd "Remove-Item -Recurse \$env:TEMP\\dir (variable target)" \
        'Remove-Item -Recurse $env:TEMP\dir'
    expect_block_cmd "Remove-Item -Recurse \"\$dir\" (quoted variable target)" \
        'Remove-Item -Recurse "$dir"'

    echo ""
    echo "=== PowerShell — rm/rmdir/erase aliases and the -Rec short form (C6) ==="

    expect_block_cmd "rm -Recurse dir (rm alias, long flag)" "rm -Recurse dir"
    expect_block_cmd "rmdir -Recurse dir (rmdir alias)" "rmdir -Recurse dir"
    expect_block_cmd "erase -Recurse dir (erase alias)" "erase -Recurse dir"
    expect_block_cmd "Remove-Item -Rec dir (abbreviated -Rec form)" "Remove-Item -Rec dir"

    echo ""
    echo "=== PowerShell is case-INSENSITIVE — cmdlet, alias and switch-value casing (round-4 C3) ==="

    expect_block_cmd "Remove-Item -Recurse:\$TRUE dir (uppercase boolean literal)" \
        'Remove-Item -Recurse:$TRUE dir'
    expect_block_cmd "remove-item -recurse:\$true dir (lowercase cmdlet + flag)" \
        'remove-item -recurse:$true dir'
    expect_block_cmd "REMOVE-ITEM -ReCuRsE dir (mixed-case cmdlet + flag)" \
        "REMOVE-ITEM -ReCuRsE dir"
    expect_block_cmd "RI -R dir (uppercase alias + short flag)" "RI -R dir"

    echo ""
    echo "=== PowerShell — recursive flag placed AFTER the target must still block (C4) ==="

    expect_block_cmd "Remove-Item dir -Recurse (flag after target, C4)" "Remove-Item dir -Recurse"

    echo ""
    echo "=== PowerShell — unresolvable flag content folds to block (C2, hook-integration level) ==="

    expect_block_cmd "Remove-Item -\$VAR dir (unresolvable flag NAME, null -> block, C2)" \
        'Remove-Item -$VAR dir'
    expect_block_cmd "Remove-Item -Recurse:\$SomeVar dir (unresolvable switch VALUE, null -> block, C2)" \
        'Remove-Item -Recurse:$SomeVar dir'

    echo ""
    echo "=== PowerShell — concealed form must block ==="

    expect_block_cmd "pwsh -Command \"Remove-Item -Recurse x\" (interpreter wrapper)" \
        'pwsh -Command "Remove-Item -Recurse x"'
    expect_block_cmd "powershell -Command \"Remove-Item -Recurse x\" (bare powershell name, no .exe)" \
        'powershell -Command "Remove-Item -Recurse x"'
    expect_block_cmd "powershell.exe -Command \"Remove-Item -Recurse x\" (actual .exe suffix, C5)" \
        'powershell.exe -Command "Remove-Item -Recurse x"'
    expect_block_cmd "pwsh -c \"Remove-Item -Recurse x\" (short -c form, C5)" \
        'pwsh -c "Remove-Item -Recurse x"'
    expect_block_cmd "/usr/bin/pwsh -Command \"Remove-Item -Recurse x\" (path-qualified interpreter, POSIX-style, C5)" \
        '/usr/bin/pwsh -Command "Remove-Item -Recurse x"'
    expect_block_cmd "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -Command \"Remove-Item -Recurse x\" (path-qualified interpreter, Windows-style, C5)" \
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Remove-Item -Recurse x"'

    echo ""
    echo "=== PowerShell — upstream-recursion pipeline forms must block (C4) ==="

    # hasRecursivePwshPipelineFlag walks BACKWARD from a bare Remove-Item: the
    # recursion can live on an upstream segment that is not itself a delete.
    expect_block_cmd "Get-ChildItem -Recurse dir | Remove-Item (upstream -Recurse enumeration)" \
        "Get-ChildItem -Recurse dir | Remove-Item"
    expect_block_cmd "gci -Recurse dir | Remove-Item (gci alias upstream)" \
        "gci -Recurse dir | Remove-Item"
    expect_block_cmd "Get-ChildItem -Recurse dir | ri (ri alias downstream)" \
        "Get-ChildItem -Recurse dir | ri"
    expect_block_cmd "Get-ChildItem dir -Recurse | Remove-Item (flag after target, upstream)" \
        "Get-ChildItem dir -Recurse | Remove-Item"
    expect_block_cmd "ls -Recurse dir | Remove-Item -Force (Force downstream, Recurse upstream)" \
        "ls -Recurse dir | Remove-Item -Force"

    # PWSH_BLOCK_PIPELINE_HEADS judges a script-block BODY as its own segment.
    expect_block_cmd "Get-ChildItem -Recurse dir | ForEach-Object { Remove-Item \$_ } (upstream recurse, block body)" \
        'Get-ChildItem -Recurse dir | ForEach-Object { Remove-Item $_ }'
    expect_block_cmd "gci dir | ForEach-Object { Remove-Item -Recurse \$_ } (Recurse INSIDE the block body)" \
        'gci dir | ForEach-Object { Remove-Item -Recurse $_ }'
    expect_block_cmd "gci -Recurse dir | %{ Remove-Item \$_ } (glued %{ alias form, upstream -Recurse)" \
        'gci -Recurse dir | %{ Remove-Item $_ }'

    echo ""
    echo "=== PowerShell — non-recursive upstream enumeration must NOT block (C4 symmetric negative) ==="

    expect_approve_cmd "Get-ChildItem dir | Remove-Item (no -Recurse anywhere in the pipeline)" \
        "Get-ChildItem dir | Remove-Item"
    expect_approve_cmd "gci dir | ForEach-Object { Remove-Item \$_ } (no -Recurse anywhere, block body)" \
        'gci dir | ForEach-Object { Remove-Item $_ }'
    expect_approve_cmd "Get-ChildItem -Recurse dir | Select-Object Name (upstream recurse, no delete downstream)" \
        "Get-ChildItem -Recurse dir | Select-Object Name"
    expect_approve_cmd "Get-ChildItem -Recurse dir; Remove-Item file.txt (statement separator, NOT a pipeline)" \
        "Get-ChildItem -Recurse dir; Remove-Item file.txt"

    echo ""
    echo "=== PowerShell — blocked command's own text must not leak into hook output (C8, CPR-ORTH with posix) ==="

    local secret_needle secret_cmd secret_combined
    secret_needle="sk-test-DUMMY1234567890ABCDEFGHIJ"
    secret_cmd="Remove-Item -Recurse C:\\cache-${secret_needle}"
    secret_combined="$(printf '%s' "$(payload_cmd "$secret_cmd")" | run_with_timeout 60 node "$HOOK" 2>&1)"
    lacks "blocked pwsh command's secret-looking substring never appears in hook stdout+stderr (C8)" \
        "$secret_needle" "$secret_combined"
}
