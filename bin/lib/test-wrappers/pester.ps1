# bin/lib/test-wrappers/pester.ps1 — runs one *.Tests.ps1 file for tests/run-all.sh (#2501).
# Writes <RUN_ALL_RESULT_DIR>/cases.tsv, fail-details.tsv (#2956) and testResults.xml; exit 0 pass, 1 any failure,
# 77 no test ran or all skipped, 79 + an `unrunnable` marker when Pester < -MinVersion.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$MinVersion
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The result env belongs to this wrapper; the test code under it must never see it.
$resultDir = $env:RUN_ALL_RESULT_DIR
Remove-Item -Path Env:RUN_ALL_RESULT_DIR, Env:RUN_ALL_RESULT_OWNER -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($resultDir)) {
    $resultDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("pester-" + [guid]::NewGuid())
}
$null = New-Item -ItemType Directory -Path $resultDir -Force
$casesFile = Join-Path -Path $resultDir -ChildPath 'cases.tsv'
$utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

function Write-UnrunnableMarker {
    param([string]$Label)
    [System.IO.File]::WriteAllText((Join-Path -Path $resultDir -ChildPath 'unrunnable'), "$Label`n", $utf8)
}

function Add-CaseRecord {
    param([int]$Seq, [string]$State, [string]$Name)
    $clean = { param($s) ($s -replace "[`t`r`n]", ' ') }
    $line = "{0}`t{1}`t{2}`t{3}`n" -f $Seq, $State, (& $clean $Name), (& $clean $Path)
    [System.IO.File]::AppendAllText($casesFile, $line, $utf8)
}

# One fail-details.tsv text: the fold of test-result-contract.md (fail-details.tsv section), cut at the byte level.
function ConvertTo-FoldBytes {
    param([string]$Text)
    $lines = @(($Text -replace "`r`n?", "`n").Split("`n") | ForEach-Object { $_ -replace '[ \t]+$', '' })
    $n = $lines.Count
    while ($n -gt 0 -and $lines[$n - 1] -eq '') { $n-- }
    $body = if ($n -gt 0) { (@($lines[0..($n - 1)] | ForEach-Object { $_.Replace('\', '\\').Replace("`t", '\t') }) -join '\n') } else { '' }
    $bytes = $utf8.GetBytes($body)
    if ($bytes.Length -le 8192) { return , $bytes }
    return , ([byte[]]($bytes[0..8191] + $utf8.GetBytes('\n[cut]')))
}

function Add-DetailRecord {
    param([int]$Seq, [string]$Name, [object[]]$ErrorRecords)
    $text = (@($ErrorRecords | Where-Object { $null -ne $_ } | ForEach-Object { $_.Exception.Message }) -join "`n")
    $headText = "{0}`t{1}`t" -f $Seq, ($Name -replace "[`t`r`n]", ' ')
    $head = $utf8.GetBytes($headText)
    $record = [byte[]]($head + (ConvertTo-FoldBytes -Text $text) + [byte[]](10))
    $stream = [System.IO.File]::Open((Join-Path -Path $resultDir -ChildPath 'fail-details.tsv'), 'Append', 'Write')
    try { $stream.Write($record, 0, $record.Length) } finally { $stream.Dispose() }
}

function Get-ErrorRecordList {
    param($Item)
    $prop = $Item.PSObject.Properties['ErrorRecord']
    if ($null -eq $prop) { return , @() }
    return , @($prop.Value)
}

# Only an absent or too-old Pester is a missing runtime; an installed one that fails to import must fail.
$installed = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]$MinVersion })
if ($installed.Count -eq 0) {
    Write-Output "UNRUNNABLE: Pester>=$MinVersion is not installed"
    Write-UnrunnableMarker -Label "Pester>=$MinVersion"
    exit 79
}
$null = Import-Module -Name Pester -MinimumVersion $MinVersion -PassThru -ErrorAction Stop

$config = New-PesterConfiguration
# Pester expands Run.Path as a wildcard; escape the literal file so `a[1].Tests.ps1` runs only itself.
$literalPath = (Resolve-Path -LiteralPath $Path).ProviderPath
$config.Run.Path = @([System.Management.Automation.WildcardPattern]::Escape($literalPath))
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path -Path $resultDir -ChildPath 'testResults.xml'
# Test code runs under default session preferences, as under a plain Invoke-Pester; only this wrapper stays strict.
$run = & { Set-StrictMode -Off; $ErrorActionPreference = 'Continue'; Invoke-Pester -Configuration $config }

$stateOf = @{ Passed = 'PASS'; Failed = 'FAIL'; Skipped = 'SKIP'; Inconclusive = 'SKIP' }
$seq = 0
$failed = 0
$skipped = 0
foreach ($test in @($run.Tests)) {
    $result = [string]$test.Result
    if (-not $stateOf.ContainsKey($result)) { continue }
    $seq++
    $state = $stateOf[$result]
    if ($state -eq 'FAIL') { $failed++ } elseif ($state -eq 'SKIP') { $skipped++ }
    Add-CaseRecord -Seq $seq -State $state -Name $test.ExpandedPath
    if ($state -eq 'FAIL') { Add-DetailRecord -Seq $seq -Name $test.ExpandedPath -ErrorRecords (Get-ErrorRecordList -Item $test) }
}
# A file that fails to load, or a BeforeAll that throws, fails no It of its own.
if (($run.FailedContainersCount + $run.FailedBlocksCount) -gt 0) {
    $seq++
    $failed++
    Add-CaseRecord -Seq $seq -State 'FAIL' -Name '(container)'
    $errs = @(@($run.Containers) + @($run.Failed) | ForEach-Object { Get-ErrorRecordList -Item $_ } | ForEach-Object { $_ })
    Add-DetailRecord -Seq $seq -Name '(container)' -ErrorRecords $errs
}

if ($failed -gt 0) { exit 1 }
if ($seq -eq 0 -or $skipped -eq $seq) { exit 77 }
exit 0
