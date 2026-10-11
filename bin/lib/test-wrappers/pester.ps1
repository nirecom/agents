# bin/lib/test-wrappers/pester.ps1 — runs one *.Tests.ps1 file for tests/run-all.sh (#2501).
# Writes <RUN_ALL_RESULT_DIR>/cases.tsv and testResults.xml; exit 0 pass, 1 any failure,
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
$run = Invoke-Pester -Configuration $config

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
}
# A file that fails to load, or a BeforeAll that throws, fails no It of its own.
if (($run.FailedContainersCount + $run.FailedBlocksCount) -gt 0) {
    $seq++
    $failed++
    Add-CaseRecord -Seq $seq -State 'FAIL' -Name '(container)'
}

if ($failed -gt 0) { exit 1 }
if ($seq -eq 0 -or $skipped -eq $seq) { exit 77 }
exit 0
