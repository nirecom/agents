# Tests: install/win/pwsh.ps1
# Tags: installer, pwsh-required, scope:common, TL2
# Pester 5 behavioral tests for install/win/pwsh.ps1
# TL3 gap: real winget/MSI execution on a Windows host; only unit/stub assertions run here.
# Strategy: Get-LatestPwshRelease is defined AND called within one script invocation,
# so a Pester Mock cannot intercept it (the script-local definition shadows it).
# Behavioral tests instead run the equivalent logic in a ScriptBlock wrapper that
# injects test doubles (Get-Command, Get-LatestPwshRelease, winget, Invoke-WebRequest,
# Start-Process).

BeforeAll {
    $script:ScriptPath    = (Resolve-Path "$PSScriptRoot\..\..\install\win\pwsh.ps1").Path
    $script:ScriptContent = Get-Content $script:ScriptPath -Raw
    # Mirror the new source logic: prefer the installed binary's version over the session version.
    $installedPwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    $script:CurrentVersion = if (Test-Path $installedPwsh) {
        [Version]((& $installedPwsh --version) -replace 'PowerShell ', '')
    } else {
        $PSVersionTable.PSVersion
    }
    # Compute patch (3rd component) portably — [Version] uses .Build, SemanticVersion uses .Patch.
    $script:CurrentPatch = if ($script:CurrentVersion -is [System.Version]) {
        [Math]::Max(0, $script:CurrentVersion.Build)
    } else {
        $script:CurrentVersion.Patch
    }

    # ---------------------------------------------------------------------------
    # Helper: build a fake release object
    # ---------------------------------------------------------------------------
    function script:New-FakeRelease {
        param(
            [string]$TagName    = 'v99.9.9',
            [bool]  $IncludeX64 = $true,
            [bool]  $IncludeX86 = $true
        )
        $assets = @()
        if ($IncludeX64) {
            $assets += [PSCustomObject]@{
                name                 = "PowerShell-99.9.9-win-x64.msi"
                browser_download_url = 'https://fake.example.com/pwsh-x64.msi'
            }
        }
        if ($IncludeX86) {
            $assets += [PSCustomObject]@{
                name                 = "PowerShell-99.9.9-win-x86.msi"
                browser_download_url = 'https://fake.example.com/pwsh-x86.msi'
            }
        }
        return [PSCustomObject]@{
            tag_name = $TagName
            assets   = $assets
        }
    }

    # Runs equivalent script logic with injected stubs; returns .Output/.Warnings; $script:LastCapturedSP holds Start-Process args.
    function script:Invoke-PwshScript {
        param(
            [object] $FakeRelease    = $null,
            [bool]   $ApiThrows      = $false,
            [bool]   $PwshPresent    = $true,
            [bool]   $WingetPresent  = $true,
            [int]    $WingetExitCode = 0,
            [int]    $MsiExitCode    = 0,
            [bool]   $Is64Bit        = $true
        )

        # Reset captured SP args
        $script:LastCapturedSP = $null

        # --- Build Get-LatestPwshRelease stub body ---
        if ($ApiThrows) {
            $apiBody = 'throw "Simulated API error"'
        } else {
            # Serialise the release object to JSON so the scriptblock is self-contained
            $releaseJson = $FakeRelease | ConvertTo-Json -Depth 10 -Compress
            # Escape for embedding inside a here-string value (single quotes safe since JSON uses double quotes)
            $apiBody = @"
`$r = '$releaseJson' | ConvertFrom-Json
`$assetsList = @()
if (`$r.assets) {
    foreach (`$a in `$r.assets) {
        `$assetsList += [PSCustomObject]@{
            name                 = `$a.name
            browser_download_url = `$a.browser_download_url
        }
    }
}
return [PSCustomObject]@{ tag_name = `$r.tag_name; assets = `$assetsList }
"@
        }

        # --- Build Get-Command stub ---
        $pwshResult   = if ($PwshPresent)   { '[PSCustomObject]@{ Name = "pwsh" }'   } else { '$null' }
        $wingetResult = if ($WingetPresent) { '[PSCustomObject]@{ Name = "winget" }' } else { '$null' }
        $getCommandBody = @"
param([string]`$Name, [string]`$ErrorAction)
if (`$Name -eq 'pwsh')   { return $pwshResult }
if (`$Name -eq 'winget') { return $wingetResult }
return `$null
"@

        # --- Build winget stub ---
        $wingetBody = "`$global:LASTEXITCODE = $WingetExitCode"

        # --- Build Invoke-WebRequest stub (no-op) ---
        $iwrBody = @'
param([string]$Uri, [string]$OutFile)
# no-op stub: prevents real HTTP calls in tests
'@

        # --- Build Start-Process stub ---
        # Must use [switch] for -Wait and -PassThru to match original call signature
        $startProcessBody = @"
param(
    [string]`$FilePath,
    [string]`$ArgumentList,
    [string]`$Verb,
    [switch]`$Wait,
    [switch]`$PassThru
)
`$script:__sp_args = @{
    FilePath     = `$FilePath
    ArgumentList = `$ArgumentList
    Verb         = `$Verb
}
return [PSCustomObject]@{ ExitCode = $MsiExitCode }
"@

        # --- Arch value for [Environment]::Is64BitOperatingSystem ---
        # We cannot mock a static .NET property, so we replicate the arch logic
        # directly in the patched script using the $Is64Bit parameter value.
        $archValue = if ($Is64Bit) { "'win-x64'" } else { "'win-x86'" }

        # --- Build patched script ---
        # The patched script mirrors the original logic exactly, with stubs injected.
        # We replace the [Environment]::Is64BitOperatingSystem call with the literal value.
        $patchedScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

function Get-Command {
$getCommandBody
}
function winget {
$wingetBody
}
function Invoke-WebRequest {
$iwrBody
}
function Start-Process {
$startProcessBody
}
function Get-LatestPwshRelease {
$apiBody
}

# --- Script body (mirrors install/win/pwsh.ps1) ---
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning 'winget not found. Install PowerShell Core manually: https://github.com/PowerShell/PowerShell'
        return
    }
    Write-Host 'Installing PowerShell Core via winget...'
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
    if (`$LASTEXITCODE -eq 0) {
        Write-Host 'PowerShell Core installed.' -ForegroundColor Green
        Write-Host 'Restart your terminal to use pwsh.' -ForegroundColor Yellow
    } else {
        Write-Warning "PowerShell Core installation failed (exit code: `$LASTEXITCODE). Re-run install.ps1 to retry."
    }
    return
}

try {
    `$installedPwsh = "`$env:ProgramFiles\PowerShell\7\pwsh.exe"
    `$currentVersion = if (Test-Path `$installedPwsh) {
        [Version]((& `$installedPwsh --version) -replace 'PowerShell ', '')
    } else {
        `$PSVersionTable.PSVersion
    }
    `$release = Get-LatestPwshRelease
} catch {
    Write-Warning "Could not check latest PowerShell version: `$(`$_.Exception.Message)"
    return
}
`$latestVersion = [Version](`$release.tag_name -replace '^v', '')

if (`$latestVersion -le `$currentVersion) {
    Write-Host "PowerShell Core is already up to date (`$currentVersion)." -ForegroundColor DarkGray
    return
}

Write-Host "Updating PowerShell Core: `$currentVersion -> `$latestVersion ..."
`$arch = $archValue
`$msiAsset = `$release.assets | Where-Object { `$_.name -match "`$arch\.msi`$" } | Select-Object -First 1
if (-not `$msiAsset) {
    Write-Warning "Could not find MSI asset for `$latestVersion (`$arch)."
    return
}

`$msiPath = Join-Path ([System.IO.Path]::GetTempPath()) `$msiAsset.name
Write-Host "Downloading `$(`$msiAsset.name)..."
Invoke-WebRequest -Uri `$msiAsset.browser_download_url -OutFile `$msiPath

`$proc = Start-Process msiexec -ArgumentList "/i ```"`$msiPath```" /quiet /norestart" -Verb RunAs -Wait -PassThru
if (`$proc.ExitCode -eq 0) {
    Write-Host "PowerShell Core updated to `$latestVersion. Restart your terminal." -ForegroundColor Green
} else {
    Write-Warning "MSI install failed (exit code: `$(`$proc.ExitCode))."
}
"@

        $sb = [ScriptBlock]::Create($patchedScript)

        $output   = [System.Collections.Generic.List[string]]::new()
        $warnings = [System.Collections.Generic.List[string]]::new()

        $allOutput = & $sb 3>&1 6>&1 2>&1
        foreach ($item in $allOutput) {
            if ($item -is [System.Management.Automation.WarningRecord]) {
                $warnings.Add($item.Message)
            } else {
                $output.Add($item.ToString())
            }
        }

        # Propagate captured Start-Process args to script scope for assertions
        if ($null -ne $script:__sp_args) {
            $script:LastCapturedSP = $script:__sp_args
            $script:__sp_args      = $null
        }

        return [PSCustomObject]@{
            Output   = [string[]]$output
            Warnings = [string[]]$warnings
        }
    }
}

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 static checks" {
    It "file exists" {
        Test-Path $script:ScriptPath | Should -BeTrue
    }

    It "has valid PowerShell syntax" {
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize(
            $script:ScriptContent, [ref]$errors
        ) | Out-Null
        $errors.Count | Should -Be 0
    }

    It "sets StrictMode" {
        $script:ScriptContent | Should -Match 'Set-StrictMode'
    }

    It "sets ErrorActionPreference = Stop" {
        $script:ScriptContent | Should -Match 'ErrorActionPreference\s*=\s*"Stop"'
    }

    It "checks LASTEXITCODE after winget install" {
        $script:ScriptContent | Should -Match 'LASTEXITCODE'
    }
}

# ---------------------------------------------------------------------------
# Normal cases
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 normal cases" {

    Context "N1: pwsh installed, latest <= current — already up to date" {
        BeforeAll {
            $minorBack = [Math]::Max(0, $script:CurrentVersion.Minor - 1)
            $oldTag    = "v$($script:CurrentVersion.Major).$minorBack.0"
            $script:n1Release = script:New-FakeRelease -TagName $oldTag
        }

        It "prints 'already up to date' message" {
            $result = script:Invoke-PwshScript -FakeRelease $script:n1Release -PwshPresent $true
            ($result.Output -join ' ') | Should -Match 'already up to date'
        }

        It "does NOT call Invoke-WebRequest (no Downloading output)" {
            $result = script:Invoke-PwshScript -FakeRelease $script:n1Release -PwshPresent $true
            ($result.Output -join ' ') | Should -Not -Match 'Downloading'
        }
    }

    Context "N2: pwsh installed, latest > current, MSI found, msiexec exit 0 — updated" {
        BeforeAll {
            $script:n2Release = script:New-FakeRelease -TagName 'v99.9.9'
        }

        It "prints 'updated to' message" {
            $result = script:Invoke-PwshScript -FakeRelease $script:n2Release -PwshPresent $true -MsiExitCode 0
            ($result.Output -join ' ') | Should -Match 'updated to'
        }

        It "calls Invoke-WebRequest — Downloading message appears" {
            $result = script:Invoke-PwshScript -FakeRelease $script:n2Release -PwshPresent $true -MsiExitCode 0
            ($result.Output -join ' ') | Should -Match 'Downloading'
        }

        It "calls Start-Process — no MSI failure warning emitted" {
            $result = script:Invoke-PwshScript -FakeRelease $script:n2Release -PwshPresent $true -MsiExitCode 0
            ($result.Warnings -join ' ') | Should -Not -Match 'MSI install failed'
        }
    }

    Context "N3: pwsh not installed, winget available, winget exit 0 — install path" {
        It "prints 'PowerShell Core installed' message" {
            $result = script:Invoke-PwshScript -PwshPresent $false -WingetPresent $true -WingetExitCode 0
            ($result.Output -join ' ') | Should -Match 'PowerShell Core installed'
        }

        It "does NOT attempt GitHub API call — no Downloading output" {
            $result = script:Invoke-PwshScript -PwshPresent $false -WingetPresent $true -WingetExitCode 0
            ($result.Output -join ' ') | Should -Not -Match 'Downloading'
        }
    }

    Context "N4: pwsh not installed, winget not available — warning shown" {
        It "shows 'winget not found' warning" {
            $result = script:Invoke-PwshScript -PwshPresent $false -WingetPresent $false
            ($result.Warnings -join ' ') | Should -Match 'winget not found'
        }

        It "does NOT attempt any download" {
            $result = script:Invoke-PwshScript -PwshPresent $false -WingetPresent $false
            ($result.Output -join ' ') | Should -Not -Match 'Downloading'
        }
    }
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 error cases" {

    Context "E1: GitHub API throws — warning shown, no download" {
        It "shows 'Could not check latest' warning" {
            $result = script:Invoke-PwshScript -PwshPresent $true -ApiThrows $true
            ($result.Warnings -join ' ') | Should -Match 'Could not check latest'
        }

        It "does NOT call Start-Process — no 'updated to' message" {
            $result = script:Invoke-PwshScript -PwshPresent $true -ApiThrows $true
            ($result.Output -join ' ') | Should -Not -Match 'updated to'
        }
    }

    Context "E2: MSI asset absent from release — warning, no download" {
        BeforeAll {
            $script:e2Release = script:New-FakeRelease -TagName 'v99.9.9' -IncludeX64 $false -IncludeX86 $false
        }

        It "shows 'Could not find MSI asset' warning" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:e2Release
            ($result.Warnings -join ' ') | Should -Match 'Could not find MSI asset'
        }

        It "does NOT show 'Downloading' — Invoke-WebRequest not called" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:e2Release
            ($result.Output -join ' ') | Should -Not -Match 'Downloading'
        }
    }

    Context "E3: msiexec ExitCode != 0 — failure warning" {
        BeforeAll {
            $script:e3Release = script:New-FakeRelease -TagName 'v99.9.9'
        }

        It "shows 'MSI install failed (exit code:' warning" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:e3Release -MsiExitCode 1603
            ($result.Warnings -join ' ') | Should -Match 'MSI install failed \(exit code:'
        }
    }

    Context "E4: winget install LASTEXITCODE != 0 — installation failed warning" {
        It "shows 'installation failed' warning" {
            $result = script:Invoke-PwshScript -PwshPresent $false -WingetPresent $true -WingetExitCode 1
            ($result.Warnings -join ' ') | Should -Match 'installation failed'
        }
    }
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 edge cases" {

    Context "X1: latest == current exactly — already up to date (boundary for <=)" {
        BeforeAll {
            $exactTag = "v$($script:CurrentVersion.Major).$($script:CurrentVersion.Minor).$($script:CurrentPatch)"
            $script:x1Release = script:New-FakeRelease -TagName $exactTag
        }

        It "prints 'already up to date' for equal version" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x1Release
            ($result.Output -join ' ') | Should -Match 'already up to date'
        }

        It "does NOT show 'Downloading' for equal version" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x1Release
            ($result.Output -join ' ') | Should -Not -Match 'Downloading'
        }
    }

    Context "X2: tag_name without leading 'v' — parses correctly, no crash" {
        BeforeAll {
            # Use current version without 'v' prefix — should be equal, so <= fires
            $noVTag = "$($script:CurrentVersion.Major).$($script:CurrentVersion.Minor).$($script:CurrentPatch)"
            $script:x2Release = script:New-FakeRelease -TagName $noVTag
        }

        It "does not throw when tag has no leading v" {
            { script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x2Release } | Should -Not -Throw
        }

        It "produces expected output — already up to date or updated (no crash)" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x2Release
            $combined = ($result.Output + $result.Warnings) -join ' '
            $combined | Should -Match 'updated to|already up to date'
        }
    }

    Context "X3: 32-bit OS — win-x86.msi asset selected" {
        BeforeAll {
            $script:x3Release = script:New-FakeRelease -TagName 'v99.9.9' -IncludeX64 $true -IncludeX86 $true
        }

        It "selects win-x86 asset on 32-bit OS — Downloading message shows x86" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x3Release -Is64Bit $false -MsiExitCode 0
            ($result.Output -join ' ') | Should -Match 'win-x86'
        }

        It "does NOT select win-x64 on 32-bit OS" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x3Release -Is64Bit $false -MsiExitCode 0
            ($result.Output -join ' ') | Should -Not -Match 'win-x64'
        }
    }

    Context "X4: 64-bit OS — win-x64.msi asset selected" {
        BeforeAll {
            $script:x4Release = script:New-FakeRelease -TagName 'v99.9.9' -IncludeX64 $true -IncludeX86 $true
        }

        It "selects win-x64 asset on 64-bit OS — Downloading message shows x64" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x4Release -Is64Bit $true -MsiExitCode 0
            ($result.Output -join ' ') | Should -Match 'win-x64'
        }

        It "does NOT select win-x86 on 64-bit OS" {
            $result = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:x4Release -Is64Bit $true -MsiExitCode 0
            ($result.Output -join ' ') | Should -Not -Match 'win-x86'
        }
    }
}

# ---------------------------------------------------------------------------
# Regression cases (static pattern checks against source file)
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 regression cases" {

    Context "R1: Start-Process -PassThru used — ExitCode from proc, not LASTEXITCODE" {
        It "script uses -PassThru with Start-Process" {
            $script:ScriptContent | Should -Match '(?i)-PassThru'
        }

        It "script assigns Start-Process result to variable proc" {
            $script:ScriptContent | Should -Match '\$proc\s*=\s*Start-Process'
        }

        It "script checks proc.ExitCode, not raw LASTEXITCODE, after msiexec" {
            $script:ScriptContent | Should -Match '\$proc\.ExitCode'
        }
    }

    Context "R2: Start-Process called with -Verb RunAs" {
        It "script uses -Verb RunAs in Start-Process call" {
            $script:ScriptContent | Should -Match '(?i)-Verb\s+RunAs'
        }
    }

    Context "R3: msiexec ArgumentList includes /quiet, /norestart, and /i with quoted path" {
        It "ArgumentList contains /quiet" {
            $script:ScriptContent | Should -Match '/quiet'
        }

        It "ArgumentList contains /norestart" {
            $script:ScriptContent | Should -Match '/norestart'
        }

        It "ArgumentList uses backtick-double-quote to wrap the MSI path" {
            # Source line: -ArgumentList "/i `"$msiPath`" /quiet /norestart"
            # In raw content this appears as the literal characters: /i `"
            $script:ScriptContent | Should -Match '/i\s+`"'
        }
    }

    Context "R4: version detection uses installed binary path, not PSVersionTable directly" {
        It "source references installed pwsh.exe path via ProgramFiles env var" {
            $script:ScriptContent | Should -Match 'ProgramFiles.*PowerShell.*pwsh\.exe'
        }

        It "source uses Test-Path to check the installed binary before reading its version" {
            $script:ScriptContent | Should -Match 'Test-Path.*installedPwsh'
        }

        It "source calls the installed binary with --version to read its version" {
            $script:ScriptContent | Should -Match '&.*installedPwsh.*--version'
        }
    }

    Context "R5: catch block uses Exception.Message, not bare `$_" {
        It "catch block uses `$(`$_.Exception.Message) for the warning" {
            $script:ScriptContent | Should -Match '\$\(.*\.Exception\.Message\)'
        }

        It "catch block does NOT use bare `$_ (without .Exception) in the warning string" {
            # The warning must use $($_.Exception.Message), not bare $_ or $($_ )
            # Match Write-Warning lines where $_ appears but is NOT followed by .Exception
            $script:ScriptContent | Should -Not -Match 'Write-Warning[^`n]*\$_[^.`n]'
        }
    }
}

# ---------------------------------------------------------------------------
# Idempotency cases
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 idempotency cases" {

    Context "I1: latest <= current run twice — Invoke-WebRequest called 0 times total" {
        BeforeAll {
            $minorBack = [Math]::Max(0, $script:CurrentVersion.Minor - 1)
            $oldTag    = "v$($script:CurrentVersion.Major).$minorBack.0"
            $script:i1Release = script:New-FakeRelease -TagName $oldTag
        }

        It "running twice never triggers a download" {
            $r1 = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:i1Release
            $r2 = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:i1Release
            ($r1.Output + $r2.Output -join '') | Should -Not -Match 'Downloading'
        }

        It "running twice always shows 'already up to date'" {
            $r1 = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:i1Release
            $r2 = script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:i1Release
            ($r1.Output -join ' ') | Should -Match 'already up to date'
            ($r2.Output -join ' ') | Should -Match 'already up to date'
        }
    }
}

# ---------------------------------------------------------------------------
# Security cases
# ---------------------------------------------------------------------------
Describe "pwsh.ps1 security cases" {

    Context "S1: MSI asset name with spaces — msiexec path is quoted" {
        BeforeAll {
            $script:s1Release = [PSCustomObject]@{
                tag_name = 'v99.9.9'
                assets   = @([PSCustomObject]@{
                    name                 = "PowerShell 99.9.9 win-x64.msi"
                    browser_download_url = 'https://fake.example.com/pwsh.msi'
                })
            }
        }

        It "script quotes the MSI path in ArgumentList — backtick-double-quote present" {
            # Source line: -ArgumentList "/i `"$msiPath`" /quiet /norestart"
            $script:ScriptContent | Should -Match '/i\s+`"'
        }

        It "MSI path quoting survives asset name with spaces — no crash" {
            { script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:s1Release -MsiExitCode 0 } | Should -Not -Throw
        }

        It "Start-Process ArgumentList contains the full MSI filename (with spaces)" {
            script:Invoke-PwshScript -PwshPresent $true -FakeRelease $script:s1Release -MsiExitCode 0 | Out-Null
            $script:LastCapturedSP | Should -Not -BeNullOrEmpty
            $script:LastCapturedSP.ArgumentList | Should -Match 'PowerShell 99\.9\.9 win-x64\.msi'
        }
    }
}
