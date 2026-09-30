# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh.
# Test-CCWaitTarget -Path: $false only for the drive-rooted Desktop app shell
# (<Drive>:\[Program Files\]WindowsApps\Claude_*\app\Claude.exe); every other path —
# a user-writable lookalike included — and null/blank, waits.
# One pwsh start dot-sources the predicate and prints "<name>=<True|False>" per row.

if [ "$HAVE_PWSH" = "0" ]; then
    skip "TP: pwsh not on PATH — Test-CCWaitTarget table skipped"
elif [ ! -f "$TARGET_PS" ]; then
    fail "TP: install/lib/wait-cc-exit-target.ps1 does not exist"
else
    _tp_driver="$TMP/tp-driver.ps1"
    cat > "$_tp_driver" << 'PS1EOF'
param([string]$Target)
$ErrorActionPreference = 'Stop'
. $Target
$rows = @(
    @('std',        'C:\Program Files\WindowsApps\Claude_1.2.3.0_x64__abc\app\Claude.exe'),
    @('lower',      'c:\program files\windowsapps\claude_1.2.3.0_x64__abc\app\claude.exe'),
    @('slash',      'C:/Program Files/WindowsApps/Claude_1.2.3.0_x64__abc/app/Claude.exe'),
    @('ddrive',     'D:\WindowsApps\Claude_1.2.3.0_x64__abc\app\Claude.exe'),
    @('ddrive2',    'D:\WindowsApps\Claude_1.2.3_x64__abc\app\Claude.exe'),
    @('userprofile','C:\Users\u\x\WindowsApps\Claude_1\app\Claude.exe'),
    @('relative',   'WindowsApps\Claude_1\app\Claude.exe'),
    @('vscode',     'C:\Users\u\.vscode\extensions\anthropic.claude-code-2.0.0-win32-x64\resources\native-binary\claude.exe'),
    @('bundled',    'C:\Users\u\AppData\Local\Packages\Claude_x\LocalCache\Roaming\Claude\claude-code\1.0.0\claude.exe'),
    @('cli',        'C:\Users\u\.local\bin\claude.exe'),
    @('unknown',    'E:\tools\claude\claude.exe'),
    @('null',       $null),
    @('empty',      ''),
    @('blank',      '  '),
    @('resources',  'C:\Program Files\WindowsApps\Claude_x\app\resources\claude.exe'),
    @('notclaude',  'C:\Program Files\WindowsApps\NotClaude_x\app\Claude.exe')
)
foreach ($r in $rows) {
    $got = Test-CCWaitTarget -Path $r[1]
    Write-Output ("{0}={1}" -f $r[0], $got)
}
PS1EOF
    _tp_out="$(run_with_timeout 60 pwsh -NoProfile -NonInteractive -File "$(np "$_tp_driver")" -Target "$(np "$TARGET_PS")" 2>&1)"
    _tp_out="$(printf '%s' "$_tp_out" | tr -d '\r')"
    for _tp_row in std:False lower:False slash:False ddrive:False ddrive2:False \
                   userprofile:True relative:True vscode:True bundled:True cli:True unknown:True \
                   null:True empty:True blank:True resources:True notclaude:True; do
        _tp_name="${_tp_row%%:*}"
        _tp_want="${_tp_row#*:}"
        _tp_got="$(printf '%s\n' "$_tp_out" | grep -E "^${_tp_name}=" | head -n 1 | cut -d= -f2)"
        if [ "$_tp_got" = "$_tp_want" ]; then
            pass "TP-$_tp_name: Test-CCWaitTarget -> $_tp_want"
        else
            fail "TP-$_tp_name: Test-CCWaitTarget want=$_tp_want got='$_tp_got'" "$(printf '%s' "$_tp_out" | head -n 3)"
        fi
    done
fi
